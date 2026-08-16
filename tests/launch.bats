#!/usr/bin/env bats
# image/launch.sh — the container-side argv decision.
#
# This is the one piece of argument handling that can silently break `claude -c` or `codex mcp list`
# for a user, which is why it is a file of its own rather than the tail of user-init.sh: a separate
# file is one the suite can call directly, with a fake agent.env and a stubbed binary.

load helper

LAUNCH="${BATS_TEST_DIRNAME}/../image/launch.sh"

setup() {
    reset_docker_code_env
    stub_dir

    AGENT_ENV="${BATS_TEST_TMPDIR}/agent.env"
    export DOCKER_CODE_AGENT_ENV="${AGENT_ENV}"
}

# Write an agent.env for the test, then stub the binary it names so the arguments come back to us.
use_agent() {
    cp "${REPO_ROOT}/agents/$1/agent.env" "${AGENT_ENV}"
    make_stub "$(agent_field "$1" AGENT_BIN)" 'echo "ARGS: $*"; echo "SANDBOX: ${IS_SANDBOX:-unset}"'
}

args_line() {
    printf '%s\n' "${output}" | sed -n 's/^ARGS: //p'
}

@test "without YOLO the arguments arrive untouched" {
    use_agent claude
    run bash "${LAUNCH}" -p "hello"
    [ "${status}" -eq 0 ]
    [ "$(args_line)" = "-p hello" ]
}

@test "YOLO prepends the agent's own bypass flag" {
    use_agent claude
    export DOCKER_CODE_YOLO=1
    run bash "${LAUNCH}" -p "hello"
    [ "$(args_line)" = "--dangerously-skip-permissions -p hello" ]
}

@test "each agent gets its own flag, never another agent's" {
    for id in $(all_agent_ids); do
        flags="$(agent_field "${id}" AGENT_YOLO_ARGS)"
        [ -n "${flags}" ] || continue
        use_agent "${id}"
        DOCKER_CODE_YOLO=1 run bash "${LAUNCH}"
        [ "$(args_line)" = "${flags}" ] || {
            echo "agent ${id}: expected '${flags}', got '$(args_line)'"; return 1
        }
    done
}

@test "an agent with no bypass flag is left alone under YOLO" {
    use_agent opencode
    export DOCKER_CODE_YOLO=1
    run bash "${LAUNCH}" run "do the thing"
    [ "$(args_line)" = "run do the thing" ]
}

@test "the flags are prepended, so they land in front of the prompt" {
    use_agent gemini
    export DOCKER_CODE_YOLO=1
    run bash "${LAUNCH}" -p "write a haiku"
    # Read from agent.env rather than spelled out, so adding a flag there is not a test edit.
    [ "$(args_line)" = "$(agent_field gemini AGENT_YOLO_ARGS) -p write a haiku" ]
}

@test "subcommands in AGENT_YOLO_SKIP do not get the flag" {
    use_agent claude
    export DOCKER_CODE_YOLO=1
    run bash "${LAUNCH}" mcp list
    [ "$(args_line)" = "mcp list" ]
}

@test "every agent's skip list is honoured" {
    for id in $(all_agent_ids); do
        skip="$(agent_field "${id}" AGENT_YOLO_SKIP)"
        [ -n "${skip}" ] || continue
        first="${skip%% *}"
        use_agent "${id}"
        DOCKER_CODE_YOLO=1 run bash "${LAUNCH}" "${first}"
        [ "$(args_line)" = "${first}" ] || {
            echo "agent ${id}: '${first}' was given a bypass flag: $(args_line)"; return 1
        }
    done
}

@test "a skip list continued across lines is read whole" {
    # The long lists in agent.env are written across several lines. Reading only the first of them
    # does not produce a shorter skip list, it produces a wrong one: the subcommands below the
    # backslash would be prepended with the bypass arguments and, for a tool whose bypass names its
    # chat subcommand, arrive at the model as a prompt.
    cat >"${AGENT_ENV}" <<'EOF'
AGENT_ID=fake
AGENT_BIN=fake-cli
AGENT_WRAPPER=fake-docker
AGENT_YOLO_ARGS="chat --trust-everything"
AGENT_YOLO_SKIP="chat login \
mcp settings"
EOF
    make_stub fake-cli 'echo "ARGS: $*"'
    export DOCKER_CODE_YOLO=1

    run bash "${LAUNCH}" mcp list
    [ "$(args_line)" = "mcp list" ]

    run bash "${LAUNCH}" "fix the test"
    [ "$(args_line)" = "chat --trust-everything fix the test" ]
}

@test "a permission flag the user typed is not overridden" {
    use_agent claude
    export DOCKER_CODE_YOLO=1
    run bash "${LAUNCH}" --permission-mode plan
    [ "$(args_line)" = "--permission-mode plan" ]
}

@test "the =value form of a permission flag counts too" {
    use_agent claude
    export DOCKER_CODE_YOLO=1
    run bash "${LAUNCH}" --permission-mode=plan
    [ "$(args_line)" = "--permission-mode=plan" ]
}

@test "bash is the escape hatch, before anything else is decided" {
    use_agent claude
    export DOCKER_CODE_YOLO=1
    run bash "${LAUNCH}" bash -c 'echo inside'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"inside"* ]]
}

@test "DOCKER_CODE_SHELL=1 works even with a broken agent.env" {
    echo "this is not a valid line" >"${AGENT_ENV}"
    export DOCKER_CODE_SHELL=1 SHELL=/bin/bash
    run bash "${LAUNCH}" -c 'echo rescued'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"rescued"* ]]
}

@test "a missing agent.env fails with a message about the image, not a shell error" {
    rm -f "${AGENT_ENV}"
    run bash "${LAUNCH}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"built wrong"* ]]
}

@test "running as root declares the sandbox only for agents that need it" {
    # Claude Code refuses to bypass permission checks as root and skips that refusal inside a
    # recognized sandbox. Agents without AGENT_ROOT_ENV must not have variables invented for them.
    use_agent claude
    export DOCKER_CODE_YOLO=1
    run bash "${LAUNCH}"
    if [ "$(id -u)" -eq 0 ]; then
        [[ "${output}" == *"SANDBOX: 1"* ]]
    fi

    use_agent gemini
    run bash "${LAUNCH}"
    [[ "${output}" == *"SANDBOX: unset"* ]]
}

@test "local-model arguments are added only when a model was named" {
    use_agent codex
    export DOCKER_CODE_LOCAL_URL=http://localhost:11434
    run bash "${LAUNCH}"
    [ "$(args_line)" = "" ]

    export DOCKER_CODE_LOCAL_MODEL=qwen3-coder:7b
    run bash "${LAUNCH}"
    [ "$(args_line)" = "--config model_provider=dockercode --model qwen3-coder:7b" ]
}

@test "local-model arguments stay out of subcommands" {
    use_agent codex
    export DOCKER_CODE_LOCAL_URL=http://localhost:11434 DOCKER_CODE_LOCAL_MODEL=qwen3-coder:7b
    run bash "${LAUNCH}" mcp list
    [ "$(args_line)" = "mcp list" ]
}
