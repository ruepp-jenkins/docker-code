# shellcheck shell=bash
# The pull-through cache in front of Docker Hub.
#
# Sessions cannot share an image store, but they can share what they pull. A registry running as a
# proxy turns the second, third and fourth pull of the same base image into a copy over the local
# bridge — and it is the answer to Hub's rate limit as well, because one account's credentials serve
# every session.
#
# Off by default: it is another container running on your machine, and that should be a decision
# rather than a surprise. See docs/REGISTRY.md.
#
# Deliberately a container on a network of its own rather than a published port: nothing new listens
# on the host, and the firewall in `restricted` mode already lets a container reach the networks it
# is attached to, so the mirror works there without punching a hole for it.

MIRROR_CONTAINER="${DOCKER_CODE_REGISTRY_CONTAINER:-docker-code-registry}"
MIRROR_NETWORK="${DOCKER_CODE_REGISTRY_NETWORK:-docker-code-mirror}"
MIRROR_LABEL="com.ruepp.docker-code"
MIRROR_UPSTREAM="${DOCKER_CODE_REGISTRY_UPSTREAM:-https://registry-1.docker.io}"
MIRROR_IMAGE="${DOCKER_CODE_REGISTRY_IMAGE:-registry:3}"

# Docker hands out its default pool a /16 at a time, in the order networks happen to be created — so
# the addresses a session runs on differ between machines and change as networks come and go. A fixed
# range is one you can name in a route, a firewall rule or a corporate exception. 172.30.30.0/24
# stays inside that same pool and sits far enough up the range that the default bridge and the first
# user-defined networks do not grow into it. The empty string hands the choice back to Docker.
MIRROR_SUBNET="${DOCKER_CODE_REGISTRY_SUBNET-172.30.30.0/24}"

# Unlike the single-agent original, which kept this in a sibling of the state directory, the cache
# lives inside ~/docker-code/registry — one directory for everything docker-code persists, which is
# what was asked for. It is still a plain directory you can measure with du and delete with rm.
mirror_store() { printf '%s\n' "${DOCKER_CODE_REGISTRY_HOME:-${STORAGE_ROOT%/}/registry/data}"; }

