#!/bin/bash
set -euo pipefail

: "${AGENT_ID:?AGENT_ID is not set (use 'base' or an id from agents/)}"
: "${DOCKER_USERNAME:?DOCKER_USERNAME is not set}"
: "${DOCKER_API_PASSWORD:?DOCKER_API_PASSWORD is not set (the Jenkinsfile binds it with withCredentials)}"
echo "Creating the multi-architecture manifest for ${AGENT_ID}"

# Joins the per-architecture images the build agents pushed into one manifest list, so a single tag
# serves both architectures and `docker pull` picks the right one.
#
# This is a separate step rather than a `--platform linux/amd64,linux/arm64` build because those two
# images are produced on two different machines. One build cannot span agents; a manifest list can
# reference anything already in the registry.
#
# The agents pushed by digest and tagged nothing, so this step is also the only one that creates a
# tag at all. A build that dies before reaching it leaves the registry's tag list untouched — which
# also means the base image must reach this step before any agent image can build FROM its tag.

# shellcheck source=scripts/docker_tags.sh
. "$(dirname "$0")/docker_tags.sh"

: "${MANIFEST_ARCHS:?MANIFEST_ARCHS is not set, e.g. 'amd64 arm64'}"

# This agent writes a manifest and nothing else: no builder, no QEMU, no build cache, so
# scripts/docker_initialize.sh would be almost entirely wasted work here. Logging in is the one thing
# it shares, and repeating that single line is cheaper than the rest of it.
echo "${DOCKER_API_PASSWORD}" | docker login --username "${DOCKER_USERNAME}" --password-stdin

# One file per architecture, written by scripts/start.sh on the agent that built it and carried here
# by the Jenkinsfile's stash. Missing means that agent never finished, and joining what is left would
# publish a tag serving one architecture while claiming both.
sources=""
for arch in ${MANIFEST_ARCHS}; do
    digest_file="digest-${AGENT_ID}-${arch}.txt"

    if [ ! -f "${digest_file}" ]; then
        echo "ERROR: ${digest_file} is missing. The ${arch} build of ${AGENT_ID} did not publish its digest." >&2
        exit 1
    fi

    digest="$(cat "${digest_file}")"
    case "${digest}" in
        sha256:*)
            ;;
        *)
            echo "ERROR: ${digest_file} does not contain a digest: '${digest}'" >&2
            exit 1
            ;;
    esac

    sources="${sources} ${IMAGE_REPO}@${digest}"
done

tags=""
for tag in ${FINAL_TAGS}; do
    tags="${tags} -t ${IMAGE_REPO}:${tag}"
done

echo "Joining:${sources}"
echo "Into:    ${FINAL_TAGS}"

# imagetools works on the registry rather than on a local image store: it reads the manifests both
# agents pushed and writes a list referencing them by digest. No layer is pulled or re-uploaded, so
# this takes seconds and needs no builder.
# shellcheck disable=SC2086  # both lists are intentionally split into separate arguments
docker buildx imagetools create ${tags} ${sources}

# Print what actually landed. A wrong or missing platform belongs in this build's log, not in a
# user's failed pull weeks later.
docker buildx imagetools inspect "${IMAGE_REPO}:${BASE_TAG}"

echo "Manifest published for ${AGENT_ID}"
