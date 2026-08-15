#!/usr/bin/env bats
# What a session must NOT be able to reach.
#
# The list of host paths a container can see is short on purpose, and a short list only stays short
# if something objects when it grows. These are the negative assertions: each one fails the moment a
# future change hands a session more of the host than it had.
#
# Scope note: this is filesystem containment. The default inner-Docker mode is `privileged`, so the
# container is explicitly not a security boundary against the host — README.md says so. What is
# asserted here is that an agent sees its own state and the project you started it in, and nothing
# else of yours.

load helper

setup() {
    setup_wrapper_env

    # A home with the things a careless mount would pick up.
    mkdir -p "${HOME}/.ssh" "${HOME}/Documents"
    echo "[user]" >"${HOME}/.gitconfig"
    echo "secret" >"${HOME}/.ssh/id_ed25519"
}

# Every mount a wrapper would create, one "source:target" per line.
mounts_of() {
    "${REPO_ROOT}/bin/$1" 2>/dev/null | tr ' ' '\n' | grep -A1 -x -- '--volume' | grep -v -x -- '--volume'
}

@test "no agent mounts the user's home directory" {
    for id in $(all_agent_ids); do
        wrapper="$(agent_field "${id}" AGENT_WRAPPER)"
        run "${REPO_ROOT}/bin/${wrapper}"
        [[ "${output}" != *"--volume ${HOME}:"* ]] || {
            echo "${wrapper} mounts the user's home: ${output}"; return 1
        }
    done
}

@test "no agent mounts the host's Docker socket" {
    # A container holding /var/run/docker.sock is effectively root on the host, and it would also
    # make every image the agent builds visible to every other tool on the machine.
    for id in $(all_agent_ids); do
        wrapper="$(agent_field "${id}" AGENT_WRAPPER)"
        run "${REPO_ROOT}/bin/${wrapper}"
        [[ "${output}" != *"docker.sock"* ]] || {
            echo "${wrapper} mounts a Docker socket: ${output}"; return 1
        }
    done
}

@test "no agent mounts a host path outside its own state and the workspace" {
    for id in $(all_agent_ids); do
        wrapper="$(agent_field "${id}" AGENT_WRAPPER)"
        while IFS= read -r spec; do
            [ -n "${spec}" ] || continue
            source="${spec%%:*}"
            case "${source}" in
                /*) ;;
                *) continue ;;    # a named volume, not a host path
            esac
            case "${source}" in
                "${WORKSPACE}"|"${WORKSPACE}"/*) ;;
                "${DOCKER_CODE_HOME}"|"${DOCKER_CODE_HOME}"/*) ;;
                *) echo "${wrapper} mounts ${source}, which is neither the workspace nor its state"
                   return 1 ;;
            esac
        done <<EOF
$(mounts_of "${wrapper}")
EOF
    done
}

@test "the git config and the SSH agent are absent unless asked for" {
    dry_out="$("${REPO_ROOT}/bin/claude-docker" 2>/dev/null)"
    [[ "${dry_out}" != *".gitconfig"* ]]
    [[ "${dry_out}" != *"ssh-agent"* ]]
}

@test "DOCKER_CODE_GITCONFIG=1 mounts it read-only" {
    export DOCKER_CODE_GITCONFIG=1
    run "${REPO_ROOT}/bin/claude-docker"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--volume ${HOME}/.gitconfig:/home/agent/.gitconfig:ro"* ]]
}

@test "starting from the home directory is refused, not warned about" {
    cd "${HOME}"
    run "${REPO_ROOT}/bin/claude-docker"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"home directory"* ]]
}

@test "the home-directory refusal has a deliberate way out" {
    cd "${HOME}"
    export DOCKER_CODE_ALLOW_HOME_WORKSPACE=1
    run "${REPO_ROOT}/bin/claude-docker"
    [ "${status}" -eq 0 ]
}

@test "starting from / is refused" {
    cd /
    run "${REPO_ROOT}/bin/claude-docker"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"refusing to mount /"* ]]
}

@test "starting from inside the state directory is refused" {
    # Not just equality: a workspace *inside* ~/docker-code would hand one session every other
    # agent's credentials.
    mkdir -p "${DOCKER_CODE_HOME}/claude/projects"
    cd "${DOCKER_CODE_HOME}/claude/projects"
    run "${REPO_ROOT}/bin/claude-docker"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"every agent's state"* ]]
}

@test "one agent cannot see another agent's state directory" {
    for id in $(all_agent_ids); do
        wrapper="$(agent_field "${id}" AGENT_WRAPPER)"
        run "${REPO_ROOT}/bin/${wrapper}"
        for other in $(all_agent_ids); do
            [ "${other}" = "${id}" ] && continue
            [[ "${output}" != *"${DOCKER_CODE_HOME}/${other}:"* ]] || {
                echo "${wrapper} mounts ${other}'s state directory"; return 1
            }
        done
    done
}

@test "the shared model store is mounted read-only" {
    # It is the one directory every agent sees. A session able to rewrite it could hand every other
    # agent a different model than the one they asked for.
    mkdir -p "${DOCKER_CODE_HOME}/models/gguf"
    export DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=test
    run "${REPO_ROOT}/bin/qwen-docker"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"${DOCKER_CODE_HOME}/models/gguf:/models/gguf:ro"* ]]
}

@test "the container never runs with --user, so id alignment stays the entrypoint's job" {
    # --user would freeze the ids before the entrypoint could adopt the state directory, and the
    # first start on a fresh host would leave a home the agent cannot write.
    run "${REPO_ROOT}/bin/claude-docker"
    [[ "${output}" != *"--user "* ]]
    [[ "${output}" == *"--env DOCKER_CODE_HOST_UID="* ]]
}