mirror_check_subnet() {
    [ -n "${MIRROR_SUBNET}" ] || return 0
    # A shape check only. Whether the range is usable here is Docker's judgement, and its message
    # about an overlap says more than anything this could work out in advance.
    case "${MIRROR_SUBNET}" in
        *[!0-9./]*|*/*/*|*/)
            die "DOCKER_CODE_REGISTRY_SUBNET must be an IPv4 CIDR like 172.30.30.0/24, not" \
                "'${MIRROR_SUBNET}'" ;;
        */*) ;;
        *) die "DOCKER_CODE_REGISTRY_SUBNET needs a prefix length: '${MIRROR_SUBNET}/24' rather" \
               "than '${MIRROR_SUBNET}'" ;;
    esac
}

mirror_create_network() {
    local err

    # A plain global, for the same reason as mirror_create below.
    mirror_network_create=(docker network create)
    [ -z "${MIRROR_SUBNET}" ] || mirror_network_create+=(--subnet "${MIRROR_SUBNET}")
    mirror_network_create+=("${MIRROR_NETWORK}")

    err="$("${mirror_network_create[@]}" 2>&1 >/dev/null)" && return 0

    # Losing the race to a session that started at the same moment is not a failure. A subnet that
    # overlaps something already routed here is, and Docker names it better than this could.
    docker network inspect "${MIRROR_NETWORK}" >/dev/null 2>&1 && return 0
    [ -z "${err}" ] || warn "${err}"
    return 1
}

# A subnet is fixed when the network is created, so a changed one means a new network. Rebuilding one
# that sessions are attached to would cut them off mid-run, and Docker refuses to remove it while
# they are — which is exactly the right answer: between sessions nothing is attached and the rebuild
# is free, and while one is running the addresses it is already talking over stay.
mirror_ensure_network() {
    local current

    if ! docker network inspect "${MIRROR_NETWORK}" >/dev/null 2>&1; then
        mirror_create_network
        return
    fi

    [ -n "${MIRROR_SUBNET}" ] || return 0

    current=" $(docker network inspect \
        -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "${MIRROR_NETWORK}" 2>/dev/null || true) "
    case "${current}" in
        *" ${MIRROR_SUBNET} "*) return 0 ;;
    esac

    if ! docker network rm "${MIRROR_NETWORK}" >/dev/null 2>&1; then
        warn "the ${MIRROR_NETWORK} network is still in use, so it keeps the subnet it was created"
        warn "with; ${MIRROR_SUBNET} applies once the last session on it has ended"
        return 0
    fi
    mirror_create_network
}

# Started on demand and reused, so the first session of the day pays for it and the rest do not.
mirror_start() {
    local running upstream store

    mirror_ensure_network || return 1
    store="$(mirror_store)"

    running="$(docker inspect -f '{{.State.Running}}' "${MIRROR_CONTAINER}" 2>/dev/null || true)"
    upstream="$(docker inspect -f "{{index .Config.Labels \"${MIRROR_LABEL}.upstream\"}}" \
        "${MIRROR_CONTAINER}" 2>/dev/null || true)"
    stored="$(docker inspect -f "{{index .Config.Labels \"${MIRROR_LABEL}.store\"}}" \
        "${MIRROR_CONTAINER}" 2>/dev/null || true)"

    # A changed upstream or a changed cache location means the container we have is not the one that
    # was asked for. What it cached stays where it is — a blob is keyed by digest, so it remains
    # valid for whoever picks that directory up again.
    if [ -n "${running}" ] &&
        { [ "${upstream}" != "${MIRROR_UPSTREAM}" ] || [ "${stored}" != "${store}" ]; }; then
        docker rm -f "${MIRROR_CONTAINER}" >/dev/null 2>&1 || true
        running=""
    fi

    case "${running}" in
        true) return 0 ;;
        false)
            # With --rm below, stopping one removes it; this is only reachable for a container left
            # behind by an older version. It carries nothing, so build a fresh one.
            docker rm -f "${MIRROR_CONTAINER}" >/dev/null 2>&1 || true
            ;;
    esac

    # A plain global rather than `local mirror_create=(...)`: array compound assignment to a local is
    # one of the places where the bash macOS ships still surprises people.
    mirror_create=(docker run --detach --rm
        --name "${MIRROR_CONTAINER}"
        --network "${MIRROR_NETWORK}"
        --label "${MIRROR_LABEL}=registry"
        --label "${MIRROR_LABEL}.upstream=${MIRROR_UPSTREAM}"
        --label "${MIRROR_LABEL}.store=${store}"
        --volume "$(prepare_store "${store}"):/var/lib/registry"
        --env "REGISTRY_PROXY_REMOTEURL=${MIRROR_UPSTREAM}")

    # The registry image runs as root. Against a directory in your home that would leave you with
    # root-owned blobs you cannot delete, so it runs as you instead — but only for a directory: a
    # fresh Docker volume is created root-owned from the image, and a non-root registry could not
    # write into it.
    case "${store}" in
        /*) mirror_create+=(--user "$(id -u):$(id -g)") ;;
    esac

    # Hub's rate limit counts anonymous pulls per IP, which on a shared connection is everyone at
    # once. One account on the mirror lifts it for every session behind it.
    if [ -n "${DOCKER_CODE_REGISTRY_USERNAME:-}" ]; then
        mirror_create+=(--env "REGISTRY_PROXY_USERNAME=${DOCKER_CODE_REGISTRY_USERNAME}")
        mirror_create+=(--env "REGISTRY_PROXY_PASSWORD=${DOCKER_CODE_REGISTRY_PASSWORD:-}")
    fi

    mirror_create+=("${MIRROR_IMAGE}")

    "${mirror_create[@]}" >/dev/null 2>&1 && return 0

    # Losing a race against another session that created it first is not a failure.
    [ "$(docker inspect -f '{{.State.Running}}' "${MIRROR_CONTAINER}" 2>/dev/null || true)" = "true" ]
}

# The last session out turns off the light. Sessions are counted by label — across every agent,
# not per agent — so a claude session still running keeps the mirror alive for the codex session that
# is about to start. An unnamed container from a lost name race counts too.
# shellcheck disable=SC2317  # reached through the trap installed before the run, not by a call
mirror_stop() {
    local remaining
    remaining="$(docker ps --filter "label=${MIRROR_LABEL}=session" --format '{{.Names}}' 2>/dev/null || true)"
    if [ -n "${container_name:-}" ]; then
        remaining="$(printf '%s\n' "${remaining}" | grep -vxF "${container_name}" || true)"
    fi
    [ -z "${remaining}" ] || return 0

    # Stop first, remove second. `docker stop` gives the registry its SIGTERM and time to finish a
    # write; `docker rm -f` would send SIGKILL into whatever it was doing.
    docker stop "${MIRROR_CONTAINER}" >/dev/null 2>&1 || true
    docker rm "${MIRROR_CONTAINER}" >/dev/null 2>&1 || true
}
