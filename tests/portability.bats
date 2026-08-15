#!/usr/bin/env bats
# Everything on the host side has to run under the bash macOS ships, which is 3.2 from 2007.
#
# This is a scanner rather than a real macOS run: the suite runs in a Linux container, where every
# bash-4 feature and every GNU flag works and nothing would ever fail. The failures it prevents all
# look the same from a user's side — the wrapper dies on line 1 with a syntax error, on the platform
# none of us tested on.

load helper

# Only the scripts a user runs on their own machine. The image scripts run inside Ubuntu, where bash
# is 5.x and coreutils are GNU, so holding them to this would be pointless.
host_scripts() {
    printf '%s\n' \
        "${REPO_ROOT}/bin/docker-code" \
        "${REPO_ROOT}/lib/agents.sh" \
        "${REPO_ROOT}/lib/models.sh" \
        "${REPO_ROOT}/lib/mirror.sh" \
        "${REPO_ROOT}/install.sh" \
        "${REPO_ROOT}/scripts/build.sh"
}

scan() {
    local pattern="$1" what="$2" file hit
    while IFS= read -r file; do
        # The line-number prefix from -n has to be skipped before deciding whether the line is a
        # comment; without that, every explanation of why a construct is avoided reports itself.
        hit="$(grep -nE "${pattern}" "${file}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
        if [ -n "${hit}" ]; then
            echo "${file}: ${what}"
            echo "${hit}"
            return 1
        fi
    done <<EOF
$(host_scripts)
EOF
    return 0
}

@test "no bash 4 builtins" {
    # mapfile, readarray and declare -A do not exist in 3.2; ${x,,} is a syntax error there, which
    # means the script does not even parse.
    run scan '(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)' 'uses mapfile/readarray'
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }

    run scan 'declare -A' 'uses an associative array'
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }

    run scan '\$\{[A-Za-z_][A-Za-z0-9_]*,,' 'uses ${x,,} case conversion'
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }

    run scan '\$\{[A-Za-z_][A-Za-z0-9_]*\^\^' 'uses ${x^^} case conversion'
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
}

@test "no GNU-only command flags" {
    # BSD versions of these take different arguments or do not have the flag at all.
    run scan 'sed -i[^.]' 'uses sed -i without a backup suffix (BSD sed needs one)'
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }

    run scan 'stat -c' 'uses stat -c (BSD stat uses -f)'
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }

    run scan 'readlink -f' 'uses readlink -f (BSD readlink has no -f)'
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }

    run scan 'grep -P' 'uses grep -P (BSD grep has no PCRE)'
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }

    run scan 'date -Is' 'uses date -Is (BSD date has no -I)'
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
}

@test "mktemp is always given a template" {
    # BSD mktemp requires one; GNU does not, so a bare call passes every test on Linux.
    run scan 'mktemp( -d)?[[:space:]]*$' 'calls mktemp without a template'
    [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
}

@test "/proc is never read without a fallback" {
    # macOS has no /proc at all, so an unguarded read makes the script exit under `set -e`.
    while IFS= read -r file; do
        hits="$(grep -n '/proc/' "${file}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
        [ -n "${hits}" ] || continue
        while IFS= read -r line; do
            [ -n "${line}" ] || continue
            case "${line}" in
                *'2>/dev/null'*|*'|| echo'*|*'|| true'*) ;;
                *) echo "${file}: unguarded /proc read: ${line}"; return 1 ;;
            esac
        done <<EOF
${hits}
EOF
    done <<EOF
$(host_scripts)
EOF
}

@test "/dev/fuse is only offered when it exists" {
    # Passing a device the host does not have is a hard `docker run` error, and macOS never has it.
    grep -q '\[ -e /dev/fuse \]' "${REPO_ROOT}/bin/docker-code"
}

@test "macOS gets a Docker volume for the inner image store" {
    # The state directory is shared into the Linux VM through virtiofs, and no overlay driver can use
    # such a filesystem as its upper layer — the daemon dies at graphdriver init, which looks exactly
    # like "the daemon is not running".
    grep -q 'uname -s.*Darwin' "${REPO_ROOT}/bin/docker-code"
}

@test "the scanner can actually fail" {
    # A scanner that never fires is indistinguishable from one that is broken.
    bad="${BATS_TEST_TMPDIR}/bad.sh"
    printf '#!/bin/bash\nmapfile -t x < /dev/null\n' >"${bad}"
    host_scripts() { printf '%s\n' "${bad}"; }

    run scan '(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)' 'uses mapfile/readarray'
    [ "${status}" -ne 0 ]
}
