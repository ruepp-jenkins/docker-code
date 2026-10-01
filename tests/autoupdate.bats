#!/usr/bin/env bats
# The daily update check: docker-code itself, then the agent's image, each once per day.
#
# These run a real session start rather than a dry run, because a dry run deliberately checks nothing.
# Docker, git and the installer are stubs; the session's `docker run` is just another recorded call.

load helper

setup() {
    setup_wrapper_env
    unset DOCKER_CODE_DRY_RUN

    # A published image by default: one that has a registry digest and an id.
    # shellcheck disable=SC2016  # the body is a script for the stub to run later
    make_stub docker 'case "$1 $2" in
    "image inspect")
        case "$*" in
            *RepoDigests*) printf "%s\n" "${FAKE_DIGEST-ruepp/docker-code-claude@sha256:1}" ;;
            *.Id*)         printf "%s\n" "${FAKE_IMAGE_ID:-sha256:1}" ;;
        esac
esac'
    printf 'bbb\trefs/heads/master\n' >"${BATS_TEST_TMPDIR}/ls-remote"
    # shellcheck disable=SC2016
    make_stub git 'cat "'"${BATS_TEST_TMPDIR}"'/ls-remote"'
}

# A remote installation of this checkout, recorded as being at commit aaa, with an installer that
# only records how it was called and moves the record to bbb, the way a real install would.
fake_install() {
    local mode="${1:-remote}"
    PREFIX="${BATS_TEST_TMPDIR}/prefix"
    BIN_DIR="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${PREFIX}" "${BIN_DIR}"
    cp -R "${REPO_ROOT}/bin" "${REPO_ROOT}/lib" "${REPO_ROOT}/agents" "${PREFIX}/"
    ln -s "${PREFIX}/bin/docker-code" "${BIN_DIR}/claude-docker"
    ln -s "${PREFIX}/bin/docker-code" "${BIN_DIR}/codex-docker"

    {
        echo "mode=${mode}"
        echo "repo=example/docker-code"
        echo "ref=master"
        echo "source=${REPO_ROOT}"
        echo "commit=aaa"
        echo "install_dir=${BIN_DIR}"
        echo "prefix=${PREFIX}"
    } >"${PREFIX}/.install-source"

    export INSTALLER_CALLS="${BATS_TEST_TMPDIR}/installer.calls"
    # shellcheck disable=SC2016
    printf '%s\n' '#!/bin/bash' \
        'echo "$@" >>"${INSTALLER_CALLS}"' \
        'while [ "$#" -gt 0 ]; do [ "$1" = --prefix ] && p="$2"; shift; done' \
        'sed -i "s/^commit=.*/commit=bbb/" "${p}/.install-source"' \
        '[ -z "${NEW_VERSION_CALLS:-}" ] || cp "${NEW_VERSION}" "${p}/bin/docker-code"' \
        >"${PREFIX}/install.sh"

    # What the installer puts in place when a test asks for it: a "new version" that only records
    # the name it was started under and each argument, bracketed so a split argument would show.
    NEW_VERSION="${BATS_TEST_TMPDIR}/new-docker-code"
    printf '%s\n' '#!/bin/bash' \
        'printf "%s" "$(basename "$0")" >"${NEW_VERSION_CALLS}"' \
        'printf " [%s]" "$@" >>"${NEW_VERSION_CALLS}"' >"${NEW_VERSION}"
    chmod +x "${NEW_VERSION}"
    export NEW_VERSION
}

session_runs() {
    stub_calls docker | grep -c '^run ' || true
}

pulls() {
    stub_calls docker | grep -c '^pull ' || true
}

@test "the first start of the day updates docker-code and starts the new one with the same arguments" {
    fake_install
    export NEW_VERSION_CALLS="${BATS_TEST_TMPDIR}/new-version.calls"
    run "${BIN_DIR}/claude-docker" -c --model "two words"
    [ "${status}" -eq 0 ]

    [ "$(wc -l <"${INSTALLER_CALLS}")" -eq 1 ]
    grep -q -- "--prefix ${PREFIX}" "${INSTALLER_CALLS}"
    grep -q -- "--dir ${BIN_DIR}" "${INSTALLER_CALLS}"
    grep -q -- "--ref master" "${INSTALLER_CALLS}"
    [[ "${output}" == *"updating docker-code"* ]]

    # The new version took over under the wrapper name, with every argument intact, and the old one
    # started nothing itself.
    [ "$(cat "${NEW_VERSION_CALLS}")" = "claude-docker [-c] [--model] [two words]" ]
    [ "$(session_runs)" -eq 0 ]
}

