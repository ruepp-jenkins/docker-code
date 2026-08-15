#!/bin/bash
set -e
echo "Running tests and exporting the JUnit report"

# Runs the suite inside the base image's build and extracts only the JUnit XML into the workspace,
# where the Jenkinsfile's junit step picks it up. Doing it through the build rather than invoking
# bats directly means the agent needs no bats or shellcheck — only Docker — and the tests run exactly
# once: the base image build that follows reuses this cached stage, and every agent image inherits
# the resulting stamp.
#
# The test-results target never fails, so a failing test still produces a report. The push build is
# what refuses to proceed, via base/Dockerfile's `verified` stage.

RESULTS_DIR="test-results"

# A stale report from a previous run would be republished if this build failed before writing one.
rm -rf "${RESULTS_DIR}"
mkdir -p "${RESULTS_DIR}"

docker buildx build \
    --file base/Dockerfile \
    --target test-results \
    --output "type=local,dest=${RESULTS_DIR}" \
    --pull \
    .

# Both architectures run the suite natively and publish into the same Jenkins build, where two files
# of the same name would collide in the archive. The suffix keeps them apart. It stays empty for a
# local run, which then produces the plain name tests/pipeline.bats checks for.
if [ -n "${TEST_REPORT_SUFFIX:-}" ]; then
    for report in "${RESULTS_DIR}"/*.junit.xml; do
        [ -e "${report}" ] || continue
        mv "${report}" "${report%.junit.xml}-${TEST_REPORT_SUFFIX}.junit.xml"
    done
fi

# Refresh the report's timestamp.
#
# BuildKit's local exporter keeps the file times of the stage it copies out of, so a cached test
# stage exports a report dated when the cache entry was written rather than now. Jenkins' junit step
# ignores result files older than the build start and then fails the build with "Test reports were
# found but none of them are new" — which reads as if the suite never ran.
#
# Backdating is safe to undo here: a cache hit means BuildKit matched the hash of the very sources
# under test, so this report belongs to this commit. Only its mtime is meaningless.
#
# find rather than a glob, so a build that produced no report at all still reaches the junit step and
# fails there, where the message says what actually happened.
find "${RESULTS_DIR}" -name '*.junit.xml' -exec touch {} +

echo "Test report:"
ls -la "${RESULTS_DIR}"
