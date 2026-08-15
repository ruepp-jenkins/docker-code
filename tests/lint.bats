#!/usr/bin/env bats
# shellcheck, exec bits, and the small consistency checks that catch a stale file before a user does.

load helper

all_shell_files() {
    printf '%s\n' \
        "${REPO_ROOT}/bin/docker-code" \
        "${REPO_ROOT}/install.sh"
    find "${REPO_ROOT}/lib" "${REPO_ROOT}/image" "${REPO_ROOT}/scripts" -name '*.sh' | sort
}

@test "shellcheck passes on every shell file" {
    while IFS= read -r file; do
        run shellcheck --external-sources --source-path="${REPO_ROOT}" "${file}"
        [ "${status}" -eq 0 ] || {
            echo "shellcheck failed for ${file}:"
            echo "${output}"
            return 1
        }
    done <<EOF
$(all_shell_files)
EOF
}

@test "everything meant to be executed is executable" {
    for file in "${REPO_ROOT}/bin/docker-code" "${REPO_ROOT}/install.sh" \
                "${REPO_ROOT}"/image/*.sh "${REPO_ROOT}"/scripts/*.sh; do
        [ -x "${file}" ] || { echo "${file} is not executable"; return 1; }
    done
}

@test "the sourced libraries are not executable, so nobody runs one by mistake" {
    for file in "${REPO_ROOT}"/lib/*.sh; do
        [ ! -x "${file}" ] || { echo "${file} is executable but is meant to be sourced"; return 1; }
    done
}

@test "every seeded default is valid for its format" {
    for file in $(find "${REPO_ROOT}/agents" -name '*.json'); do
        run jq empty "${file}"
        [ "${status}" -eq 0 ] || { echo "${file} is not valid JSON: ${output}"; return 1; }
    done
}

@test "a seeded default lands somewhere the tool will look" {
    # The defaults directory mirrors the home directory, so a file at defaults/foo would end up as
    # ~/foo — almost certainly not what was meant.
    for id in $(all_agent_ids); do
        dir="${REPO_ROOT}/agents/${id}/defaults"
        [ -d "${dir}" ] || continue
        for file in $(find "${dir}" -type f); do
            rel="${file#"${dir}"/}"
            case "${rel}" in
                */*) ;;
                .*) ;;
                *) echo "agents/${id}/defaults/${rel} would be seeded as ~/${rel}"; return 1 ;;
            esac
        done
    done
}

@test "the files the docs point at exist" {
    for doc in README.md AGENTS.md LOCAL-MODELS.md REGISTRY.md; do
        [ -f "${REPO_ROOT}/${doc}" ] || { echo "${doc} is missing"; return 1; }
    done
}

@test "the help text names only commands that exist" {
    run "${REPO_ROOT}/bin/docker-code" help
    [ "${status}" -eq 0 ]
    for cmd in list build update models registry doctor; do
        [[ "${output}" == *"${cmd}"* ]] || { echo "help does not mention ${cmd}"; return 1; }
        grep -q "^    ${cmd}[)|]" "${REPO_ROOT}/bin/docker-code" ||
            grep -q "^    ${cmd}|" "${REPO_ROOT}/bin/docker-code" || {
                echo "help mentions ${cmd} but the dispatcher has no branch for it"; return 1
            }
    done
}

@test "every wrapper the help text names is one an agent actually claims" {
    # The direction that matters: an example left behind after a tool was renamed or removed sends
    # the reader to a command that does not exist.
    run "${REPO_ROOT}/bin/docker-code" help
    [ "${status}" -eq 0 ]

    # A leading [a-z0-9] so a placeholder like <agent>-docker does not decompose into "-docker".
    names="$(printf '%s\n' "${output}" | tr -c 'a-z0-9-' '\n' | grep -E '^[a-z0-9][a-z0-9-]*-docker$' | sort -u)"
    for word in ${names}; do
        run bash -c ". '${REPO_ROOT}/lib/agents.sh'; agent_for_wrapper '${word}'"
        [ "${status}" -eq 0 ] || {
            echo "the help text names ${word}, which no agent claims"; return 1
        }
    done
}

@test "the installer never uses sudo and never edits a shell startup file" {
    # Both are promises made in install.sh's own header, and both are the kind of thing that gets
    # added in a hurry when a PATH problem shows up.
    ! grep -q 'sudo' "${REPO_ROOT}/install.sh"
    ! grep -qE '>>?\s*"?\$\{?HOME\}?/\.(bashrc|zshrc|profile)' "${REPO_ROOT}/install.sh"
}

@test "the installer validates a download before installing it" {
    grep -q "head -n 1.*grep -q '\^#!'" "${REPO_ROOT}/install.sh"
    grep -q 'DOCKER_CODE_HOME' "${REPO_ROOT}/install.sh"
}

@test "the installer derives wrapper names from the tree, not from a list of its own" {
    grep -q 'AGENT_WRAPPER' "${REPO_ROOT}/install.sh"
    for id in $(all_agent_ids); do
        wrapper="$(agent_field "${id}" AGENT_WRAPPER)"
        grep -q "${wrapper}" "${REPO_ROOT}/install.sh" && {
            echo "install.sh hard-codes ${wrapper}; it should read agents/*/agent.env"; return 1
        }
    done
    return 0
}
