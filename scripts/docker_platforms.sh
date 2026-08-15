#!/bin/bash
# Resolves which platforms this build targets. Sourced, not executed.
#
# DOCKER_PLATFORMS accepts:
#   host  (default)                 this machine's architecture, nothing emulated
#   linux/amd64,linux/arm64         an explicit list — anything foreign needs QEMU
#
# Exports:
#   RESOLVED_PLATFORMS   comma-separated list to hand to `docker build --platform`
#   HOST_PLATFORM        linux/<this machine's arch>
#   FOREIGN_PLATFORMS    space-separated requested platforms that are not the host ("" when none)
#
# The point of the 'host' sentinel is that re-enabling multi-arch is a one-line edit in the
# Jenkinsfile and nothing else changes: the QEMU registration, the platform verification and the
# build flag all key off this one variable.
#
# Resolving the host from Docker rather than assuming amd64 matters: on an arm64 agent a hard-coded
# default would quietly emulate the entire build — the exact cost this is meant to avoid.

HOST_ARCH="$(docker version --format '{{.Server.Arch}}' 2>/dev/null)"

if [ -z "${HOST_ARCH}" ]; then
    echo "ERROR: could not ask Docker for its architecture. Is the daemon reachable?" >&2
    exit 1
fi

HOST_PLATFORM="linux/${HOST_ARCH}"

# The pipeline pins each agent to an architecture by label, and a label is a promise a human made.
# When that promise turns out to be wrong — an agent relabelled, a node replaced — nothing would
# fail: both agents would build the same architecture, and the manifest list would end up claiming a
# platform it does not carry. Users would only find out on a pull. Checking here costs nothing and
# fails while the log still says which agent it was.
if [ -n "${EXPECTED_PLATFORM:-}" ] && [ "${EXPECTED_PLATFORM}" != "${HOST_PLATFORM}" ]; then
    echo "ERROR: this agent is ${HOST_PLATFORM}, but the pipeline expected ${EXPECTED_PLATFORM}." >&2
    echo "       Check the Jenkins agent labels: 'docker' must be amd64, 'oracle_docker' arm64." >&2
    exit 1
fi

case "${DOCKER_PLATFORMS:-host}" in
    host|HOST|"")
        RESOLVED_PLATFORMS="${HOST_PLATFORM}"
        ;;
    *)
        RESOLVED_PLATFORMS="${DOCKER_PLATFORMS}"
        ;;
esac

FOREIGN_PLATFORMS=""
for platform in $(echo "${RESOLVED_PLATFORMS}" | tr ',' ' '); do
    if [ "${platform}" != "${HOST_PLATFORM}" ]; then
        FOREIGN_PLATFORMS="${FOREIGN_PLATFORMS} ${platform}"
    fi
done
FOREIGN_PLATFORMS="$(echo "${FOREIGN_PLATFORMS}" | xargs)"

export RESOLVED_PLATFORMS HOST_PLATFORM FOREIGN_PLATFORMS
