#!/usr/bin/env bats
# Where the pipeline and the repository have to agree.
#
# Each of these stands for a failure that only appears in CI, long after the change that caused it:
# a report Jenkins cannot find, a tool that never gets rebuilt when it releases, a manifest step
# looking for a digest nobody stashed.

load helper

JENKINSFILE="${BATS_TEST_DIRNAME}/../Jenkinsfile"

@test "no top-level def constants, which the pipeline's own methods cannot see" {
    # In a Declarative pipeline a top-level `def x = ...` is a local of the script's run method, not
    # a binding property, so a method defined in the same file cannot read it — the reference fails
    # at runtime with MissingPropertyException, after the agent has already been claimed and the
    # repository cloned. Methods (`def name(...) {`) are fine; assignments are not.
    offenders="$(grep -nE '^def +[A-Za-z_]+ *=' "${JENKINSFILE}" || true)"
    [ -z "${offenders}" ] || {
        echo "top-level def assignments are invisible to the methods below:"
        echo "${offenders}"
        return 1
    }
}

@test "the checkout uses the job's own SCM rather than a second copy of the remote" {
    # The job found this file by cloning the repository, so it already knows the URL, the credentials
    # and the revision. Spelling them out again is a copy that can disagree with the first — and did.
    grep -q 'checkout scm' "${JENKINSFILE}"
    ! grep -qE "^\s*git .*(url:|credentialsId:)" "${JENKINSFILE}"
}

@test "every stage that runs a script checks the repository out first" {
    # cleanWs() in a post block wipes the workspace, so a later stage on the same agent starts empty.
    # A stage that runs ./scripts/... without a checkout fails with "no such file".
    checkouts="$(grep -c 'checkoutRepo()' "${JENKINSFILE}")"
    runners="$(grep -cE "sh '\./scripts/" "${JENKINSFILE}")"
    [ "${checkouts}" -gt "${runners}" ] || {
        echo "found ${runners} script invocations but only ${checkouts} checkoutRepo() calls"
        return 1
    }
}

@test "agent builds are sequential per node, because the builder and cache are shared per machine" {
    # One branch per agent would put one build per agent on one node, each creating and then removing the
    # shared `mybuilder` underneath the others. Parallel across architectures only.
    grep -q "stage('agents amd64')" "${JENKINSFILE}"
    grep -q "stage('agents arm64')" "${JENKINSFILE}"
    ! grep -qE "node\('(docker|oracle_docker)'\)" "${JENKINSFILE}"
}

@test "cleanup runs once per stage, not once per image" {
    # docker_cleanup.sh removes the builder and prunes the cache; between two agents in the same
    # loop that would discard exactly the layers the next one reuses.
    ! grep -q 'docker_cleanup.sh' "${REPO_ROOT}/scripts/start.sh"
    grep -q "sh './scripts/docker_cleanup.sh'" "${JENKINSFILE}"
}

@test "the agent list in CI is read from the directories, not written out by hand" {
    # This is what keeps "add a folder under agents/" true all the way through the pipeline.
    grep -q 'AGENT_IDS' "${JENKINSFILE}"
    grep -q 'ls -1 agents' "${JENKINSFILE}"
}

@test "the junit glob matches the report the build actually writes" {
    glob="$(sed -n "s/.*junit testResults: '\([^']*\)'.*/\1/p" "${JENKINSFILE}" | head -n 1)"
    [ -n "${glob}" ]

    dir="$(sed -n 's/^RESULTS_DIR="\(.*\)"$/\1/p' "${REPO_ROOT}/scripts/test.sh")"
    name="$(sed -n 's|.*> /out/\([a-z.]*junit.xml\).*|\1|p' "${REPO_ROOT}/base/Dockerfile" | head -n 1)"
    [ -n "${dir}" ]
    [ -n "${name}" ]

    # shellcheck disable=SC2053  # matching against a glob is the point
    [[ "${dir}/${name}" == ${glob} ]]
}

@test "a missing report fails the build rather than passing quietly" {
    grep -q 'allowEmptyResults: false' "${JENKINSFILE}"
}

@test "the base is built and its manifest published before any agent" {
    base_stage="$(grep -n "stage('Base')" "${JENKINSFILE}" | cut -d: -f1)"
    base_manifest="$(grep -n "stage('Base manifest')" "${JENKINSFILE}" | cut -d: -f1)"
    agents_stage="$(grep -n "stage('Agents')" "${JENKINSFILE}" | cut -d: -f1)"

    [ -n "${base_stage}" ] && [ -n "${base_manifest}" ] && [ -n "${agents_stage}" ]
    # The agent Dockerfiles resolve the base by tag, and the manifest step is the only thing in the
    # pipeline that writes one.
    [ "${base_stage}" -lt "${base_manifest}" ]
    [ "${base_manifest}" -lt "${agents_stage}" ]
}

