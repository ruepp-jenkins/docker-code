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

@test "every session knob has a working per-agent form" {
    # This is what makes a shell startup file useful: local models for Qwen, the cloud for the agent
    # you pay a subscription for. A knob read straight from the environment instead of through
    # agent_knob would silently ignore the per-agent spelling — which is exactly what the README
    # promised and the code did not do.
    export DOCKER_CODE_QWEN_YOLO=1
    dry qwen-docker
    [[ "${output}" == *"--env DOCKER_CODE_YOLO=1"* ]]

    dry claude-docker
    [[ "${output}" == *"--env DOCKER_CODE_YOLO=0"* ]]
}

@test "a per-agent knob beats the generic one" {
    export DOCKER_CODE_DIND=0 DOCKER_CODE_CLAUDE_DIND=privileged
    dry claude-docker
    [[ "${output}" == *"--privileged"* ]]

    dry qwen-docker
    [[ "${output}" != *"--privileged"* ]]
}

@test "local models can be switched on for one agent only" {
    export DOCKER_CODE_QWEN_LOCAL=1 DOCKER_CODE_QWEN_LOCAL_MODEL=qwen2.5-coder:14b
    dry qwen-docker
    [[ "${output}" == *"--network docker-code-net"* ]]
    [[ "${output}" == *"--env OPENAI_MODEL=qwen2.5-coder:14b"* ]]

    # Claude keeps its cloud provider: no model network, no rewritten base URL.
    dry claude-docker
    [[ "${output}" != *"--network docker-code-net"* ]]
    [[ "${output}" != *"ANTHROPIC_BASE_URL"* ]]
}

@test "the knobs the container side reads actually reach it" {
    # init-firewall.sh and user-init.sh read these inside the container; a launcher that never
    # forwarded them would leave the documented hooks unreachable.
    export DOCKER_CODE_ALLOW_DOMAINS="registry.intern" \
           DOCKER_CODE_ALLOW_GITHUB=0 \
           DOCKER_CODE_DIND_WAIT=30 \
           DOCKER_CODE_INSECURE_REGISTRIES="registry.intern:5000"
    dry claude-docker
    [[ "${output}" == *"--env DOCKER_CODE_ALLOW_DOMAINS=registry.intern"* ]]
    [[ "${output}" == *"--env DOCKER_CODE_ALLOW_GITHUB=0"* ]]
    [[ "${output}" == *"--env DOCKER_CODE_DIND_WAIT=30"* ]]
    [[ "${output}" == *"--env DOCKER_CODE_INSECURE_REGISTRIES=registry.intern:5000"* ]]
}

@test "per-agent forms of the container-side knobs arrive under the plain name" {
    # The container runs one agent and has no use for the per-agent spelling.
    export DOCKER_CODE_QWEN_SHELL=1
    dry qwen-docker
    [[ "${output}" == *"--env DOCKER_CODE_SHELL=1"* ]]
    [[ "${output}" != *"DOCKER_CODE_QWEN_SHELL"* ]]
}

@test "a per-agent mount applies to that agent only" {
    export DOCKER_CODE_CODEX_MOUNT="/srv/data:/data:ro"
    dry codex-docker
    [[ "${output}" == *"--volume /srv/data:/data:ro"* ]]

    dry qwen-docker
    [[ "${output}" != *"/srv/data"* ]]
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
    # Every mode is named, so the message stays a usable answer rather than a partial one.
    for mode in full restricted gateway none; do
        [[ "${output}" == *"${mode}"* ]] || { echo "the refusal does not mention ${mode}"; return 1; }
    done
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

# ---------------------------------------------------------------------------------------------
# Background sessions and remote control
# ---------------------------------------------------------------------------------------------
@test "a session runs in the foreground unless detached" {
    dry claude-docker
    [[ "${output}" != *"--detach"* ]]

    export DOCKER_CODE_CLAUDE_DETACH=1
    dry claude-docker
    [[ "${output}" == *"--detach --tty"* ]]
    dry qwen-docker
    [[ "${output}" != *"--detach"* ]]
}

@test "remote control is passed as a switch, not as a flag the wrapper invents" {
    export DOCKER_CODE_REMOTE=1 DOCKER_CODE_DETACH=1
    dry claude-docker
    [[ "${output}" == *"--env DOCKER_CODE_REMOTE=1"* ]]
    [[ "${output}" != *"--remote-control"* ]]
}

@test "remote control on an agent that has none says so" {
    export DOCKER_CODE_REMOTE=1
    run "${REPO_ROOT}/bin/gemini-docker"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"has no remote control"* ]]
}

