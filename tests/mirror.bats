#!/usr/bin/env bats
# lib/mirror.sh, checked without a Docker daemon.
#
# The pull-through cache is otherwise exercised only by hand, and the one thing in it that must not
# regress quietly is where the Hub credentials travel: an argument to `docker run` is readable in the
# host's process table while the call runs, and stays in `docker inspect` for as long as the mirror
# lives — which is across every session that shares it.

load helper

setup() {
    reset_docker_code_env
    export STORAGE_ROOT="${BATS_TEST_TMPDIR}/state"
    mkdir -p "${STORAGE_ROOT}"
}

# Run mirror_start against stubs and record the docker argv. The stub also copies whatever
# --env-file names, because the real file is deleted before the function returns and the delivered
# credentials would otherwise be unobservable.
start_mirror() {
    stub_dir
    export DELIVERED="${BATS_TEST_TMPDIR}/delivered.env"
    make_stub docker "$(cat <<'STUB'
prev=""
for arg in "$@"; do
    if [ "${prev}" = "--env-file" ]; then
        cp "${arg}" "${DELIVERED}" 2>/dev/null || true
        echo "${arg}" > "${STUB_DIR}/env-file.path"
    fi
    prev="${arg}"
done
STUB
)"

    run bash -c "
        STORAGE_ROOT='${STORAGE_ROOT}'
        STUB_DIR='${STUB_DIR}'
        DELIVERED='${DELIVERED}'
        warn() { :; }
        say() { :; }
        die() { exit 1; }
        ensure_image() { :; }
        prepare_store() { printf '%s\n' \"\$1\"; }
        . '${REPO_ROOT}/lib/egress.sh'
        . '${REPO_ROOT}/lib/mirror.sh'
        egress_mode=0
        mirror_start
    "
}

@test "the Hub password never appears in the docker command line" {
    export DOCKER_CODE_REGISTRY_USERNAME=someone
    export DOCKER_CODE_REGISTRY_PASSWORD='hunter2-not-in-argv'
    start_mirror

    local calls
    calls="$(stub_calls docker)"
    [[ "${calls}" != *"hunter2-not-in-argv"* ]] || {
        echo "the password was passed as an argument:"
        printf '%s\n' "${calls}" | grep 'hunter2-not-in-argv'
        return 1
    }
    [[ "${calls}" != *"REGISTRY_PROXY_PASSWORD="* ]]
    [[ "${calls}" == *"--env-file"* ]]
}

@test "the credentials still reach the container, or the mirror is anonymous again" {
    # The other half of the pair above: not passing them at all would also satisfy it.
    export DOCKER_CODE_REGISTRY_USERNAME=someone
    export DOCKER_CODE_REGISTRY_PASSWORD='hunter2-not-in-argv'
    start_mirror

    [ -f "${DELIVERED}" ] || {
        echo "no --env-file was handed to docker run"
        return 1
    }
    grep -qx 'REGISTRY_PROXY_USERNAME=someone' "${DELIVERED}"
    grep -qx 'REGISTRY_PROXY_PASSWORD=hunter2-not-in-argv' "${DELIVERED}"
}

@test "the credentials file does not outlive the call that used it" {
    export DOCKER_CODE_REGISTRY_USERNAME=someone
    export DOCKER_CODE_REGISTRY_PASSWORD='hunter2-not-in-argv'
    start_mirror

    local path
    path="$(cat "${STUB_DIR}/env-file.path" 2>/dev/null || true)"
    [ -n "${path}" ]
    [ ! -e "${path}" ] || {
        echo "a world-readable moment aside, the credentials are still on disk at ${path}"
        return 1
    }
}

@test "an anonymous mirror writes no credentials file at all" {
    start_mirror
    [[ "$(stub_calls docker)" != *"--env-file"* ]]
    [ ! -f "${DELIVERED}" ]
}
