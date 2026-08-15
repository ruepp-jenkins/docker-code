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

@test "pulling a model without the services running says how to start them" {
    make_stub docker 'echo ""'
    run models_sh 'models_exec_ollama pull anything'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"docker-code models up"* ]]
}
