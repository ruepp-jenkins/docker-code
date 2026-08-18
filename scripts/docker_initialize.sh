#!/bin/bash
set -euo pipefail
echo "Initialize docker"

# Named rather than left to set -u, so the message says what is missing. DOCKER_API_PASSWORD is bound
# by withCredentials around the step that calls this; DOCKER_USERNAME comes from the agent's own
# environment and is not set anywhere in this repository.
: "${DOCKER_USERNAME:?DOCKER_USERNAME is not set}"
: "${DOCKER_API_PASSWORD:?DOCKER_API_PASSWORD is not set (the Jenkinsfile binds it with withCredentials)}"

# shellcheck source=scripts/docker_platforms.sh
. "$(dirname "$0")/docker_platforms.sh"

BUILDER_NAME="${BUILDX_BUILDER_NAME:-mybuilder}"

echo "Host platform:    ${HOST_PLATFORM}"
echo "Target platforms: ${RESOLVED_PLATFORMS}"

echo "${DOCKER_API_PASSWORD}" | docker login --username "${DOCKER_USERNAME}" --password-stdin
docker buildx install

# Register the QEMU emulators, but only when something foreign is actually requested.
#
# Building a foreign architecture needs binfmt_misc handlers in the kernel, and a plain Linux agent
# has none — without them the one emulated instruction in the runtime stage (apt-get install curl)
# fails with "exec format error". The handlers are a host-level setting, so this is idempotent.
#
# It also needs --privileged, which is worth not asking an agent for when nothing will be emulated.
# The check is against the resolved list rather than a string compare, so it stays correct for a list
# containing the host plus one foreign platform.
if [ -n "${FOREIGN_PLATFORMS}" ]; then
    echo "Registering QEMU handlers for:${FOREIGN_PLATFORMS# }"
    docker run --privileged --rm tonistiigi/binfmt --install all
else
    echo "Host-architecture build; skipping QEMU registration"
fi

set +e
echo "Adding buildx builder - this could throw a 'wanted' error if it already exists"
docker buildx create --name "${BUILDER_NAME}" --bootstrap --use
set -e

# Bootstrap explicitly, so the builder is running and reports its platforms before we interrogate it.
# `create` above is a no-op when the builder already exists, in which case it may be stopped.
docker buildx inspect "${BUILDER_NAME}" --bootstrap >/dev/null

# Fail now, with a clear message, if the builder cannot serve a requested platform. Otherwise the
# build dies much later inside a stage, where the real cause is buried in BuildKit output.
AVAILABLE=$(docker buildx inspect "${BUILDER_NAME}" | sed -n 's/^ *Platforms: *//p' | tr -d ' ')
echo "Builder platforms: ${AVAILABLE}"

MISSING=""
for platform in $(echo "${RESOLVED_PLATFORMS}" | tr ',' ' '); do
    case ",${AVAILABLE}," in
        *",${platform},"*) ;;
        *) MISSING="${MISSING} ${platform}" ;;
    esac
done

if [ -n "${MISSING}" ]; then
    echo "ERROR: builder '${BUILDER_NAME}' cannot build:${MISSING}" >&2
    echo "       Available: ${AVAILABLE}" >&2
    if [ -n "${FOREIGN_PLATFORMS}" ]; then
        echo "       QEMU registration probably failed, or the agent forbids --privileged." >&2
    else
        echo "       This is the host's own architecture, so the builder itself is broken." >&2
    fi
    exit 1
fi

echo "All requested platforms are supported"
