#!/bin/bash
# Makes the shared model services reachable at localhost inside the container.
#
# Why a port bridge rather than just handing every tool the service's hostname: several of these CLIs
# hard-code localhost for local models. Codex's --oss path ignores base_url entirely
# (openai/codex#8240), and more than one provider integration assumes 127.0.0.1 somewhere below its
# config surface. Forwarding the ports means the tools are simply right, and a tool added later
# inherits the same assumption working.
#
# Runs as root from entrypoint.sh, before the firewall, and never fails the session: no local models
# is a worse session, not a broken one.
set -euo pipefail

BRIDGE="${DOCKER_CODE_LOCAL_BRIDGE:-}"
LOG_DIR="/home/agent/.docker-code"
LOG="${LOG_DIR}/local-models.log"

[ -n "${BRIDGE}" ] || exit 0

mkdir -p "${LOG_DIR}"
chown agent:agent "${LOG_DIR}" 2>/dev/null || true

{
    echo "=== local-model bridge started $(date -Is) ==="
} >>"${LOG}" 2>&1

# Each entry is <local-port>:<host>:<port>, e.g. 11434:docker-code-ollama:11434
for spec in ${BRIDGE}; do
    local_port="${spec%%:*}"
    remainder="${spec#*:}"
    remote_host="${remainder%%:*}"
    remote_port="${remainder##*:}"

    case "${local_port}" in
        ''|*[!0-9]*)
            echo "docker-code: ignoring malformed bridge spec '${spec}'" >&2
            continue
            ;;
    esac

    if [ -z "${remote_host}" ] || [ -z "${remote_port}" ]; then
        echo "docker-code: ignoring malformed bridge spec '${spec}'" >&2
        continue
    fi

    # Bound to loopback only. The forward exists for the tools in this container; publishing it on
    # the container's other interfaces would hand it to anything else on the model network.
    (
        exec >>"${LOG}" 2>&1
        echo "--- forwarding 127.0.0.1:${local_port} -> ${remote_host}:${remote_port}"
        exec socat "TCP4-LISTEN:${local_port},bind=127.0.0.1,fork,reuseaddr" \
                   "TCP4:${remote_host}:${remote_port}"
    ) &
done

exit 0