@test "remote control in the foreground points at detaching" {
    export DOCKER_CODE_REMOTE=1
    run "${REPO_ROOT}/bin/claude-docker"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Ctrl-P Ctrl-Q"* ]]

    export DOCKER_CODE_DETACH=1
    run "${REPO_ROOT}/bin/claude-docker"
    [[ "${output}" != *"Ctrl-P Ctrl-Q"* ]]
}

@test "every agent that offers remote control has a way to switch it on, and only those do" {
    for id in $(all_agent_ids); do
        flags="$(agent_field "${id}" AGENT_REMOTE_ARGS)$(agent_field "${id}" AGENT_REMOTE_START)"
        case "${id}" in
            claude|codex|copilot) [ -n "${flags}" ] || { echo "${id} lost its remote control"; return 1; } ;;
            *) [ -z "${flags}" ] || { echo "${id} claims remote control: ${flags}"; return 1; } ;;
        esac
    done
}

@test "the -remote command starts in the background with remote control on" {
    dry claude-docker-remote
    [[ "${output}" == *"--detach --tty"* ]]
    [[ "${output}" == *"--env DOCKER_CODE_REMOTE=1"* ]]
    [[ "${output}" == *"ruepp/docker-code-claude:test"* ]]
}

@test "the -remote command leaves the plain wrapper alone" {
    dry claude-docker
    [[ "${output}" != *"--detach"* ]]
    [[ "${output}" != *"DOCKER_CODE_REMOTE"* ]]
}

@test "the -remote command can still be kept in the foreground" {
    export DOCKER_CODE_CLAUDE_DETACH=0
    dry claude-docker-remote
    [[ "${output}" != *"--detach"* ]]
    [[ "${output}" == *"--env DOCKER_CODE_REMOTE=1"* ]]
}

@test "a -remote name for an agent without remote control is refused" {
    ln -s "${REPO_ROOT}/bin/docker-code" "${BATS_TEST_TMPDIR}/gemini-docker-remote"
    run "${BATS_TEST_TMPDIR}/gemini-docker-remote"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no agent is registered for the name 'gemini-docker-remote'"* ]]
}

# ---------------------------------------------------------------------------------------------
# Named remote sessions, restart policy and compose
# ---------------------------------------------------------------------------------------------
@test "a remote session is named after the directory it starts in" {
    dry claude-docker-remote
    [[ "${output}" == *"--name claude-docker-remote_workspace "* ]]
    [[ "${output}" == *"--env DOCKER_CODE_SESSION_NAME=workspace "* ]]
    # Its own inner Docker store: it outlives the numbered sessions that share slot 1's.
    [[ "${output}" == *"--volume docker-code-claude_remote_workspace:/var/lib/docker"* ]]
}

@test "DOCKER_CODE_NAME names the session, and the container gets a name Docker accepts" {
    export DOCKER_CODE_NAME="My Project!"
    dry claude-docker-remote
    [[ "${output}" == *"--name claude-docker-remote_my-project "* ]]
    [[ "${output}" == *"DOCKER_CODE_SESSION_NAME=My\\ Project\\!"* ]]
}

@test "sessions without remote control keep their numbered names" {
    export DOCKER_CODE_NAME=ignored
    dry claude-docker
    [[ "${output}" == *"--name claude-docker_1"* ]]
    [[ "${output}" != *"SESSION_NAME"* ]]
}

@test "a remote session in the background restarts unless stopped, and is not removed" {
    dry claude-docker-remote
    [[ "${output}" == *"docker run --init --restart unless-stopped "* ]]
    [[ "${output}" != *"--rm"* ]]

    dry claude-docker
    [[ "${output}" == *"docker run --rm --init "* ]]
    [[ "${output}" != *"--restart"* ]]
}

@test "DOCKER_CODE_RESTART=no gives a remote session --rm back" {
    export DOCKER_CODE_RESTART=no
    dry claude-docker-remote
    [[ "${output}" == *"docker run --rm --init "* ]]
    [[ "${output}" != *"--restart"* ]]
}

@test "a restart policy for a session in the foreground is refused with a warning, not applied" {
    export DOCKER_CODE_RESTART=always
    run "${REPO_ROOT}/bin/claude-docker"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DOCKER_CODE_RESTART applies to sessions in the background"* ]]
    [[ "${output}" == *"--rm --init"* ]]
    [[ "${output}" != *"--restart"* ]]
}

