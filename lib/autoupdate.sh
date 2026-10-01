# shellcheck shell=bash
# The daily update check, run by the first session of the day.
#
# Two independent checks, in this order, each at most once per calendar day:
#
#   1. docker-code itself. A newer commit on the branch it was installed from is installed with the
#      recorded installer, and the session is started again by the new code with the same arguments.
#   2. The agent's image. A newer published image is pulled before the session starts.
#
# Sourced by bin/docker-code, which provides say, warn, with_progress, ensure_image, STORAGE_ROOT
# and SELF_INVOCATION.
#
# Every failure here degrades to a warning and a session on what is already installed. An update
# check is a convenience; it must never be the reason an agent does not start — not offline, not
# behind a proxy, not on a machine where somebody else owns the installation.

# Where the once-a-day markers live. In the state directory rather than in the installation, because
# an installation made with --system is shared and read-only to the people running it.
#
# A function rather than a variable: this file is sourced before bin/docker-code has worked out
# STORAGE_ROOT.
auto_update_dir() {
    printf '%s\n' "${STORAGE_ROOT}/.auto-update"
}

auto_update_today() {
    date +%Y-%m-%d
}

# auto_update_claim <name>
#
# Succeeds for exactly one caller per name and day. The marker is created with noclobber, which is an
# atomic O_EXCL open: two sessions started in the same second cannot both win, so they cannot both
# run the installer over one prefix. The claim is made before the check rather than after it, so an
# offline morning costs one failed attempt instead of a timeout on every start until midnight.
auto_update_claim() {
    local name="$1" dir marker old
    dir="$(auto_update_dir)"
    marker="${dir}/${name}.$(auto_update_today)"

    mkdir -p "${dir}" 2>/dev/null || return 1
    ( set -C; : >"${marker}" ) 2>/dev/null || return 1

    # Yesterday's marker is no longer needed, and without this the directory grows by one file per
    # image and day for as long as docker-code is installed.
    for old in "${dir}/${name}".*; do
        [ "${old}" = "${marker}" ] || rm -f "${old}"
    done
    return 0
}

# Whether the check for docker-code itself is switched on. Global only: there is one installation,
# whichever agent happens to start first.
auto_update_self_enabled() {
    [ "${DOCKER_CODE_AUTO_UPDATE:-1}" != "0" ] && [ "${DOCKER_CODE_AUTO_UPDATE_SELF:-1}" != "0" ]
}

# install_record_field <record> <key>
install_record_field() {
    sed -n "s/^$2=//p" "$1" | head -n 1
}

# The commit a remote ref currently points at, or nothing.
#
# GIT_TERMINAL_PROMPT=0 so a private fork without credentials fails instead of waiting for a password
# nobody is going to type, and the low-speed limit so a network that accepts the connection and then
# goes quiet costs fifteen seconds rather than the TCP timeout.
#
# An annotated tag is listed twice, as the tag object and peeled (`^{}`) as the commit; the clone
# install.sh made checked out the commit, so the peeled line wins when there is one.
auto_update_remote_commit() {
    local remote="$1" ref="$2" refs
    refs="$(GIT_TERMINAL_PROMPT=0 git \
        -c http.lowSpeedLimit=1 -c http.lowSpeedTime=15 \
        ls-remote "${remote}" "refs/heads/${ref}" "refs/tags/${ref}" "refs/tags/${ref}^{}" \
        2>/dev/null)" || return 1
    printf '%s\n' "${refs}" | awk '$2 ~ /\^\{\}$/ { peeled = $1 } NR == 1 { first = $1 }
        END { if (peeled != "") print peeled; else if (first != "") print first }'
}

