#!/bin/bash
# Frees what the build left behind. Cleanup must never redden a green build, so every command here
# runs without -e and its failure is ignored: a full disk is a problem for the next build, not a
# reason to fail this one after the image was already pushed.
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