@test "the restarted process does not check docker-code a second time" {
    fake_install
    run "${BIN_DIR}/claude-docker" -c
    [ "${status}" -eq 0 ]
    [ "$(wc -l <"${INSTALLER_CALLS}")" -eq 1 ]
    [ "$(stub_calls git | wc -l)" -eq 1 ]
    [ "$(session_runs)" -eq 1 ]
    stub_calls docker | grep '^run ' | grep -q -- ' -c$'
}

@test "a later start the same day checks nothing" {
    fake_install
    run "${BIN_DIR}/claude-docker"
    [ "${status}" -eq 0 ]
    stub_reset_calls git
    stub_reset_calls docker
    rm -f "${INSTALLER_CALLS}"

    run "${BIN_DIR}/claude-docker"
    [ "${status}" -eq 0 ]
    [ ! -f "${STUB_DIR}/git.calls" ]
    [ ! -f "${INSTALLER_CALLS}" ]
    [ "$(pulls)" -eq 0 ]
    [ "$(session_runs)" -eq 1 ]
}

@test "yesterday's check does not count today" {
    fake_install
    mkdir -p "${DOCKER_CODE_HOME}/.auto-update"
    touch "${DOCKER_CODE_HOME}/.auto-update/self.2000-01-01"

    run "${BIN_DIR}/claude-docker"
    [ "${status}" -eq 0 ]
    [ -f "${INSTALLER_CALLS}" ]
    [ ! -f "${DOCKER_CODE_HOME}/.auto-update/self.2000-01-01" ]
}

@test "the installed commit being the latest one installs nothing" {
    fake_install
    printf 'aaa\trefs/heads/master\n' >"${BATS_TEST_TMPDIR}/ls-remote"
    run "${BIN_DIR}/claude-docker"
    [ "${status}" -eq 0 ]
    stub_called git
    [ ! -f "${INSTALLER_CALLS}" ]
    [ "$(session_runs)" -eq 1 ]
}

@test "the peeled commit of an annotated tag is the one compared" {
    fake_install
    printf 'tagobj\trefs/tags/master\naaa\trefs/tags/master^{}\n' >"${BATS_TEST_TMPDIR}/ls-remote"
    run "${BIN_DIR}/claude-docker"
    [ "${status}" -eq 0 ]
    [ ! -f "${INSTALLER_CALLS}" ]
}

@test "a ref the remote does not list, such as a pinned commit, is left alone" {
    fake_install
    : >"${BATS_TEST_TMPDIR}/ls-remote"
    run "${BIN_DIR}/claude-docker"
    [ "${status}" -eq 0 ]
    [ ! -f "${INSTALLER_CALLS}" ]
    [ "$(session_runs)" -eq 1 ]
}

@test "an unreachable remote is a warning, and the session still starts" {
    fake_install
    make_stub git 'exit 1'
    run "${BIN_DIR}/claude-docker"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"could not check"* ]]
    [ ! -f "${INSTALLER_CALLS}" ]
    [ "$(session_runs)" -eq 1 ]
}

@test "a failed installer is a warning, and the session still starts" {
    fake_install
    printf '#!/bin/bash\necho "clone failed"\nexit 1\n' >"${PREFIX}/install.sh"
    run "${BIN_DIR}/claude-docker"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"update of docker-code failed"* ]]
    [[ "${output}" == *"clone failed"* ]]
    [ "$(session_runs)" -eq 1 ]
}

@test "an installation from a checkout is never updated automatically" {
    fake_install local
    run "${BIN_DIR}/claude-docker"
    [ "${status}" -eq 0 ]
    [ ! -f "${STUB_DIR}/git.calls" ]
    [ ! -f "${INSTALLER_CALLS}" ]
}

@test "a checkout is never updated automatically" {
    run "${REPO_ROOT}/bin/docker-code" run claude
    [ "${status}" -eq 0 ]
    [ ! -f "${STUB_DIR}/git.calls" ]
    [ "$(session_runs)" -eq 1 ]
}

@test "AUTO_UPDATE=0 checks neither docker-code nor the image" {
    fake_install
    export DOCKER_CODE_AUTO_UPDATE=0
    run "${BIN_DIR}/claude-docker"
    [ "${status}" -eq 0 ]
    [ ! -f "${STUB_DIR}/git.calls" ]
    [ "$(pulls)" -eq 0 ]
    [ "$(session_runs)" -eq 1 ]
}

