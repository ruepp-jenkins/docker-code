#!/usr/bin/env bats
# The host-side launcher, checked through the dry-run seam.
#
# Everything bin/docker-code does before it runs anything is pure command construction, so
# DOCKER_CODE_DRY_RUN=1 turns the whole launcher into a function from environment to argv — testable
# without a Docker daemon. Assertions are on that argv.

load helper

setup() {
    setup_wrapper_env
}

# Run an agent's wrapper and leave the argv in $output.
dry() {
    local wrapper="$1"
    shift
    run "${REPO_ROOT}/bin/${wrapper}" "$@"
    [ "${status}" -eq 0 ] || {
        echo "wrapper exited ${status}: ${output}"
        return 1
    }
}

@test "every wrapper starts a container from its own image" {
    for id in $(all_agent_ids); do
        wrapper="$(agent_field "${id}" AGENT_WRAPPER)"
        run "${REPO_ROOT}/bin/${wrapper}"
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"ruepp/docker-code-${id}:test"* ]] || {
            echo "${wrapper} did not use the ${id} image: ${output}"; return 1
        }
    done
}

@test "every wrapper mounts its own state directory as the container home" {
    for id in $(all_agent_ids); do
        wrapper="$(agent_field "${id}" AGENT_WRAPPER)"
        run "${REPO_ROOT}/bin/${wrapper}"
        [[ "${output}" == *"--volume ${DOCKER_CODE_HOME}/${id}:/home/agent"* ]] || {
            echo "${wrapper} did not mount ${DOCKER_CODE_HOME}/${id}: ${output}"; return 1
        }
    done
}

@test "no two agents share a state directory" {
    seen=""
    for id in $(all_agent_ids); do
        case " ${seen} " in
            *" ${id} "*) echo "duplicate state directory ${id}"; return 1 ;;
        esac
        seen="${seen} ${id}"
        [ -d "${DOCKER_CODE_HOME}/${id}" ] || true
    done
}

@test "the workspace is mounted at the same absolute path it has on the host" {
    dry claude-docker
    [[ "${output}" == *"--volume ${WORKSPACE}:${WORKSPACE}"* ]]
    [[ "${output}" == *"--workdir ${WORKSPACE}"* ]]
}

@test "arguments are passed through untouched, after the image" {
    dry gemini-docker --model gemini-2.5-pro -p "hello world"
    [[ "${output}" == *"ruepp/docker-code-gemini:test --model gemini-2.5-pro -p hello\\ world"* ]] ||
        [[ "${output}" == *"ruepp/docker-code-gemini:test --model gemini-2.5-pro -p 'hello world'"* ]]
}

@test "the container is named after the wrapper and the free slot" {
    dry qwen-docker
    [[ "${output}" == *"--name qwen-docker_1"* ]]
}

@test "a session gets a label naming its agent" {
    dry codex-docker
    [[ "${output}" == *"--label com.ruepp.docker-code=session"* ]]
    [[ "${output}" == *"--label com.ruepp.docker-code.agent=codex"* ]]
}

@test "an unknown agent id is refused with the list of known ones" {
    run "${REPO_ROOT}/bin/docker-code" run nosuchagent
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"claude"* ]]
}

@test "docker-code run <agent> builds the same command as the wrapper" {
    # Only the argv is compared: warnings are prefixed with the name the user typed, so those two
    # legitimately differ.
    run "${REPO_ROOT}/bin/docker-code" run claude --version
    via_cli="$(printf '%s\n' "${output}" | grep '^docker run ')"
    run "${REPO_ROOT}/bin/claude-docker" --version
    via_wrapper="$(printf '%s\n' "${output}" | grep '^docker run ')"

    [ -n "${via_cli}" ]
    [ "${via_cli}" = "${via_wrapper}" ]
}

