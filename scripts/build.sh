#!/bin/bash
# Local builds — what `docker-code build` calls.
#
# Nothing is pushed and nothing is tagged by date: this produces the `:latest` images the wrappers
# look for by default, on this machine's architecture only. The CI path is scripts/start.sh.
#
#   scripts/build.sh                 base, then every agent
#   scripts/build.sh claude qwen     base (if missing), then those two
#   scripts/build.sh base            only the base
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# shellcheck source=lib/agents.sh
. "${ROOT}/lib/agents.sh"

NAMESPACE="${DOCKER_CODE_NAMESPACE:-ruepp}"
PREFIX="${DOCKER_CODE_IMAGE_PREFIX:-docker-code}"
TAG="${DOCKER_CODE_TAG:-latest}"
BASE_IMAGE="${NAMESPACE}/${PREFIX}-base:${TAG}"

# The daemon's own builder, not whichever one `docker buildx create --use` last selected.
#
# An agent image is built FROM the base image this script just produced, and a docker-container
# builder cannot see the daemon's image store: it would try to pull ruepp/docker-code-base from
# Docker Hub and fail with "not found". The CI path has no such problem — there the base is really
# in a registry by the time the agents build — so this is a local-build concern only.
BUILDER="${DOCKER_CODE_BUILDER:-default}"

log() { echo "==> $*"; }
die() { echo "build.sh: ERROR: $*" >&2; exit 1; }

build_base() {
    log "base  ->  ${BASE_IMAGE}"
    # The suite runs in here (base/Dockerfile's test stage), and the `verified` stage refuses to
    # produce an image when it failed. That is the gate for all seven agents, not just this one.
    docker buildx build \
        --builder "${BUILDER}" \
        --file base/Dockerfile \
        --target final \
        --tag "${BASE_IMAGE}" \
        --load \
        .
}

# What an agent image should actually build FROM.
#
# Not `…-base:latest` directly. BuildKit caches how it resolved a FROM reference, and a tag that was
# rebuilt locally keeps resolving to the image it pointed at the first time — so an agent silently
# comes out on last week's base, with last week's entrypoint scripts in it. That is not a theoretical
# failure: it produced an agent image whose firewall script was three versions old while `base:latest`
# in the same daemon was current.
#
# A tag derived from the base's image id has no such history: it is new whenever the base changed,
# and identical whenever it did not, so the cache still works for repeated builds.
base_ref() {
    local id
    id="$(docker image inspect -f '{{.Id}}' "${BASE_IMAGE}" 2>/dev/null)" ||
        die "the base image ${BASE_IMAGE} is missing; run: scripts/build.sh base"
    id="${id#sha256:}"
    printf '%s/%s-base:build-%s\n' "${NAMESPACE}" "${PREFIX}" "$(printf '%s' "${id}" | cut -c1-12)"
}

build_agent() {
    local id="$1" image from
    agent_load "${id}" || exit 1
    image="${NAMESPACE}/${PREFIX}-${id}:${TAG}"

    from="$(base_ref)"
    docker tag "${BASE_IMAGE}" "${from}"

    # A second *name* for the same image — no copy, no layers, no extra disk. But names accumulate,
    # and a stale one keeps a superseded base image from ever being collected, so the previous ones
    # go. Only the tag is removed; `…-base:latest` still names the current base, and any image left
    # without a name is dangling for the user's own `docker image prune` to deal with.
    docker images "${NAMESPACE}/${PREFIX}-base" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null |
        grep ':build-' | grep -vxF "${from}" |
        while IFS= read -r stale; do
            if [ -n "${stale}" ]; then
                docker rmi "${stale}" >/dev/null 2>&1 || true
            fi
        done

    log "${id}  ->  ${image}   (FROM ${from})"
    docker buildx build \
        --builder "${BUILDER}" \
        --file "agents/${id}/Dockerfile" \
        --build-arg "BASE_IMAGE=${from}" \
        --tag "${image}" \
        --load \
        .
}

agents_validate_all || die "fix the agent definitions above before building"

targets="$*"
if [ -z "${targets}" ]; then
    targets="base $(agent_ids | tr '\n' ' ')"
fi

# The base has to exist before any agent can build FROM it. Asked for explicitly it is rebuilt;
# otherwise it is built only when it is missing, so `build.sh claude` after a base build is quick.
case " ${targets} " in
    *" base "*) ;;
    *)
        if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
            log "the base image is missing, building it first"
            build_base
        fi
        ;;
esac

for target in ${targets}; do
    if [ "${target}" = "base" ]; then
        build_base
    else
        build_agent "${target}"
    fi
done

log "done"
docker images --filter "reference=${NAMESPACE}/${PREFIX}-*" \
    --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}'
