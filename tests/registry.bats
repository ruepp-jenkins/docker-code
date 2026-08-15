#!/usr/bin/env bats
# The agent registry contract.
#
# This is the file that makes "adding a tool is adding a folder" a promise rather than a hope: every
# rule the launcher, the installer and the CI matrix rely on is asserted here, so a new agents/<id>/
# either satisfies all of them or fails the build with a message naming what it is missing.

load helper

setup() {
    reset_docker_code_env
    export DOCKER_CODE_ROOT="${REPO_ROOT}"
}

@test "there is at least one agent" {
    run all_agent_ids
    [ "${status}" -eq 0 ]
    [ -n "${output}" ]
}

@test "lib/agents.sh parses every agent.env" {
    for id in $(all_agent_ids); do
        run bash -c ". '${REPO_ROOT}/lib/agents.sh'; agent_load '${id}'"
        [ "${status}" -eq 0 ] || {
            echo "agent ${id} failed to load: ${output}"
            return 1
        }
    done
}

@test "every agent passes its own validation" {
    run bash -c ". '${REPO_ROOT}/lib/agents.sh'; agents_validate_all"
    [ "${status}" -eq 0 ] || {
        echo "${output}"
        return 1
    }
}

@test "AGENT_ID matches the directory name" {
    for id in $(all_agent_ids); do
        [ "$(agent_field "${id}" AGENT_ID)" = "${id}" ]
    done
}

@test "every wrapper name ends in -docker" {
    for id in $(all_agent_ids); do
        case "$(agent_field "${id}" AGENT_WRAPPER)" in
            *-docker) ;;
            *) echo "agent ${id} has a wrapper that would shadow the real command"; return 1 ;;
        esac
    done
}

@test "no wrapper name equals the command it wraps" {
    # The whole reason for the suffix: typing `gemini` must still reach the gemini on your PATH.
    for id in $(all_agent_ids); do
        [ "$(agent_field "${id}" AGENT_WRAPPER)" != "$(agent_field "${id}" AGENT_BIN)" ]
    done
}

@test "wrapper names and commands are unique across agents" {
    wrappers="$(for id in $(all_agent_ids); do agent_field "${id}" AGENT_WRAPPER; done | sort)"
    [ "$(printf '%s\n' "${wrappers}" | wc -l)" -eq "$(printf '%s\n' "${wrappers}" | sort -u | wc -l)" ]

    bins="$(for id in $(all_agent_ids); do agent_field "${id}" AGENT_BIN; done | sort)"
    [ "$(printf '%s\n' "${bins}" | wc -l)" -eq "$(printf '%s\n' "${bins}" | sort -u | wc -l)" ]
}

@test "every agent has a Dockerfile that builds FROM the shared base" {
    for id in $(all_agent_ids); do
        file="${REPO_ROOT}/agents/${id}/Dockerfile"
        [ -f "${file}" ] || { echo "agents/${id}/Dockerfile is missing"; return 1; }
        grep -q '^ARG BASE_IMAGE=' "${file}" || {
            echo "agents/${id}/Dockerfile does not declare ARG BASE_IMAGE"; return 1
        }
        grep -q '^FROM \${BASE_IMAGE}' "${file}" || {
            echo "agents/${id}/Dockerfile does not build FROM \${BASE_IMAGE}"; return 1
        }
    done
}

@test "every agent Dockerfile installs its own agent.env" {
    # launch.sh and init-firewall.sh read /etc/docker-code/agent.env; an image without it starts and
    # then fails at the last moment with a message about a file the user never wrote.
    for id in $(all_agent_ids); do
        grep -q "COPY agents/${id}/agent.env /etc/docker-code/agent.env" \
            "${REPO_ROOT}/agents/${id}/Dockerfile" || {
            echo "agents/${id}/Dockerfile does not COPY its agent.env"; return 1
        }
    done
}

@test "every agent Dockerfile smoke-tests its own binary" {
    # A broken image should fail in the build, not in front of a user — and per architecture, so an
    # arm64 image that cannot execute its own binaries never gets pushed.
    for id in $(all_agent_ids); do
        bin="$(agent_field "${id}" AGENT_BIN)"
        grep -q "${bin} --version" "${REPO_ROOT}/agents/${id}/Dockerfile" || {
            echo "agents/${id}/Dockerfile never runs ${bin} --version"; return 1
        }
    done
}

