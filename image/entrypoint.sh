#!/bin/bash
# First half of the entrypoint chain: runs as root, PID 1's child (tini is PID 1).
#
# Only the things that genuinely need root live here — matching the container user to the host user,
# seeding the home directory, the optional privileged Docker daemon, the egress firewall and the
# port bridge to the shared model services. It then drops to `agent` and never comes back, because
# several of these CLIs refuse to bypass their permission prompts when they run as root.
set -euo pipefail

AGENT_USER="agent"
AGENT_HOME="/home/${AGENT_USER}"
DEFAULTS_DIR="/opt/docker-code/defaults"
AGENT_ENV_FILE="/etc/docker-code/agent.env"

# Which tool this image holds. Written by the agent's Dockerfile; only used for messages here.
AGENT_ID="$(sed -n 's/^AGENT_ID=//p' "${AGENT_ENV_FILE}" 2>/dev/null | head -n 1)"
AGENT_ID="${AGENT_ID:-agent}"

log() { echo "docker-code[${AGENT_ID}]: $*" >&2; }

# Someone can always start this image with `docker run --user`, in which case none of the root work
# below is possible — and none of it is needed either, since that user was chosen deliberately.
if [ "$(id -u)" -ne 0 ]; then
    exec /usr/local/bin/user-init.sh "$@"
fi

# ---------------------------------------------------------------------------------------------
# Match the container user to the host user
#
# Files the agent writes land in the bind-mounted workspace, which is the host's filesystem. Without
# this the host ends up owning its own project files as uid 1000, or not owning them at all.
# ---------------------------------------------------------------------------------------------
RUN_AS_ROOT=0

# The filesystem type behind a mount point, straight from mountinfo. `stat -f` would be shorter but
# prints "UNKNOWN (0x…)" for exactly the filesystems this needs to recognize.
mount_fstype() {
    awk -v target="$1" '
        $5 == target {
            for (i = 6; i <= NF; i++) {
                if ($i == "-") { fstype = $(i + 1); break }
            }
        }
        END { print fstype }
    ' /proc/self/mountinfo 2>/dev/null
}

# Whether the owner the container sees on the home directory is a real, stored uid.
#
# On a macOS host it is not. Docker Desktop and OrbStack share the directory into their Linux VM
# through virtiofs or a FUSE bridge, and the uid on every file there is synthesized by the mount
# driver: it does not match the container user, chown does not change it, and access is granted
# regardless of what the numbers say. Adopting such a mount is worse than useless — the reported
# owner never changes, so the walk would repeat on every single start.
home_ownership_is_synthetic() {
    case "$(mount_fstype "${AGENT_HOME}")" in
        virtiofs|9p|osxfs|grpcfuse|fuse|fuse.*) return 0 ;;
        *) return 1 ;;
    esac
}

# mkdir plus a best-effort chown. The home directory is a bind mount from the host and may sit on a
# filesystem that refuses ownership changes even to root — a shared macOS directory does. That must
# not be fatal: the directory itself is what the daemon and the tool need, and on those mounts the
# user can write it no matter who it claims to belong to.
ensure_owned_dir() {
    local dir="$1"
    local mode="${2:-0755}"
    mkdir -p "${dir}"
    chmod "${mode}" "${dir}" 2>/dev/null || true
    chown "${AGENT_USER}:${AGENT_USER}" "${dir}" 2>/dev/null || true
}

# The recursive adoption, with the inner Docker store left alone.
#
# Two reasons to skip it. Its contents belong to the subuid range the rootless daemon maps, not to
# the container user, so flattening them to agent:agent corrupts the store. And it is the one
# subtree that can hold directories no one may traverse — overlayfs work directories are mode 000 —
# which on a host-shared mount stops even root and would otherwise abort the whole startup.
adopt_home() {
    local uid gid
    uid="$(id -u "${AGENT_USER}")"
    gid="$(id -g "${AGENT_USER}")"

    if ! find "${AGENT_HOME}" -path "${AGENT_HOME}/.local/share/docker" -prune \
        -o -exec chown -h "${uid}:${gid}" {} + 2>/dev/null; then
        log "some files under ${AGENT_HOME} could not be adopted; continuing"
    fi
}

