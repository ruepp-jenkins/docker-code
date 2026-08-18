#!/bin/bash
set -euo pipefail

# The build context is the repository root and so are the Dockerfile paths, the metadata file and the
# digest file the Jenkinsfile stashes. Half of this script used to reach its siblings through
# $(dirname "$0") and the other half through a bare `scripts/…`, so it only worked from one directory
# — true in CI, where checkoutRepo() guarantees it, and a trap for anyone running it by hand.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

: "${AGENT_ID:?AGENT_ID is not set (use 'base' or an id from agents/)}"
echo "Starting build workflow for ${AGENT_ID}"

# shellcheck source=scripts/docker_platforms.sh
. "${ROOT}/scripts/docker_platforms.sh"
# shellcheck source=scripts/docker_tags.sh
. "${ROOT}/scripts/docker_tags.sh"

"${ROOT}/scripts/docker_initialize.sh"

# The suite lives in the base image's build and gates every agent through the stamp it copies, so it
# runs once per pipeline rather than once per agent. Building the base is what produces the report.
if [ "${AGENT_ID}" = "base" ]; then
    "${ROOT}/scripts/test.sh"
fi

# One image, one architecture — pushed by digest, deliberately without a tag.
#
# The obvious alternative is a tag per architecture, joined afterwards. It works, but every build
# then leaves `<datestamp>-amd64` and `<datestamp>-arm64` behind in the registry forever: half-images
# nobody should pull, cluttering the tag list users actually read. push-by-digest uploads the same
# manifest and simply does not name it; the manifest list written by scripts/docker_manifest.sh is
# what references it, and that is the only thing that ends up with a tag.
#
# The cost is that the digest has to travel to the machine writing the manifest, which is what the
# Jenkinsfile's stash of the file below is for.
ARCH="${HOST_PLATFORM#linux/}"
METADATA_FILE="build-metadata-${AGENT_ID}-${ARCH}.json"
DIGEST_FILE="digest-${AGENT_ID}-${ARCH}.txt"

echo "[${BRANCH_NAME:-local}] Building ${IMAGE_REPO} for ${BASE_TAG} natively on ${HOST_PLATFORM}"
echo "  Dockerfile: ${DOCKERFILE}"
[ -z "${BASE_IMAGE_REF}" ] || echo "  FROM:       ${BASE_IMAGE_REF}"

build_args=()
[ -z "${BASE_IMAGE_REF}" ] || build_args+=(--build-arg "BASE_IMAGE=${BASE_IMAGE_REF}")

docker buildx build \
    --file "${DOCKERFILE}" \
    --platform "${RESOLVED_PLATFORMS}" \
    "${build_args[@]}" \
    --output "type=image,name=${IMAGE_REPO},push-by-digest=true,name-canonical=true,push=true" \
    --metadata-file "${METADATA_FILE}" \
    --pull \
    .

# BuildKit reports the pushed manifest's digest in the metadata file, and that digest is the only
# handle on an image that carries no tag.
#
# Parsed with sed rather than jq: the agents need Docker and nothing else, and adding a dependency to
# read one string would undo that. The pattern is anchored on the key, and the result is checked
# below — a silent empty digest would otherwise surface much later as an unreadable imagetools error.
DIGEST="$(sed -n 's/.*"containerimage.digest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "${METADATA_FILE}")"
DIGEST="${DIGEST%%$'\n'*}"

case "${DIGEST}" in
    sha256:*)
        ;;
    *)
        echo "ERROR: no image digest in ${METADATA_FILE}. BuildKit wrote:" >&2
        cat "${METADATA_FILE}" >&2
        exit 1
        ;;
esac

printf '%s\n' "${DIGEST}" > "${DIGEST_FILE}"
echo "Pushed ${IMAGE_REPO}@${DIGEST} (${HOST_PLATFORM}, untagged)"

# No cleanup here.
#
# A stage builds every agent in turn, and docker_cleanup.sh removes the shared buildx builder and
# prunes the build cache — doing that after each image would throw away the layers the next agent in
# the loop is about to reuse, and remove the builder out from under it. The Jenkinsfile calls it once
# per stage instead, from a post block that runs even when a build failed.