@test "a Dockerfile that seeds defaults has a defaults directory, and vice versa" {
    for id in $(all_agent_ids); do
        file="${REPO_ROOT}/agents/${id}/Dockerfile"
        if grep -q "COPY agents/${id}/defaults/" "${file}"; then
            [ -d "${REPO_ROOT}/agents/${id}/defaults" ] || {
                echo "agents/${id}/Dockerfile copies defaults/ but the directory does not exist"
                return 1
            }
        elif [ -d "${REPO_ROOT}/agents/${id}/defaults" ]; then
            echo "agents/${id}/defaults exists but the Dockerfile never copies it"
            return 1
        fi
    done
}

@test "an agent that claims a local-model mode says how to reach it" {
    for id in $(all_agent_ids); do
        mode="$(agent_field "${id}" AGENT_LOCAL_MODE)"
        [ -n "${mode}" ] || mode=none
        [ "${mode}" = "none" ] && continue
        [ -n "$(agent_field "${id}" AGENT_LOCAL_ENV)" ] || {
            echo "agent ${id} sets AGENT_LOCAL_MODE=${mode} but no AGENT_LOCAL_ENV"; return 1
        }
    done
}

@test "an agent with no local-model support explains itself" {
    # DOCKER_CODE_LOCAL silently doing nothing is the kind of thing a user files a bug about.
    for id in $(all_agent_ids); do
        [ "$(agent_field "${id}" AGENT_LOCAL_MODE)" = "none" ] || continue
        [ -n "$(agent_field "${id}" AGENT_NOTE)" ] || {
            echo "agent ${id} cannot use local models but has no AGENT_NOTE saying so"; return 1
        }
    done
}

@test "every agent names the domains its restricted mode needs" {
    for id in $(all_agent_ids); do
        [ -n "$(agent_field "${id}" AGENT_DOMAINS)" ] || {
            echo "agent ${id} has no AGENT_DOMAINS, so DOCKER_CODE_NET=restricted would cut it off"
            return 1
        }
    done
}

@test "an unknown key in agent.env is rejected rather than ignored" {
    tmp="${BATS_TEST_TMPDIR}/agents"
    mkdir -p "${tmp}/bogus"
    cat >"${tmp}/bogus/agent.env" <<'EOF'
AGENT_ID=bogus
AGENT_BIN=bogus
AGENT_WRAPPER=bogus-docker
AGENT_TYPOED_KEY=oops
EOF
    run bash -c ". '${REPO_ROOT}/lib/agents.sh'; AGENTS_DIR='${tmp}' agent_load bogus"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"AGENT_TYPOED_KEY"* ]]
}

@test "a wrapper name without the -docker suffix is rejected" {
    tmp="${BATS_TEST_TMPDIR}/agents"
    mkdir -p "${tmp}/bogus"
    cat >"${tmp}/bogus/agent.env" <<'EOF'
AGENT_ID=bogus
AGENT_BIN=bogus
AGENT_WRAPPER=bogus
EOF
    touch "${tmp}/bogus/Dockerfile"
    run bash -c ". '${REPO_ROOT}/lib/agents.sh'; AGENTS_DIR='${tmp}' agent_validate bogus"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"-docker"* ]]
}

@test "line continuations in agent.env are joined, not truncated" {
    # The long lists (env vars, domains) are written across several lines; a parser that stopped at
    # the backslash would silently pass through only the first few variables.
    for id in $(all_agent_ids); do
        run bash -c ". '${REPO_ROOT}/lib/agents.sh'; agent_load '${id}'; printf '%s' \"\${AGENT_ENV_VARS}\""
        [ "${status}" -eq 0 ]
        [[ "${output}" != *'\'* ]] || {
            echo "agent ${id}: AGENT_ENV_VARS still contains a backslash: ${output}"; return 1
        }
    done
}

@test "the launcher resolves every wrapper name back to its agent" {
    for id in $(all_agent_ids); do
        wrapper="$(agent_field "${id}" AGENT_WRAPPER)"
        run bash -c ". '${REPO_ROOT}/lib/agents.sh'; agent_for_wrapper '${wrapper}'"
        [ "${status}" -eq 0 ]
        [ "${output}" = "${id}" ]
    done
}

@test "there is a symlink in bin/ for every wrapper" {
    for id in $(all_agent_ids); do
        wrapper="$(agent_field "${id}" AGENT_WRAPPER)"
        [ -L "${REPO_ROOT}/bin/${wrapper}" ] || {
            echo "bin/${wrapper} is missing; run: ln -s docker-code bin/${wrapper}"; return 1
        }
        [ "$(readlink "${REPO_ROOT}/bin/${wrapper}")" = "docker-code" ] || {
            echo "bin/${wrapper} does not point at docker-code"; return 1
        }
    done
}
