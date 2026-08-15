#!/bin/bash
# Resolves the repository, tags and Dockerfile this build uses. Sourced, not executed.
#
# Three steps have to agree on these names: the two architecture builds, each pushing its own image,
# and the manifest step that joins them. They run on different agents and must not derive the names
# independently — `date +%Y%m%d` on two machines disagrees across midnight and across time zones, and
# the manifest step would then look for a tag nobody wrote. So DATESTAMP is computed once by the
# pipeline and passed in; the fallback below only serves a run started by hand.
#
# Inputs:
#   IMAGE_FULLNAME  repository stem, e.g. ruepp/docker-code
#   AGENT_ID        which image: `base`, or an id from agents/ (claude, gemini, …)
#
# Exports:
#   IMAGE_REPO      repository this build pushes to
#   BASE_TAG        the tag the finished manifest list carries
#   FINAL_TAGS      every tag the manifest list gets, space separated
#   DOCKERFILE      the Dockerfile to build
#   BASE_IMAGE_REF  what an agent image builds FROM (empty for the base itself)
#
# There is no per-architecture tag. The agents push by digest and the manifest list is the only thing
# that gets named, so the registry's tag list stays exactly as long as the number of releases — see
# scripts/start.sh for how the digest reaches the manifest step.

: "${IMAGE_FULLNAME:?IMAGE_FULLNAME is not set}"
: "${AGENT_ID:?AGENT_ID is not set (use 'base' or an id from agents/)}"

DATESTAMP="${DATESTAMP:-$(date +%Y%m%d)}"

# A slash is legal in a branch name and illegal in a tag, so `feature/x` would otherwise be pushed as
# a repository named after the branch's first segment rather than as a tag.
SAFE_BRANCH="$(echo "${BRANCH_NAME:-local}" | tr '/' '-')"

# One repository per image rather than one repository with an agent-prefixed tag. A tag list that
# interleaves seven tools is unreadable, and `docker pull ruepp/docker-code-gemini` is the name a
# user would guess.
IMAGE_STEM="${IMAGE_FULLNAME}-${AGENT_ID}"

case "${BRANCH_NAME:-}" in
    master|main)
        IMAGE_REPO="${IMAGE_STEM}"
        BASE_TAG="${DATESTAMP}"
        FINAL_TAGS="${BASE_TAG} latest"
        ;;
    *)
        IMAGE_REPO="${IMAGE_STEM}-test"
        BASE_TAG="${SAFE_BRANCH}-${DATESTAMP}"
        FINAL_TAGS="${BASE_TAG}"
        ;;
esac

if [ "${AGENT_ID}" = "base" ]; then
    DOCKERFILE="base/Dockerfile"
    BASE_IMAGE_REF=""
else
    DOCKERFILE="agents/${AGENT_ID}/Dockerfile"

    # An agent image is built FROM the base this same pipeline run produced, by tag rather than by
    # digest: the two architectures resolve the same tag to their own manifest, which is exactly what
    # a multi-arch base is for. On a branch that means the branch's own base, so a change to the base
    # is tested by the agents before either reaches master.
    case "${BRANCH_NAME:-}" in
        master|main) BASE_IMAGE_REF="${IMAGE_FULLNAME}-base:${DATESTAMP}" ;;
        *)           BASE_IMAGE_REF="${IMAGE_FULLNAME}-base-test:${SAFE_BRANCH}-${DATESTAMP}" ;;
    esac
fi

export IMAGE_REPO BASE_TAG FINAL_TAGS DOCKERFILE BASE_IMAGE_REF