align_user_ids() {
    local target_uid="${DOCKER_CODE_HOST_UID:-}"
    local target_gid="${DOCKER_CODE_HOST_GID:-}"
    local current_uid current_gid
    current_uid="$(id -u "${AGENT_USER}")"
    current_gid="$(id -g "${AGENT_USER}")"

    # A root host is the one case where the ids cannot both be matched and dropped. Keeping the
    # container on uid 1000 would leave the workspace — owned by root on the host — unwritable, and
    # an agent that cannot edit your files is no agent at all. So the container stays root as well.
    #
    # The cost is that some CLIs refuse their bypass flag as root; launch.sh handles that per tool.
    if [ "${target_uid}" = "0" ]; then
        log "host runs as root, so this container does too — otherwise your workspace is read-only"
        RUN_AS_ROOT=1
        export HOME="${AGENT_HOME}"
        return 0
    fi

    if [ -n "${target_gid}" ] && [ "${target_gid}" != "${current_gid}" ]; then
        # -o because the target gid may already belong to a system group in this image.
        groupmod -o -g "${target_gid}" "${AGENT_USER}"
    fi

    if [ -n "${target_uid}" ] && [ "${target_uid}" != "${current_uid}" ]; then
        usermod -o -u "${target_uid}" "${AGENT_USER}"
    fi

    # chown only on an actual mismatch. The home directory grows with every session transcript, and a
    # recursive chown on every container start is a cost paid for nothing in the common case where
    # the ids already line up.
    local owner
    owner="$(stat -c %u "${AGENT_HOME}")"
    if [ "${owner}" = "$(id -u "${AGENT_USER}")" ]; then
        return 0
    fi

    if home_ownership_is_synthetic; then
        log "${AGENT_HOME} is a $(mount_fstype "${AGENT_HOME}") mount from the host, which maps"
        log "ownership itself — leaving it as it is"
        return 0
    fi

    log "adopting ${AGENT_HOME} for uid $(id -u "${AGENT_USER}") (this runs once)"
    adopt_home
}

# ---------------------------------------------------------------------------------------------
# Seed the home directory — never overwrite
#
# The defaults live in /opt rather than in the image's home directory on purpose. Docker does not
# copy the image's version of a bind-mounted path into the mount the way it seeds an empty named
# volume, so a first run starts with a bare directory. Copying here also means a new default file
# added in a later image release still arrives, while anything the user already has stays exactly as
# they left it.
# ---------------------------------------------------------------------------------------------
seed_home() {
    local src dest
    for src in /etc/skel/.*; do
        [ -f "${src}" ] || continue
        dest="${AGENT_HOME}/$(basename "${src}")"
        if [ ! -e "${dest}" ]; then
            cp -a "${src}" "${dest}"
            chown "${AGENT_USER}:${AGENT_USER}" "${dest}" 2>/dev/null || true
        fi
    done

    # Rootless Docker keeps its image store here. It can create the directory itself, but only once
    # the parents exist and belong to the user. Classic dind has its store on /var/lib/docker and
    # never looks at this path, so there is no reason to create it there.
    case "${DOCKER_CODE_DIND:-privileged}" in
        0|false|none|privileged) ;;
        *)
            ensure_owned_dir "${AGENT_HOME}/.local"
            ensure_owned_dir "${AGENT_HOME}/.local/share"
            ensure_owned_dir "${AGENT_HOME}/.local/share/docker"
            ;;
    esac
}

# ---------------------------------------------------------------------------------------------
# Per-agent defaults
#
# /opt/docker-code/defaults mirrors the home directory, so an agent seeds wherever its tool actually
# looks — .codex/config.toml, .config/opencode/opencode.json, .claude/settings.json — without this
# script knowing anything about any of them. That is what keeps "add a folder" true for tool number
# eight.
#
# Copy semantics are per file, not per directory: a user who already has .config/opencode/ must
# still receive a new default that lands beside their own files.
# ---------------------------------------------------------------------------------------------
seed_defaults() {
    [ -d "${DEFAULTS_DIR}" ] || return 0

    local src rel dest
    while IFS= read -r src; do
        rel="${src#"${DEFAULTS_DIR}"/}"
        dest="${AGENT_HOME}/${rel}"
        [ -e "${dest}" ] && continue

        ensure_owned_dir "$(dirname "${dest}")"
        cp -a "${src}" "${dest}"
        chown "${AGENT_USER}:${AGENT_USER}" "${dest}" 2>/dev/null || true
    done <<EOF
$(find "${DEFAULTS_DIR}" -type f 2>/dev/null)
EOF
}

