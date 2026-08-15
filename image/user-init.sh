#!/bin/bash
# Second half of the entrypoint chain: runs as the unprivileged `agent` user.
#
# Everything that must not have root belongs here. That is currently one thing — the rootless Docker
# daemon — but it is the reason the chain is split at all: a rootless dockerd started by root is not
# rootless, so it cannot live in entrypoint.sh.
set -euo pipefail

DIND_MODE="${DOCKER_CODE_DIND:-privileged}"
LOG_DIR="${HOME}/.docker-code"
DOCKERD_LOG="${LOG_DIR}/dockerd.log"

start_rootless_dockerd() {
    mkdir -p "${LOG_DIR}"

    if [ ! -x /usr/bin/dockerd-rootless.sh ]; then
        echo "docker-code: docker-ce-rootless-extras is missing from this image" >&2
        return 1
    fi

    # dockerd-rootless.sh refuses to start as root, and the container is root whenever the host user
    # is. The wrapper normally picks privileged mode in that case, so reaching this is a sign the
    # container was started by hand.
    if [ "$(id -u)" -eq 0 ]; then
        echo "docker-code: this container runs as root, so the rootless daemon cannot start." >&2
        echo "             Start it with DOCKER_CODE_DIND=privileged instead." >&2
        return 1
    fi

    # Started in the background and deliberately not waited on. The daemon needs a couple of seconds
    # and almost no session touches Docker in its first prompt, so blocking here would tax every
    # start for a feature most sessions never use. DOCKER_CODE_DIND_WAIT buys the guarantee back for
    # scripted runs that do need `docker` immediately.
    local dockerd_args=()
    if [ -n "${DOCKER_CODE_MIRROR_URL:-}" ]; then
        dockerd_args=(--registry-mirror "${DOCKER_CODE_MIRROR_URL}")

        # Plain HTTP has to be declared per host, or the pull fails with "server gave HTTP response
        # to HTTPS client". Only 127.0.0.0/8 is exempt by default.
        case "${DOCKER_CODE_MIRROR_URL}" in
            http://*)
                local mirror_host="${DOCKER_CODE_MIRROR_URL#http://}"
                dockerd_args+=(--insecure-registry "${mirror_host%%/*}")
                ;;
        esac

        echo "docker-code: Docker Hub pulls go through the mirror at ${DOCKER_CODE_MIRROR_URL}" >&2
    fi

    # Mirrors for registries other than Hub are addressed by name and need the same exemption.
    local host hosts
    hosts="${DOCKER_CODE_INSECURE_REGISTRIES:-}"
    for host in ${hosts//,/ }; do
        dockerd_args+=(--insecure-registry "${host}")
    done

    (
        exec >>"${DOCKERD_LOG}" 2>&1
        echo "=== dockerd-rootless started $(date -Is) ==="
        exec /usr/bin/dockerd-rootless.sh "${dockerd_args[@]}"
    ) &
    local dockerd_pid=$!

    local wait_secs="${DOCKER_CODE_DIND_WAIT:-0}"
    if [ "${wait_secs}" -gt 0 ] 2>/dev/null; then
        wait_for_dockerd "${wait_secs}" "${dockerd_pid}" && return 0

        if ! docker version >/dev/null 2>&1; then
            report_dockerd_failure
            return 1
        fi
    fi

    return 0
}

# Poll until `docker version` answers, the daemon process is gone, or the budget runs out. The second
# argument is optional: the privileged daemon belongs to root in the other half of the entrypoint
# chain, so there is no pid here to watch — only the socket.
wait_for_dockerd() {
    local budget="$1"
    local pid="${2:-}"
    local waited=0

    while [ "${waited}" -lt "${budget}" ]; do
        if docker version >/dev/null 2>&1; then
            return 0
        fi
        if [ -n "${pid}" ] && ! kill -0 "${pid}" 2>/dev/null; then
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    docker version >/dev/null 2>&1
}

# Rootless Docker needs unprivileged user namespaces, and a hardened host kernel or a restrictive
# AppArmor profile can refuse them. That failure surfaces deep inside rootlesskit's output, so name
# the way out here rather than leaving the user to decode the log.
report_dockerd_failure() {
    {
        echo "docker-code: the rootless Docker daemon did not come up."
        echo "             Log: ${DOCKERD_LOG}"
        echo "             Usual cause: the host restricts unprivileged user namespaces, so"
        echo "             rootlesskit cannot write its uid map."
        echo "             Fallbacks: DOCKER_CODE_DIND=rootless-privileged  (daemon stays"
        echo "                        unprivileged, container gets --privileged)"
        echo "                        DOCKER_CODE_DIND=privileged           (classic dind, default)"
        echo "                        DOCKER_CODE_DIND=0                    (no inner Docker)"
    } >&2
}

case "${DIND_MODE}" in
    1|true|auto|rootless|rootless-privileged)
        # A failing daemon must not take the session with it: the agent is still useful without
        # Docker, and the user gets the diagnosis either from stderr or from the log.
        start_rootless_dockerd || true
        ;;
    privileged)
        # Already started by entrypoint.sh as root; DOCKER_HOST was exported there. Only the wait is
        # left to do, and it belongs here rather than in the entrypoint: blocking there would delay
        # every session, including the ones that never touch Docker.
        wait_secs="${DOCKER_CODE_DIND_WAIT:-0}"
        if [ "${wait_secs}" -gt 0 ] 2>/dev/null; then
            wait_for_dockerd "${wait_secs}" || {
                echo "docker-code: the privileged Docker daemon did not come up within ${wait_secs}s." >&2
                echo "             Log: ${DOCKERD_LOG}" >&2
            }
        fi
        ;;
    0|false|none)
        ;;
    *)
        echo "docker-code: unknown DOCKER_CODE_DIND='${DIND_MODE}', starting without inner Docker" >&2
        ;;
esac

exec /usr/local/bin/launch.sh "$@"