# ---------------------------------------------------------------------------------------------
# Environment pass-through
# ---------------------------------------------------------------------------------------------
@test "an agent's own variables are forwarded when set" {
    export ANTHROPIC_API_KEY=sk-test-123
    dry claude-docker
    [[ "${output}" == *"--env ANTHROPIC_API_KEY=sk-test-123"* ]]
}

@test "another agent's variables are not forwarded" {
    # A Gemini session has no business receiving the Anthropic key that happens to be exported.
    export ANTHROPIC_API_KEY=sk-test-123
    dry gemini-docker
    [[ "${output}" != *"ANTHROPIC_API_KEY"* ]]
}

@test "unset variables stay unset rather than arriving empty" {
    dry claude-docker
    [[ "${output}" != *"ANTHROPIC_API_KEY="* ]]
}

@test "terminal and proxy variables reach every agent" {
    export TERM=xterm-256color HTTPS_PROXY=http://proxy:3128
    for id in $(all_agent_ids); do
        wrapper="$(agent_field "${id}" AGENT_WRAPPER)"
        run "${REPO_ROOT}/bin/${wrapper}"
        [[ "${output}" == *"--env TERM=xterm-256color"* ]]
        [[ "${output}" == *"--env HTTPS_PROXY=http://proxy:3128"* ]]
    done
}

@test "DOCKER_CODE_ENV adds variables by name" {
    export MY_SECRET=abc DOCKER_CODE_ENV="MY_SECRET"
    dry claude-docker
    [[ "${output}" == *"--env MY_SECRET=abc"* ]]
}

# ---------------------------------------------------------------------------------------------
# Per-agent overrides
# ---------------------------------------------------------------------------------------------
@test "DOCKER_CODE_<AGENT>_IMAGE overrides one agent only" {
    export DOCKER_CODE_CLAUDE_IMAGE=my/custom:1
    dry claude-docker
    [[ "${output}" == *"my/custom:1"* ]]

    dry gemini-docker
    [[ "${output}" == *"ruepp/docker-code-gemini:test"* ]]
}

@test "DOCKER_CODE_NAMESPACE moves every image at once" {
    export DOCKER_CODE_NAMESPACE=example
    dry qwen-docker
    [[ "${output}" == *"example/docker-code-qwen:test"* ]]
}

# ---------------------------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------------------------
@test "the default is a privileged inner Docker with a store per agent" {
    dry claude-docker
    [[ "${output}" == *"--privileged"* ]]
    [[ "${output}" == *"--volume docker-code-claude:/var/lib/docker"* ]]
}

@test "DOCKER_CODE_DIND=0 leaves out the daemon and the privileged flag" {
    export DOCKER_CODE_DIND=0
    dry claude-docker
    [[ "${output}" != *"--privileged"* ]]
    [[ "${output}" != *"/var/lib/docker"* ]]
    [[ "${output}" == *"--env DOCKER_CODE_DIND=0"* ]]
}

@test "DOCKER_CODE_NET=restricted asks for the capabilities the firewall needs" {
    export DOCKER_CODE_NET=restricted
    dry claude-docker
    [[ "${output}" == *"--cap-add NET_ADMIN"* ]]
    [[ "${output}" == *"--cap-add NET_RAW"* ]]
    [[ "${output}" == *"--env DOCKER_CODE_NET=restricted"* ]]
}

@test "DOCKER_CODE_NET=none cuts the network" {
    export DOCKER_CODE_NET=none
    dry claude-docker
    [[ "${output}" == *"--network none"* ]]
}

@test "an unknown network mode is refused" {
    export DOCKER_CODE_NET=sideways
    run "${REPO_ROOT}/bin/claude-docker"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"full, restricted, none"* ]]
}

@test "an unknown dind mode is refused" {
    export DOCKER_CODE_DIND=sideways
    run "${REPO_ROOT}/bin/claude-docker"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"DOCKER_CODE_DIND"* ]]
}