@test "an unknown restart policy is refused" {
    export DOCKER_CODE_RESTART=sometimes
    run "${REPO_ROOT}/bin/claude-docker-remote"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"DOCKER_CODE_RESTART must be"* ]]
}

# A docker stub whose `inspect` reports the given state for the session name, and the label of a
# docker-code session unless told otherwise.
stub_existing_session() {
    local state="$1" label="${2-session}"
    make_stub docker "case \"\$1\" in
    inspect) case \"\$3\" in
        *State.Status*) echo ${state} ;;
        *Labels*) echo ${label} ;;
    esac ;;
esac"
}

@test "a remote session already running under its name is not started twice" {
    unset DOCKER_CODE_DRY_RUN
    export DOCKER_CODE_AUTO_UPDATE=0
    stub_existing_session running
    run "${REPO_ROOT}/bin/claude-docker-remote"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"claude-docker-remote_workspace is already running"* ]]
    [[ "${output}" == *"docker-code attach claude-docker-remote_workspace"* ]]
    ! stub_calls docker | grep -q '^run '
}

@test "a stopped remote session under the name is replaced" {
    unset DOCKER_CODE_DRY_RUN
    export DOCKER_CODE_AUTO_UPDATE=0
    stub_existing_session exited
    run "${REPO_ROOT}/bin/claude-docker-remote"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"replacing the stopped session claude-docker-remote_workspace"* ]]
    stub_calls docker | grep -qx 'rm claude-docker-remote_workspace'
    stub_calls docker | grep -q '^run .*--name claude-docker-remote_workspace'
}

@test "a container under the name that is not a session is left alone" {
    unset DOCKER_CODE_DRY_RUN
    export DOCKER_CODE_AUTO_UPDATE=0
    stub_existing_session exited ""
    run "${REPO_ROOT}/bin/claude-docker-remote"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"is not a docker-code session"* ]]
    ! stub_calls docker | grep -q '^rm '
}

@test "docker-code compose prints a remote session that restarts" {
    run "${REPO_ROOT}/bin/docker-code" compose --stdout claude
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'name: "workspace"'* ]]
    [[ "${output}" == *'container_name: "claude-docker-remote_workspace"'* ]]
    [[ "${output}" == *'restart: "unless-stopped"'* ]]
    [[ "${output}" == *'- "DOCKER_CODE_REMOTE=1"'* ]]
    [[ "${output}" == *'- "DOCKER_CODE_SESSION_NAME=workspace"'* ]]
    [[ "${output}" == *"- \"${WORKSPACE}:${WORKSPACE}\""* ]]
    [[ "${output}" == *'  docker-code-claude_remote_workspace:'* ]]
    [[ "${output}" != *"__DOCKER_CODE_"* ]]
}

@test "docker-code compose names variables but never writes their values" {
    export ANTHROPIC_API_KEY=sk-secret-value
    run "${REPO_ROOT}/bin/docker-code" compose --stdout claude
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'- "ANTHROPIC_API_KEY"'* ]]
    [[ "${output}" != *"sk-secret-value"* ]]
}

@test "docker-code compose escapes what compose would otherwise interpolate" {
    export DOCKER_CODE_NAME='cost $HOME "quoted"'
    run "${REPO_ROOT}/bin/docker-code" compose --stdout claude
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'DOCKER_CODE_SESSION_NAME=cost $$HOME \"quoted\""'* ]]
    [[ "${output}" == *'container_name: "claude-docker-remote_cost-home-quoted"'* ]]
}

@test "docker-code compose refuses what a compose file cannot carry" {
    run "${REPO_ROOT}/bin/docker-code" compose --stdout gemini
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"has no remote control"* ]]

    export DOCKER_CODE_RUN_ARGS="--memory 4g"
    run "${REPO_ROOT}/bin/docker-code" compose --stdout claude
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"'--memory' has no translation"* ]]
}

@test "docker-code compose leaves out the registry mirror docker-code would have to start" {
    export DOCKER_CODE_REGISTRY_MIRROR=1
    run "${REPO_ROOT}/bin/docker-code" compose --stdout claude
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"leaves it out"* ]]
    [[ "${output}" != *"DOCKER_CODE_MIRROR_URL"* ]]
}