@test "AUTO_UPDATE_SELF=0 still checks the image" {
    fake_install
    export DOCKER_CODE_AUTO_UPDATE_SELF=0
    run "${BIN_DIR}/claude-docker"
    [ "${status}" -eq 0 ]
    [ ! -f "${STUB_DIR}/git.calls" ]
    [ "$(pulls)" -eq 1 ]
}

@test "AUTO_UPDATE_IMAGE=0 still checks docker-code" {
    fake_install
    export DOCKER_CODE_AUTO_UPDATE_IMAGE=0
    run "${BIN_DIR}/claude-docker"
    [ "${status}" -eq 0 ]
    [ -f "${INSTALLER_CALLS}" ]
    [ "$(pulls)" -eq 0 ]
}

@test "the image check is once a day per image" {
    run "${REPO_ROOT}/bin/docker-code" run claude
    [ "${status}" -eq 0 ]
    [ "$(pulls)" -eq 1 ]
    stub_calls docker | grep -q '^pull ruepp/docker-code-claude:test$'

    run "${REPO_ROOT}/bin/docker-code" run claude
    [ "$(pulls)" -eq 1 ]

    # Another agent's image has not been checked yet today.
    run "${REPO_ROOT}/bin/docker-code" run codex
    [ "$(pulls)" -eq 2 ]
    stub_calls docker | grep -q '^pull ruepp/docker-code-codex:test$'
}

@test "the image check has a per-agent switch" {
    export DOCKER_CODE_CLAUDE_AUTO_UPDATE_IMAGE=0
    run "${REPO_ROOT}/bin/docker-code" run claude
    [ "$(pulls)" -eq 0 ]
    run "${REPO_ROOT}/bin/docker-code" run codex
    [ "$(pulls)" -eq 1 ]
}

@test "the per-agent switch can turn the image check back on under AUTO_UPDATE=0" {
    export DOCKER_CODE_AUTO_UPDATE=0 DOCKER_CODE_CLAUDE_AUTO_UPDATE_IMAGE=1
    run "${REPO_ROOT}/bin/docker-code" run claude
    [ "$(pulls)" -eq 1 ]
}

@test "a newer image is reported once it is pulled" {
    # shellcheck disable=SC2016
    make_stub docker 'case "$1 $2" in
    "image inspect")
        case "$*" in
            *RepoDigests*) echo "ruepp/docker-code-claude@sha256:1" ;;
            *.Id*) if grep -q "^pull" "'"${STUB_DIR}"'/docker.calls"; then echo new; else echo old; fi ;;
        esac ;;
esac'
    run "${REPO_ROOT}/bin/docker-code" run claude
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"updated ruepp/docker-code-claude:test"* ]]
}

@test "an image built on this machine is not replaced by the published one" {
    export FAKE_DIGEST=""
    run "${REPO_ROOT}/bin/docker-code" run claude
    [ "${status}" -eq 0 ]
    [ "$(pulls)" -eq 0 ]
    [ "$(session_runs)" -eq 1 ]
}

@test "PULL=never is respected by the image check" {
    export DOCKER_CODE_PULL=never
    run "${REPO_ROOT}/bin/docker-code" run claude
    [ "$(pulls)" -eq 0 ]
}

@test "a failed image check is a warning, and the session still starts" {
    # shellcheck disable=SC2016
    make_stub docker 'case "$1 $2" in
    "image inspect") case "$*" in *RepoDigests*) echo "x@sha256:1" ;; *.Id*) echo id ;; esac ;;
    "pull "*) exit 1 ;;
esac'
    run "${REPO_ROOT}/bin/docker-code" run claude
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"could not check for a newer"* ]]
    [ "$(session_runs)" -eq 1 ]
}

@test "a dry run checks nothing" {
    fake_install
    export DOCKER_CODE_DRY_RUN=1
    run "${BIN_DIR}/claude-docker"
    [ "${status}" -eq 0 ]
    [ ! -f "${STUB_DIR}/git.calls" ]
    [ ! -f "${INSTALLER_CALLS}" ]
    [ "$(pulls)" -eq 0 ]
    [ ! -d "${DOCKER_CODE_HOME}/.auto-update" ]
}

@test "install.sh records the commit it installed, for the daily check to compare against" {
    grep -q '^        echo "commit=' "${REPO_ROOT}/install.sh"
}
