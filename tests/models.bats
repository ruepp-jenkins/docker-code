#!/usr/bin/env bats
# The shared local-model services.
#
# lib/models.sh is the only thing in the project that starts containers a user did not ask for by
# name, so its lifecycle is asserted against a programmable docker stub rather than a real daemon:
# what it starts, what it does not restart, and that every failure degrades to a session without
# local models rather than to no session at all.

load helper

setup() {
    reset_docker_code_env
    stub_dir

    export STORAGE_ROOT="${BATS_TEST_TMPDIR}/docker-code"
    mkdir -p "${STORAGE_ROOT}"
}

# lib/models.sh expects the launcher's warn/die and prepare_store to exist around it.
models_sh() {
    bash -c '
        warn() { echo "warn: $*" >&2; }
        die() { echo "die: $*" >&2; exit 1; }
        prepare_store() { case "$1" in /*) mkdir -p "$1";; esac; printf "%s\n" "$1"; }
        say() { echo "say: $*" >&2; }
        ensure_image() { echo "ensure_image: $1" >&2; }
        . "'"${REPO_ROOT}"'/lib/models.sh"
        '"$*"
}

@test "the weights live in one place, under the state directory" {
    run models_sh 'ollama_store'
    [ "${status}" -eq 0 ]
    [ "${output}" = "${STORAGE_ROOT}/models/ollama" ]
}

@test "the bridge forwards both services to loopback" {
    run models_sh 'models_bridge_spec'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"11434:docker-code-ollama:11434"* ]]
    [[ "${output}" == *"4000:docker-code-litellm:4000"* ]]
}

@test "an OpenAI-compatible tool is sent to Ollama, a Gemini-format one to the gateway" {
    run models_sh 'models_url_for_mode openai-compat'
    [ "${output}" = "http://localhost:11434" ]

    run models_sh 'models_url_for_mode ollama-anthropic'
    [ "${output}" = "http://localhost:11434" ]

    run models_sh 'models_url_for_mode litellm-gemini'
    [ "${output}" = "http://localhost:4000" ]
}

@test "an unknown mode is an error, not a silently wrong URL" {
    run models_sh 'models_url_for_mode nonsense'
    [ "${status}" -ne 0 ]
}

@test "the LiteLLM config is written once and then left alone" {
    run models_sh 'models_write_litellm_config'
    [ "${status}" -eq 0 ]

    config="${STORAGE_ROOT}/models/litellm/config.yaml"
    [ -f "${config}" ]
    # A wildcard, so a model pulled later is servable without another line in this file.
    grep -q 'model_name: "\*"' "${config}"
    grep -q "api_base: \"http://docker-code-ollama:11434\"" "${config}"

    echo "# user edit" >>"${config}"
    run models_sh 'models_write_litellm_config'
    grep -q "# user edit" "${config}"
}

@test "up starts both services on the model network" {
    make_stub docker 'case "$*" in
    "network inspect"*) exit 1 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'models_up'
    [ "${status}" -eq 0 ]

    calls="$(stub_calls docker)"
    [[ "${calls}" == *"network create"*"docker-code-net"* ]]
    [[ "${calls}" == *"--name docker-code-ollama"* ]]
    [[ "${calls}" == *"--name docker-code-litellm"* ]]
    [[ "${calls}" == *"${STORAGE_ROOT}/models/ollama:/root/.ollama"* ]]
}

@test "a service that is already running is not restarted" {
    make_stub docker 'case "$*" in
    *"State.Running"*) echo true ;;
    "network inspect"*) exit 0 ;;
esac'
    run models_sh 'models_up'
    [ "${status}" -eq 0 ]
    [[ "$(stub_calls docker)" != *"--name docker-code-ollama"* ]]
}

@test "nothing is published on the host unless asked for" {
    make_stub docker 'case "$*" in
    "network inspect"*) exit 1 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'models_up'
    [[ "$(stub_calls docker)" != *"--publish"* ]]

    stub_reset_calls docker
    run models_sh 'DOCKER_CODE_MODELS_PUBLISH=1 models_up'
    [[ "$(stub_calls docker)" == *"--publish 127.0.0.1:11434:11434"* ]]
}

@test "a gateway that will not start is a warning, not a failed session" {
    # Gemini loses its local model; Qwen and Codex talk to Ollama directly and are unaffected.
    make_stub docker 'case "$*" in
    "network inspect"*) exit 1 ;;
    *docker-code-litellm*) exit 1 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'models_up'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"LiteLLM gateway did not start"* ]]
}

@test "an Ollama that will not start does fail, because nothing else can serve a model" {
    make_stub docker 'case "$*" in
    "network inspect"*) exit 1 ;;
    *docker-code-ollama*) exit 1 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'models_up'
    [ "${status}" -ne 0 ]
}

@test "a container that will not start says why, in Docker's own words" {
    # The failure people actually hit is asking for a GPU the host cannot provide. Swallowing the
    # exit code would send them looking anywhere but at the GPU request.
    make_stub docker 'case "$*" in
    "network inspect"*) exit 1 ;;
    *docker-code-ollama*)
        echo "Error response from daemon: failed to discover GPU vendor from CDI" >&2
        exit 125 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'DOCKER_CODE_MODELS_GPU=1 models_up'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"failed to discover GPU vendor"* ]]
    [[ "${output}" == *"DOCKER_CODE_MODELS_GPU=0"* ]]
}

@test "down stops both services and removes the network" {
    make_stub docker
    run models_sh 'models_down'
    [ "${status}" -eq 0 ]
    calls="$(stub_calls docker)"
    # Stop before remove: SIGTERM and time to finish a write, rather than SIGKILL into it.
    [[ "${calls}" == *"stop docker-code-litellm"* ]]
    [[ "${calls}" == *"stop docker-code-ollama"* ]]
    [[ "${calls}" == *"network rm docker-code-net"* ]]
    [[ "${calls}" != *"rm -f"* ]]
}

@test "a network with the wrong subnet is rebuilt, one in use is left alone" {
    make_stub docker 'case "$*" in
    "network inspect"*IPAM*) echo "172.30.99.0/24" ;;
    "network inspect"*) exit 0 ;;
    "network rm"*) exit 1 ;;
esac'
    run models_sh 'models_ensure_network'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"in use"* ]]
}

@test "a GPU is requested only when Docker reports one" {
    # Asking for a GPU that is not there is a hard `docker run` error, so the auto path has to detect
    # rather than assume — and a host without the nvidia runtime must come up on the CPU, not fail.
    make_stub docker 'case "$*" in
    *Runtimes*) echo "io.containerd.runc.v2 runc " ;;
    "network inspect"*) exit 1 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'models_up'
    [ "${status}" -eq 0 ]
    [[ "$(stub_calls docker)" != *"--gpus"* ]]

    stub_reset_calls docker
    make_stub docker 'case "$*" in
    *Runtimes*) echo "io.containerd.runc.v2 nvidia runc " ;;
    "network inspect"*) exit 1 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'models_up'
    [[ "$(stub_calls docker)" == *"--gpus all"* ]]
}

@test "the runtime name is matched as a word, not as a substring" {
    # .Runtimes renders as kilobytes of capability detail; a loose grep over it would turn any
    # mention of a vendor name into a GPU request, and the container would then refuse to start.
    grep -q 'range \$name, \$r := .Runtimes' "${REPO_ROOT}/lib/models.sh"
    grep -q 'grep -qw nvidia' "${REPO_ROOT}/lib/models.sh"
}

@test "the GPU can be forced on, off, or pinned to one card" {
    # Detection only sees the toolkit's registered runtime; a CDI-only host has none, so there has to
    # be a way to say "yes, really".
    make_stub docker 'case "$*" in
    *Runtimes*) echo "runc " ;;
    "network inspect"*) exit 1 ;;
    inspect*) echo "" ;;
esac'

    run models_sh 'DOCKER_CODE_MODELS_GPU=1 models_up'
    [[ "$(stub_calls docker)" == *"--gpus all"* ]]

    stub_reset_calls docker
    run models_sh 'DOCKER_CODE_MODELS_GPU=device=0 models_up'
    [[ "$(stub_calls docker)" == *"--gpus device=0"* ]]

    stub_reset_calls docker
    run models_sh 'DOCKER_CODE_MODELS_GPU=0 models_up'
    [[ "$(stub_calls docker)" != *"--gpus"* ]]
}

@test "the AMD path binds the ROCm devices and takes the ROCm image" {
    # NVIDIA arrives through a container runtime that injects the card; AMD has no such runtime, so
    # the device nodes have to be named — and ROCm is a separate build of Ollama, not a flag on the
    # default one. Both halves have to happen from the single value, or the user gets a container
    # that starts and computes on the CPU anyway.
    make_stub docker 'case "$*" in
    *Runtimes*) echo "runc " ;;
    "network inspect"*) exit 1 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'DOCKER_CODE_MODELS_GPU=rocm models_up'
    [ "${status}" -eq 0 ]

    calls="$(stub_calls docker)"
    [[ "${calls}" == *"--device /dev/kfd"* ]]
    [[ "${calls}" == *"--device /dev/dri"* ]]
    [[ "${calls}" == *"ollama/ollama:rocm"* ]]
    [[ "${calls}" != *"--gpus"* ]]
}

@test "an image named by hand wins over the ROCm default" {
    make_stub docker 'case "$*" in
    "network inspect"*) exit 1 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'DOCKER_CODE_MODELS_GPU=rocm DOCKER_CODE_OLLAMA_IMAGE=my/ollama:custom models_up'
    calls="$(stub_calls docker)"
    [[ "${calls}" == *"my/ollama:custom"* ]]
    [[ "${calls}" != *"ollama/ollama:rocm"* ]]
    # Still the devices: the override says which image, not whether the card is bound in.
    [[ "${calls}" == *"--device /dev/kfd"* ]]
}

@test "the daemon takes extra environment and extra docker arguments" {
    # HSA_OVERRIDE_GFX_VERSION is what makes a card ROCm does not list by name run at all, and it
    # belongs to this daemon — a session variable would never reach it.
    make_stub docker 'case "$*" in
    "network inspect"*) exit 1 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'DOCKER_CODE_MODELS_GPU=rocm \
        DOCKER_CODE_OLLAMA_ENV="HSA_OVERRIDE_GFX_VERSION=11.0.0 HIP_VISIBLE_DEVICES=0" \
        DOCKER_CODE_OLLAMA_ARGS="--security-opt seccomp=unconfined" models_up'
    [ "${status}" -eq 0 ]

    calls="$(stub_calls docker)"
    [[ "${calls}" == *"--env HSA_OVERRIDE_GFX_VERSION=11.0.0"* ]]
    [[ "${calls}" == *"--env HIP_VISIBLE_DEVICES=0"* ]]
    [[ "${calls}" == *"--security-opt seccomp=unconfined"* ]]
}

@test "status answers the GPU question in its own right" {
    # Two separate facts, because they come apart: a container can be started with --gpus and Ollama
    # still fall back to the CPU. "requested at start" plus "computing on cpu" is the diagnosis.
    make_stub docker 'case "$*" in
    *DeviceRequests*) echo "null" ;;
    *logs*) echo "level=INFO msg=\"inference compute\" id=cpu library=cpu name=cpu description=cpu" ;;
    *) echo running ;;
esac'
    run models_sh 'models_status'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"not requested"* ]]
    [[ "${output}" == *"computing on cpu"* ]]
}

@test "status recognises the AMD path, which leaves no device request behind" {
    # --device does not show up in .HostConfig.DeviceRequests, so a status that only looked there
    # would tell an AMD user their card was never asked for while it is busy answering.
    make_stub docker 'case "$*" in
    *DeviceRequests*) echo "null" ;;
    *Devices*) echo "[{\"PathOnHost\":\"/dev/kfd\"}]" ;;
    *logs*) echo "level=INFO msg=\"inference compute\" id=0 library=rocm description=AMD-Radeon-RX-7900-XTX" ;;
    *) echo running ;;
esac'
    run models_sh 'models_status'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/dev/kfd"* ]]
    [[ "${output}" != *"not requested"* ]]
    [[ "${output}" == *"computing on rocm"* ]]
}

@test "the documented GPU values are the ones the code accepts" {
    block="$(sed -n '/DOCKER_CODE_MODELS_GPU:-auto/,/esac/p' "${REPO_ROOT}/lib/models.sh")"
    [ -n "${block}" ]
    # Every value the GPU table in docs/LOCAL-MODELS.md offers has to appear in that case statement, or
    # the page promises a setting that silently does something else.
    for value in auto 1 0 rocm; do
        [[ "${block}" == *"${value}"* ]] || {
            echo "docs/LOCAL-MODELS.md documents DOCKER_CODE_MODELS_GPU=${value}, the code has no branch for it"
            return 1
        }
    done
    grep -q 'DOCKER_CODE_MODELS_GPU' "${REPO_ROOT}/docs/LOCAL-MODELS.md"
    # And the page has to tell people how to check, not just how to set it.
    grep -q 'ollama ps' "${REPO_ROOT}/docs/LOCAL-MODELS.md"
    grep -q 'inference compute' "${REPO_ROOT}/docs/LOCAL-MODELS.md"
}

@test "the AMD knobs the page documents are knobs the code reads" {
    # The AMD path used to be a paragraph saying it was possible "via the environment", with no
    # variable behind it that did anything. Each of these has to exist on both sides.
    for var in DOCKER_CODE_OLLAMA_IMAGE DOCKER_CODE_OLLAMA_ENV DOCKER_CODE_OLLAMA_ARGS; do
        grep -q "${var}" "${REPO_ROOT}/lib/models.sh" || {
            echo "docs/LOCAL-MODELS.md documents ${var}, lib/models.sh never reads it"; return 1
        }
        grep -q "${var}" "${REPO_ROOT}/docs/LOCAL-MODELS.md" || {
            echo "lib/models.sh reads ${var}, docs/LOCAL-MODELS.md never mentions it"; return 1
        }
    done
    # The two device nodes are the whole AMD story; a page that names neither cannot be followed.
    grep -q '/dev/kfd' "${REPO_ROOT}/docs/LOCAL-MODELS.md"
    grep -q 'HSA_OVERRIDE_GFX_VERSION' "${REPO_ROOT}/docs/LOCAL-MODELS.md"
}

@test "status prints the endpoints and the API key" {
    # The key is undiscoverable otherwise: a session started with DOCKER_CODE_LOCAL=1 gets it set
    # automatically, so anyone configuring a tool by hand hits "API key required" with nothing to
    # type. `models status` is the first place they look.
    make_stub docker 'echo running'
    run models_sh 'models_status'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"docker-code-local"* ]]
    [[ "${output}" == *"localhost:11434/v1"* ]]
    [[ "${output}" == *"localhost:4000"* ]]
}

@test "the documented key is the one the code actually uses" {
    key="$(sed -n 's/^LOCAL_API_KEY="\(.*\)"$/\1/p' "${REPO_ROOT}/lib/models.sh")"
    [ -n "${key}" ]
    grep -q "${key}" "${REPO_ROOT}/docs/LOCAL-MODELS.md" || {
        echo "docs/LOCAL-MODELS.md does not name the API key '${key}'"; return 1
    }
    # And every agent that reaches a local model is handed it, rather than being left to guess.
    for id in $(all_agent_ids); do
        mode="$(agent_field "${id}" AGENT_LOCAL_MODE)"
        [ "${mode}" = "none" ] || [ -z "${mode}" ] && continue
        [[ "$(agent_field "${id}" AGENT_LOCAL_ENV)" == *"${key}"* ]] || {
            echo "agent ${id} uses local models but its AGENT_LOCAL_ENV never sets the key"
            return 1
        }
    done
}

@test "the documented example model is the same one throughout" {
    # A page that names three different models in three examples is a page people copy wrongly.
    models="$(grep -oE 'qwen2\.5-coder:[0-9.]+b' "${REPO_ROOT}/docs/LOCAL-MODELS.md" | sort -u)"
    [ "$(printf '%s\n' "${models}" | wc -l)" -le 2 ] || {
        echo "docs/LOCAL-MODELS.md mixes example models:"; echo "${models}"; return 1
    }
}

@test "pulling a model without the services running says how to start them" {
    make_stub docker 'echo ""'
    run models_sh 'models_exec_ollama pull anything'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"docker-code models up"* ]]
}

# ---------------------------------------------------------------------------------------------
# restart
# ---------------------------------------------------------------------------------------------

@test "restart recreates the containers rather than calling docker restart" {
    # The reason to restart one of these is almost always a setting that only applies at creation —
    # DOCKER_CODE_OLLAMA_ENV, a GPU mode, a pinned image tag, the LiteLLM config. `docker restart`
    # would keep the container as it was created and look like it had done nothing.
    make_stub docker 'case "$*" in
    "network inspect"*) exit 1 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'models_restart'
    [ "${status}" -eq 0 ]

    calls="$(stub_calls docker)"
    [[ "${calls}" != *"docker restart"* ]]
    [[ "${calls}" == *"rm -f docker-code-ollama"* ]]
    [[ "${calls}" == *"rm -f docker-code-litellm"* ]]
    [[ "${calls}" == *"--name docker-code-ollama"* ]]
    [[ "${calls}" == *"--name docker-code-litellm"* ]]
}

@test "restart stops before removing, so a write in flight gets its SIGTERM" {
    make_stub docker 'case "$*" in
    "network inspect"*) exit 1 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'models_restart ollama'
    [ "${status}" -eq 0 ]

    # The stop has to be recorded before the removal of the same container.
    calls="$(stub_calls docker)"
    stop_line="$(printf '%s\n' "${calls}" | grep -n '^stop docker-code-ollama' | head -n 1 | cut -d: -f1)"
    rm_line="$(printf '%s\n' "${calls}" | grep -n '^rm -f docker-code-ollama' | head -n 1 | cut -d: -f1)"
    [ -n "${stop_line}" ] && [ -n "${rm_line}" ]
    [ "${stop_line}" -lt "${rm_line}" ]
}

@test "naming one service restarts only that one" {
    # Editing LiteLLM's config.yaml — which is yours and never overwritten — needs only that half,
    # and taking Ollama down with it would drop a loaded model from VRAM for nothing.
    make_stub docker 'case "$*" in
    "network inspect"*) exit 0 ;;
    *"State.Running"*) echo true ;;
esac'
    run models_sh 'models_restart litellm'
    [ "${status}" -eq 0 ]

    calls="$(stub_calls docker)"
    [[ "${calls}" == *"rm -f docker-code-litellm"* ]]
    [[ "${calls}" != *"rm -f docker-code-ollama"* ]]
    [[ "${calls}" != *"stop docker-code-ollama"* ]]
}

@test "restart leaves the network alone, unlike down" {
    # Removing it would disturb every attached session to no purpose: the containers rejoin the same
    # network by name.
    make_stub docker 'case "$*" in
    "network inspect"*) exit 1 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'models_restart'
    [ "${status}" -eq 0 ]
    [[ "$(stub_calls docker)" != *"network rm"* ]]
}

@test "an unknown service is refused rather than silently restarting everything" {
    make_stub docker 'echo ""'
    run models_sh 'models_restart sideways'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"ollama"* ]]
    [[ "${output}" == *"litellm"* ]]
    [[ "$(stub_calls docker)" != *"rm -f"* ]]
}

@test "a missing image is pulled where its progress can be seen" {
    # Every start here sends docker run's output to /dev/null so that losing a name race stays quiet.
    # That also swallows the implicit pull, and Ollama is the largest image in the project — so a
    # first start looked like a hang for however long several GB take, with nothing on screen.
    make_stub docker 'case "$*" in
    "network inspect"*) exit 1 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'models_up'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ensure_image: ollama/ollama:latest"* ]]
    [[ "${output}" == *"ensure_image: ghcr.io/berriai/litellm:main-stable"* ]]
}

@test "each service says what it is starting rather than sitting silent" {
    make_stub docker 'case "$*" in
    "network inspect"*) exit 1 ;;
    inspect*) echo "" ;;
esac'
    run models_sh 'models_up'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"starting Ollama"* ]]
    [[ "${output}" == *"starting the LiteLLM gateway"* ]]
}

@test "an already-present image is not pulled again" {
    # ensure_image checks first; a pull on every start would add a registry round trip to a session
    # that needs nothing.
    run bash -c '
        docker() { echo "docker $*" >&2; return 0; }
        say() { echo "say: $*" >&2; }
        warn() { :; }
        ensure_image() {
            docker image inspect "$1" >/dev/null 2>&1 && return 0
            say "pulling $1"
            docker pull "$1" >&2
        }
        ensure_image already/there:1
    '
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"pulling"* ]]
    [[ "${output}" != *"docker pull"* ]]
}
