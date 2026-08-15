# Shared helpers for the bats suite.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export REPO_ROOT

# A directory of fake executables, prepended to PATH. Every test that would otherwise need a real
# Docker daemon, a real user database or root's ability to rewrite /etc/passwd uses one of these
# instead, and asserts on what the script tried to call.
#
# Never call this in a command substitution: `$(stub_dir)` runs in a subshell, so the PATH it exports
# is thrown away and every stub silently stops being found. Call it plainly and read $STUB_DIR.
stub_dir() {
    if [ -z "${STUB_DIR:-}" ]; then
        STUB_DIR="${BATS_TEST_TMPDIR}/stubs"
        mkdir -p "${STUB_DIR}"
        PATH="${STUB_DIR}:${PATH}"
        export STUB_DIR PATH
    fi
}

# make_stub <name> [body]
#
# The default body records the call in $STUB_DIR/<name>.calls and succeeds, so a test can check both
# that a command ran and which arguments it got.
make_stub() {
    local name="$1"
    local body="${2:-}"
    stub_dir

    {
        echo '#!/bin/sh'
        echo "echo \"\$@\" >> \"${STUB_DIR}/${name}.calls\""
        if [ -n "${body}" ]; then
            echo "${body}"
        fi
        echo 'exit 0'
    } >"${STUB_DIR}/${name}"
    chmod +x "${STUB_DIR}/${name}"
}

stub_calls() {
    stub_dir
    cat "${STUB_DIR}/$1.calls" 2>/dev/null || true
}

stub_called() {
    stub_dir
    [ -f "${STUB_DIR}/$1.calls" ]
}

# Forget what a stub has recorded so far, for a test that wants to assert on one phase only.
stub_reset_calls() {
    stub_dir
    rm -f "${STUB_DIR}/$1.calls"
}

# The suite runs as root inside the build stage, and several code paths branch on whether the caller
# is root. This makes the script under test see an ordinary user instead.
stub_non_root_user() {
    # shellcheck disable=SC2016  # the body is a script for the stub to run later, not for us now
    make_stub id 'case "${1:-}" in
    -g) echo 1000 ;;
    *)  echo 1000 ;;
esac'
}

# Clear every DOCKER_CODE_* knob plus the provider variables the agents pass through, so a test never
# inherits the environment of the shell that started the suite. One prefix for every knob is what
# keeps this a two-line function.
reset_docker_code_env() {
    local var
    # shellcheck disable=SC2046  # one variable name per line
    for var in $(env | grep -o '^DOCKER_CODE_[A-Z_]*' || true); do
        unset "${var}"
    done
    unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_MODEL \
          OPENAI_API_KEY OPENAI_BASE_URL OPENAI_MODEL \
          GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_GEMINI_BASE_URL \
          CURSOR_API_KEY GH_TOKEN GITHUB_TOKEN HTTPS_PROXY
}

# The standard setup for a wrapper test: no daemon, no real home, a workspace of its own.
setup_wrapper_env() {
    reset_docker_code_env
    make_stub docker

    export HOME="${BATS_TEST_TMPDIR}/home"
    export DOCKER_CODE_HOME="${HOME}/docker-code"
    export DOCKER_CODE_DRY_RUN=1
    export DOCKER_CODE_TAG=test

    WORKSPACE="${BATS_TEST_TMPDIR}/workspace"
    mkdir -p "${HOME}" "${WORKSPACE}"
    cd "${WORKSPACE}" || return 1
}

# Every agent id in the repository, space separated. Tests loop over this rather than naming the
# seven, so an eighth agent is covered by the existing assertions the moment it is added.
all_agent_ids() {
    local dir id
    for dir in "${REPO_ROOT}"/agents/*/; do
        [ -f "${dir}agent.env" ] || continue
        id="${dir%/}"
        printf '%s\n' "${id##*/}"
    done | sort
}

# agent_field <id> <KEY> — one value out of an agent.env, without sourcing it.
agent_field() {
    sed -n "s/^$2=//p" "${REPO_ROOT}/agents/$1/agent.env" | head -n 1 |
        sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}