# auto_update_self <argv...>
#
# Called with the arguments this process was started with. Returns when there is nothing to do;
# otherwise it does not return, because the process is replaced by the updated command.
#
# Everything from the installer run to the exec happens inside this one function on purpose. The
# installer deletes the prefix this script was read from, and bash reads a script as it goes — but a
# function body has been parsed in full before it runs, so nothing after the install is read from a
# file that no longer exists.
auto_update_self() {
    auto_update_self_enabled || return 0

    # A checkout has no record and is updated with git by whoever works in it.
    local record="${DOCKER_CODE_ROOT}/.install-source"
    local installer="${DOCKER_CODE_ROOT}/install.sh"
    [ -f "${record}" ] && [ -f "${installer}" ] || return 0

    # A --local installation follows a checkout somebody is working in. Installing whatever state
    # that tree happens to be in every morning would ship half-finished work into every session, so
    # those are updated when their owner runs `docker-code self-update`.
    [ "$(install_record_field "${record}" mode)" = "remote" ] || return 0
    command -v git >/dev/null 2>&1 || return 0

    auto_update_claim self || return 0

    local repo ref installed latest prefix install_dir
    repo="$(install_record_field "${record}" repo)"
    ref="$(install_record_field "${record}" ref)"
    installed="$(install_record_field "${record}" commit)"
    prefix="$(install_record_field "${record}" prefix)"
    install_dir="$(install_record_field "${record}" install_dir)"
    [ -n "${repo}" ] && [ -n "${ref}" ] || return 0

    latest="$(auto_update_remote_commit "https://github.com/${repo}.git" "${ref}")" || {
        warn "could not check ${repo} for a newer docker-code; starting the installed one"
        return 0
    }

    # Nothing listed is how a pinned commit looks: ls-remote only knows branch and tag names, and an
    # installation pinned to a sha has asked not to move.
    [ -n "${latest}" ] || return 0

    # An installation from before the commit was recorded has no value here, and is updated once so
    # that the next check has something to compare against.
    [ "${latest}" != "${installed}" ] || return 0

    # Same refusal install.sh would give, made before anything is downloaded. Somebody else's
    # --system installation is theirs to update; say so once a day rather than fail at it.
    if [ ! -w "${prefix}" ] || [ ! -w "${install_dir}" ]; then
        say "a newer docker-code is available, but ${prefix} is not writable by you."
        say "Whoever installed it can update it: docker-code self-update"
        return 0
    fi

    say "updating docker-code (${repo}@${ref}: ${installed:0:7}${installed:+ -> }${latest:0:7})"

    # A copy of the installer, for the same reason cmd_self_update uses one: the original is inside
    # the directory the installer is about to replace. Its output goes to a log, because the
    # installer's closing advice is for somebody installing by hand, not for somebody who typed
    # claude-docker and is waiting for Claude.
    local tmp log status=0
    log="$(auto_update_dir)/self-update.log"
    tmp="$(mktemp "${TMPDIR:-/tmp}/docker-code-install.XXXXXX")" || {
        warn "cannot create a temp file; docker-code was not updated"
        return 0
    }
    cat "${installer}" >"${tmp}"

    DOCKER_CODE_REPO="${repo}" bash "${tmp}" --dir "${install_dir}" --prefix "${prefix}" \
        --ref "${ref}" >"${log}" 2>&1 || status=$?
    rm -f "${tmp}"

    if [ "${status}" -ne 0 ]; then
        warn "the update of docker-code failed; starting the installed one. Installer output:"
        tail -n 5 "${log}" | sed 's/^/    /' >&2
        warn "full log: ${log}"
        # No exec: the likely failure is the clone, before install.sh has touched the prefix, and
        # then this process is still the installed version. Even if the tree was replaced after all,
        # bash keeps reading from the file it opened, and every library is already sourced.
        return 0
    fi

    # Through the name the user typed, so the wrapper link resolves to the new tree — and with the
    # arguments exactly as they were given. The marker claimed above keeps the new process from
    # checking a second time.
    exec "${SELF_INVOCATION}" "$@"
}

# auto_update_image <image>
#
# Pulls a newer version of the image when one is published. Whether to check at all is decided by
# run_session, where every per-agent knob is resolved: DOCKER_CODE_CLAUDE_AUTO_UPDATE_IMAGE=0 keeps
# one agent on the image it has, and PULL=never is an explicit request not to touch the registry.
auto_update_image() {
    local image="$1" before after name

    # Not here yet: the normal first-start path, with its visible progress, rather than a spinner in
    # front of a download that can take minutes.
    if ! docker image inspect "${image}" >/dev/null 2>&1; then
        ensure_image "${image}" "${AGENT_TITLE:-${AGENT_ID}}" || true
        return 0
    fi

    # An image without a registry digest was built on this machine — `docker-code build` tags its
    # result with the same name the published one has. Pulling would replace the local build with
    # the published image every morning.
    if [ -z "$(docker image inspect --format '{{join .RepoDigests ""}}' "${image}" 2>/dev/null)" ]; then
        return 0
    fi

    name="$(printf '%s' "${image}" | tr -c 'A-Za-z0-9._-' '_')"
    auto_update_claim "image-${name}" || return 0

    before="$(docker image inspect --format '{{.Id}}' "${image}" 2>/dev/null || true)"
    with_progress "checking for a newer ${image}" docker pull "${image}" || {
        warn "could not check for a newer ${image}; starting the one you have"
        return 0
    }
    after="$(docker image inspect --format '{{.Id}}' "${image}" 2>/dev/null || true)"

    if [ -n "${after}" ] && [ "${before}" != "${after}" ]; then
        say "updated ${image}"
    fi
}