# XDG_RUNTIME_DIR has to exist and belong to the user before rootless Docker starts: that is where
# rootlesskit puts its socket.
prepare_runtime_dir() {
    local uid
    uid="$(id -u "${AGENT_USER}")"
    export XDG_RUNTIME_DIR="/run/user/${uid}"
    install -d -o "${AGENT_USER}" -g "${AGENT_USER}" -m 0700 "${XDG_RUNTIME_DIR}"
    export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/docker.sock"
}

# The fallback for hosts where rootless Docker cannot run, and the default because it is the mode
# that works everywhere. It is a real inner daemon either way — what changes is that this one is
# root inside a privileged container, so the container itself stops being a boundary against the
# host. README.md says so in as many words.
start_privileged_dockerd() {
    local log_dir="${AGENT_HOME}/.docker-code"
    ensure_owned_dir "${log_dir}"

    local dockerd_args
    dockerd_args=(--host=unix:///var/run/docker.sock --group docker)

    # The wrapper passes this when it has a pull-through cache running for the session to share.
    # A flag rather than a daemon.json: the file would have to be written into the bind-mounted
    # home, where it would outlive the mirror it names.
    if [ -n "${DOCKER_CODE_MIRROR_URL:-}" ]; then
        dockerd_args+=(--registry-mirror "${DOCKER_CODE_MIRROR_URL}")

        # A plain-HTTP mirror is refused as "server gave HTTP response to HTTPS client" unless the
        # daemon is told it may talk to that one host in the clear. Only 127.0.0.0/8 is exempt by
        # default, and the mirror is reached by container name on a bridge network.
        case "${DOCKER_CODE_MIRROR_URL}" in
            http://*)
                local mirror_host="${DOCKER_CODE_MIRROR_URL#http://}"
                dockerd_args+=(--insecure-registry "${mirror_host%%/*}")
                ;;
        esac

        log "Docker Hub pulls go through the mirror at ${DOCKER_CODE_MIRROR_URL}"
    fi

    # Mirrors for registries other than Hub have to be addressed by name, so their hosts need the
    # same exemption. See REGISTRY.md.
    local host hosts
    hosts="${DOCKER_CODE_INSECURE_REGISTRIES:-}"
    for host in ${hosts//,/ }; do
        dockerd_args+=(--insecure-registry "${host}")
    done

    log "starting the privileged Docker daemon"
    (
        exec >>"${log_dir}/dockerd.log" 2>&1
        echo "=== dockerd (privileged) started $(date -Is) ==="
        exec dockerd "${dockerd_args[@]}"
    ) &

    export DOCKER_HOST="unix:///var/run/docker.sock"
}

align_user_ids
seed_home
seed_defaults
prepare_runtime_dir

if [ "${DOCKER_CODE_DIND:-privileged}" = "privileged" ]; then
    start_privileged_dockerd
fi

# Before the firewall, so the bridge's listeners exist while the allowlist is still permissive, and
# because the loopback ports it opens are what the agent's local-model config points at.
if [ -n "${DOCKER_CODE_LOCAL_URL:-}" ]; then
    /usr/local/bin/local-models.sh || log "the local-model bridge did not start; continuing"
fi

# After the daemon, so its own iptables chains already exist when the firewall takes inventory.
if [ "${DOCKER_CODE_NET:-full}" = "restricted" ]; then
    /usr/local/bin/init-firewall.sh
fi

if [ "${RUN_AS_ROOT}" = "1" ]; then
    exec /usr/local/bin/user-init.sh "$@"
fi

# gosu rather than su: no intermediate shell, no extra process, signals and the TTY pass straight
# through to the agent.
exec gosu "${AGENT_USER}" /usr/local/bin/user-init.sh "$@"