@test "the digest names the build stashes are the ones the manifest step unstashes" {
    grep -q 'stash name: "digest-\${agentId}-\${arch}"' "${JENKINSFILE}"
    grep -q 'unstash "digest-\${agentId}-amd64"' "${JENKINSFILE}"
    grep -q 'unstash "digest-\${agentId}-arm64"' "${JENKINSFILE}"

    # And that is the file scripts/start.sh actually writes.
    grep -q 'DIGEST_FILE="digest-${AGENT_ID}-${ARCH}.txt"' "${REPO_ROOT}/scripts/start.sh"
}

@test "every architecture in MANIFEST_ARCHS has a build branch" {
    archs="$(sed -n "s/.*MANIFEST_ARCHS = '\(.*\)'.*/\1/p" "${JENKINSFILE}")"
    [ -n "${archs}" ]
    for arch in ${archs}; do
        grep -q "buildImage(id, '${arch}'" "${JENKINSFILE}" || {
            echo "MANIFEST_ARCHS names ${arch} but no agent branch builds it"; return 1
        }
    done
}

@test "every tool installed from npm has a rebuild trigger" {
    # The image is the update path for its users: every tool is installed system-wide with its
    # auto-updater off, so without a trigger a release simply never reaches anyone.
    for id in $(all_agent_ids); do
        pkg="$(sed -n 's/.*npm install -g "\(@\?[a-z0-9./-]*\)@.*/\1/p' \
            "${REPO_ROOT}/agents/${id}/Dockerfile" | head -n 1)"
        [ -n "${pkg}" ] || continue
        grep -q "registry.npmjs.org/${pkg}/latest" "${JENKINSFILE}" || {
            echo "agent ${id} installs ${pkg} from npm but the Jenkinsfile has no URLTrigger for it"
            return 1
        }
    done
}

@test "the ubuntu trigger tracks the tag the base image actually uses" {
    tag="$(sed -n 's/^ARG UBUNTU_TAG=//p' "${REPO_ROOT}/base/Dockerfile" | head -n 1)"
    [ -n "${tag}" ]
    grep -q "library/ubuntu/tags/${tag}" "${JENKINSFILE}"
}

@test "concurrent builds of a branch are disabled" {
    # Two runs of the same branch would write the same intermediate tags, and a manifest could pick
    # up half of one build and half of another.
    grep -q 'disableConcurrentBuilds' "${JENKINSFILE}"
}

@test "the datestamp is computed once, not per agent" {
    # Two machines running `date` disagree across midnight and across time zones, and the manifest
    # step would then look for a tag nobody wrote.
    [ "$(grep -c 'date +%Y%m%d' "${JENKINSFILE}")" -eq 1 ]
    grep -q 'DATESTAMP:-$(date +%Y%m%d)' "${REPO_ROOT}/scripts/docker_tags.sh"
}

@test "docker_tags.sh refuses to guess which image it is building" {
    # Sourced in a subshell so the `${AGENT_ID:?}` abort becomes an ordinary non-zero status here,
    # rather than bash's own 127 for a failed parameter expansion.
    run bash -c "export IMAGE_FULLNAME=x; ( . '${REPO_ROOT}/scripts/docker_tags.sh' ) || exit 3"
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"AGENT_ID"* ]]
}

@test "one repository per image, and no per-architecture tags" {
    run bash -c "export IMAGE_FULLNAME=ruepp/docker-code AGENT_ID=gemini BRANCH_NAME=master DATESTAMP=20260101; \
        . '${REPO_ROOT}/scripts/docker_tags.sh'; echo \"\${IMAGE_REPO} | \${FINAL_TAGS} | \${DOCKERFILE}\""
    [ "${status}" -eq 0 ]
    [ "${output}" = "ruepp/docker-code-gemini | 20260101 latest | agents/gemini/Dockerfile" ]
}

@test "a branch build pushes to a -test repository and never claims latest" {
    run bash -c "export IMAGE_FULLNAME=ruepp/docker-code AGENT_ID=codex BRANCH_NAME=feature/x DATESTAMP=20260101; \
        . '${REPO_ROOT}/scripts/docker_tags.sh'; echo \"\${IMAGE_REPO} | \${FINAL_TAGS} | \${BASE_IMAGE_REF}\""
    [ "${status}" -eq 0 ]
    # The slash in the branch name is illegal in a tag and has to become a dash.
    [ "${output}" = "ruepp/docker-code-codex-test | feature-x-20260101 | ruepp/docker-code-base-test:feature-x-20260101" ]
}

@test "an agent image on a branch builds FROM that branch's own base" {
    # A change to the base is then tested by all eight agents before either reaches master.
    run bash -c "export IMAGE_FULLNAME=ruepp/docker-code AGENT_ID=base BRANCH_NAME=master DATESTAMP=20260101; \
        . '${REPO_ROOT}/scripts/docker_tags.sh'; echo \"\${DOCKERFILE}|\${BASE_IMAGE_REF}\""
    [ "${output}" = "base/Dockerfile|" ]
}

@test "the test suite runs once per pipeline, in the base build" {
    grep -q 'if \[ "${AGENT_ID}" = "base" \]; then' "${REPO_ROOT}/scripts/start.sh"
    grep -q 'scripts/test.sh' "${REPO_ROOT}/scripts/start.sh"
}
