#!/bin/bash
# Frees what the build left behind. Cleanup must never redden a green build, so every command here
# runs without -e and its failure is ignored: a full disk is a problem for the next build, not a
# reason to fail this one after the image was already pushed.
#
# The pruning is deliberately host-wide rather than scoped to this build. These are dedicated build
# agents, images and layers are exactly what fills them up, and a filter that missed something would
# defeat the point. Do not narrow it without knowing what else runs on those machines.
set +e
echo "Cleaning up"

docker buildx prune -a -f

if [ "${BUILDX_KEEP_BUILDER:-false}" != "true" ]; then
    docker buildx rm "${BUILDX_BUILDER_NAME:-mybuilder}"
else
    echo "Keeping the builder (BUILDX_KEEP_BUILDER=true)"
fi

docker image prune -f
docker container prune -f

exit 0