@test "sessions of agents with remote control point at a compose template, others do not" {
    dry claude-docker
    [[ "${output}" == *"--env DOCKER_CODE_COMPOSE_TEMPLATE=/home/agent/.docker-code/compose-"*".yml"* ]]
    dry gemini-docker
    [[ "${output}" != *"DOCKER_CODE_COMPOSE_TEMPLATE"* ]]
}

@test "under NET=gateway the compose file brings its own gateway, on the launcher's topology" {
    export DOCKER_CODE_NET=gateway HTTP_PROXY=http://corporate:8080
    run "${REPO_ROOT}/bin/docker-code" compose --stdout claude
    [ "${status}" -eq 0 ]
    # The session: only the internal network, pointed at the gateway service, after it is healthy.
    [[ "${output}" == *'      - "egress-internal"
    depends_on:
      egress:
        condition: service_healthy'* ]]
    [[ "${output}" == *'- "HTTPS_PROXY=http://egress:3128"'* ]]
    [[ "${output}" == *'- "DOCKER_CODE_PROXY=http://egress:3128"'* ]]
    # The shell's proxy by name would replace the gateway in compose; it must not be listed again.
    [[ "${output}" != *'- "HTTP_PROXY"'* ]]
    [[ "${output}" != *"corporate"* ]]
    # The gateway: both networks, its policy inline, restarting with the session.
    [[ "${output}" == *'  egress:
    image: "ubuntu/squid:'* ]]
    [[ "${output}" == *'container_name: "claude-docker-remote_workspace-egress"'* ]]
    [[ "${output}" == *'  egress-internal:
    internal: true'* ]]
    [[ "${output}" == *'      acl allowed_domains dstdomain '*'api.anthropic.com'* ]]
    [[ "${output}" == *'      http_access deny all'* ]]
    [ "$(printf '%s\n' "${output}" | grep -c 'restart: "unless-stopped"')" -eq 2 ]
    # Nothing of the launcher's own gateway, which egress_start would remove from under it.
    [[ "${output}" != *"docker-code-egress-claude"* ]]
}

@test "the compose gateway follows the egress policy and joins the model network for local models" {
    export DOCKER_CODE_NET=gateway DOCKER_CODE_EGRESS_POLICY=open DOCKER_CODE_LOCAL=1
    run "${REPO_ROOT}/bin/docker-code" compose --stdout claude
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"# policy: open"* ]]
    [[ "${output}" == *'      - "egress-out"
      - "docker-code-net"'* ]]
    [[ "${output}" == *'  docker-code-net:
    name: "docker-code-net"
    external: true'* ]]
}

@test "docker-code compose writes compose.yml and will not replace one unasked" {
    run "${REPO_ROOT}/bin/docker-code" compose claude
    [ "${status}" -eq 0 ]
    grep -q 'container_name: "claude-docker-remote_workspace"' "${WORKSPACE}/compose.yml"
    [[ "${output}" == *"docker-code attach claude-docker-remote_workspace"* ]]

    echo "keep me" >"${WORKSPACE}/compose.yml"
    run "${REPO_ROOT}/bin/docker-code" compose claude
    [ "${status}" -ne 0 ]
    [ "$(cat "${WORKSPACE}/compose.yml")" = "keep me" ]

    run "${REPO_ROOT}/bin/docker-code" compose --force claude
    [ "${status}" -eq 0 ]
    grep -q 'restart: "unless-stopped"' "${WORKSPACE}/compose.yml"
}

@test "docker-code compose asks whether to use the shell's settings, and keeps them on yes" {
    export DOCKER_CODE_YOLO=1
    run "${REPO_ROOT}/bin/docker-code" compose --ask --stdout claude <<<"$(printf 'y\nmy name\n')"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DOCKER_CODE_YOLO=1"* ]]
    [[ "${output}" == *'- "DOCKER_CODE_YOLO=1"'* ]]
    [[ "${output}" == *'container_name: "claude-docker-remote_my-name"'* ]]
}

@test "docker-code compose asks for the important settings when the shell's are declined" {
    export DOCKER_CODE_YOLO=1 DOCKER_CODE_CLAUDE_DIND=rootless
    # decline, name, network, policy, extra domains, YOLO, inner Docker, restart
    answers="$(printf 'n\nproj\ngateway\nopen\nexample.org\nn\n0\nalways\n')"
    run "${REPO_ROOT}/bin/docker-code" compose --ask --stdout claude <<<"${answers}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'- "DOCKER_CODE_YOLO=0"'* ]]
    [[ "${output}" == *'- "DOCKER_CODE_DIND=0"'* ]]
    [[ "${output}" != *"privileged: true"* ]]
    [[ "${output}" == *'restart: "always"'* ]]
    [[ "${output}" == *"# policy: open"* ]]
    [[ "${output}" == *'- "DOCKER_CODE_ALLOW_DOMAINS=example.org"'* ]]
    [[ "${output}" == *'container_name: "claude-docker-remote_proj"'* ]]
}

@test "docker-code compose asks again on an answer that is not one of the choices" {
    # A file, not a here-string: $(…) would strip the trailing empty answers that take the defaults.
    printf '\nnowhere\nnone\n\n\n\n' >"${BATS_TEST_TMPDIR}/answers"
    run "${REPO_ROOT}/bin/docker-code" compose --ask --stdout claude <"${BATS_TEST_TMPDIR}/answers"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"one of: full restricted gateway none"* ]]
    [[ "${output}" == *'network_mode: "none"'* ]]
}

@test "docker-code compose stops rather than guessing when the answers run out" {
    run "${REPO_ROOT}/bin/docker-code" compose --ask --stdout claude </dev/null
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"--yes"* ]]
}

@test "the template a session leaves becomes the same file docker-code compose prints" {
    unset DOCKER_CODE_DRY_RUN
    export DOCKER_CODE_AUTO_UPDATE=0
    run "${REPO_ROOT}/bin/claude-docker"
    [ "${status}" -eq 0 ]
    template="$(stub_calls docker | grep -o 'DOCKER_CODE_COMPOSE_TEMPLATE=[^ ]*' | head -n 1)"
    template="${DOCKER_CODE_HOME}/claude/${template#DOCKER_CODE_COMPOSE_TEMPLATE=/home/agent/}"
    [ -s "${template}" ]
    grep -q '__DOCKER_CODE_SLUG__' "${template}"

    # Inside the session: the /remote skill, with a name of its own.
    DOCKER_CODE_COMPOSE_TEMPLATE="${template}" run "${REPO_ROOT}/image/compose.sh" "Side Project"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"claude-docker-remote_side-project"* ]]

    export DOCKER_CODE_DRY_RUN=1 DOCKER_CODE_NAME="Side Project"
    run "${REPO_ROOT}/bin/docker-code" compose --stdout claude
    [ "${status}" -eq 0 ]
    diff <(printf '%s\n' "${output}" | grep -v '^docker-code:') "${WORKSPACE}/compose.yml"
}

@test "a gateway session's template carries the gateway into the compose file" {
    unset DOCKER_CODE_DRY_RUN
    export DOCKER_CODE_AUTO_UPDATE=0 DOCKER_CODE_NET=gateway
    # egress_start needs a gateway that comes up; the stub reports it running and ready.
    make_stub docker 'case "$1" in inspect) echo true ;; esac'
    run "${REPO_ROOT}/bin/claude-docker"
    template="$(stub_calls docker | grep -o 'DOCKER_CODE_COMPOSE_TEMPLATE=[^ ]*' | head -n 1)"
    [ -n "${template}" ]
    template="${DOCKER_CODE_HOME}/claude/${template#DOCKER_CODE_COMPOSE_TEMPLATE=/home/agent/}"
    grep -q '^  egress:$' "${template}"
    grep -q 'HTTPS_PROXY=http://egress:3128' "${template}"
}

@test "the /remote skill's command will not overwrite a compose.yml unasked" {
    printf 'name: "x"\n' >"${BATS_TEST_TMPDIR}/template.yml"
    echo "keep me" >"${WORKSPACE}/compose.yml"
    DOCKER_CODE_COMPOSE_TEMPLATE="${BATS_TEST_TMPDIR}/template.yml" run "${REPO_ROOT}/image/compose.sh"
    [ "${status}" -ne 0 ]
    [ "$(cat "${WORKSPACE}/compose.yml")" = "keep me" ]

    DOCKER_CODE_COMPOSE_TEMPLATE="${BATS_TEST_TMPDIR}/template.yml" run "${REPO_ROOT}/image/compose.sh" --force
    [ "${status}" -eq 0 ]
    [ "$(cat "${WORKSPACE}/compose.yml")" = 'name: "x"' ]
}

@test "the /remote skill's command explains a session without a template" {
    run "${REPO_ROOT}/image/compose.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"without a compose template"* ]]
    [ ! -e "${WORKSPACE}/compose.yml" ]
}