@test "YOLO is passed as a switch, not as a flag the wrapper invents" {
    export DOCKER_CODE_YOLO=1
    dry claude-docker
    [[ "${output}" == *"--env DOCKER_CODE_YOLO=1"* ]]
    # The actual bypass flag is the container's decision, from agent.env — see launch.bats.
    [[ "${output}" != *"--dangerously-skip-permissions"* ]]
}

@test "YOLO on an agent that has no bypass flag says so" {
    export DOCKER_CODE_YOLO=1
    run "${REPO_ROOT}/bin/opencode-docker"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"no bypass flag"* ]]
}

# ---------------------------------------------------------------------------------------------
# Local models
# ---------------------------------------------------------------------------------------------
@test "local models attach the session to the model network and bridge the ports" {
    export DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3-coder:7b
    dry qwen-docker
    [[ "${output}" == *"--network docker-code-net"* ]]
    [[ "${output}" == *"DOCKER_CODE_LOCAL_BRIDGE=11434:docker-code-ollama:11434"* ]]
    [[ "${output}" == *"--env DOCKER_CODE_LOCAL_MODEL=qwen3-coder:7b"* ]]
}

@test "an openai-compatible agent is pointed at Ollama directly" {
    export DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3-coder:7b
    dry qwen-docker
    [[ "${output}" == *"--env OPENAI_BASE_URL=http://localhost:11434/v1"* ]]
    [[ "${output}" == *"--env OPENAI_MODEL=qwen3-coder:7b"* ]]
}

@test "a gemini-format agent is pointed at the LiteLLM gateway instead" {
    export DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3-coder:7b
    dry gemini-docker
    # The gateway's root: the SDK appends /v1beta/models/<model>:generateContent itself, and
    # LiteLLM's own /gemini prefix is a pass-through to Google AI Studio, not a local route.
    [[ "${output}" == *"--env GOOGLE_GEMINI_BASE_URL=http://localhost:4000"* ]]
    [[ "${output}" != *"localhost:4000/gemini"* ]]
}

@test "claude is pointed at Ollama's own Anthropic endpoint" {
    export DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3-coder:7b
    dry claude-docker
    [[ "${output}" == *"--env ANTHROPIC_BASE_URL=http://localhost:11434"* ]]
    [[ "${output}" == *"--env ANTHROPIC_MODEL=qwen3-coder:7b"* ]]
}

@test "a cloud-only agent says local models do not apply and starts anyway" {
    export DOCKER_CODE_LOCAL=1
    run "${REPO_ROOT}/bin/cursor-agent-docker"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cannot use a local model"* ]]
    [[ "${output}" != *"--network docker-code-net"* ]]
}

@test "local models and no network at all is refused rather than half-applied" {
    export DOCKER_CODE_LOCAL=1 DOCKER_CODE_NET=none
    run "${REPO_ROOT}/bin/qwen-docker"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"local models off"* ]]
    [[ "${output}" != *"--network docker-code-net"* ]]
}

# ---------------------------------------------------------------------------------------------
# State directory resolution
# ---------------------------------------------------------------------------------------------
@test "a relative DOCKER_CODE_HOME is refused, because Docker would make it a volume" {
    export DOCKER_CODE_HOME=state
    run "${REPO_ROOT}/bin/claude-docker"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"absolute path"* ]]
}

@test "without a usable HOME the launcher stops rather than inventing a location" {
    unset DOCKER_CODE_HOME
    unset HOME
    run "${REPO_ROOT}/bin/claude-docker"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"DOCKER_CODE_HOME"* ]]
}

@test "the state directory is created by us, not by Docker as root" {
    dry claude-docker
    [ -d "${DOCKER_CODE_HOME}/claude" ]
}

@test "the shared directory is opt-in" {
    dry claude-docker
    [[ "${output}" != *"/home/agent/shared"* ]]

    export DOCKER_CODE_SHARED=1
    dry claude-docker
    [[ "${output}" == *"--volume ${DOCKER_CODE_HOME}/shared:/home/agent/shared"* ]]
}
