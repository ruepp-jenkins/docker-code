# shellcheck shell=bash
# The agent registry.
#
# Sourced by bin/docker-code and by the bats suite, so there is exactly one place that knows which
# tools exist and what each one needs. Adding a tool means adding agents/<id>/agent.env — nothing
# here changes.
#
# Deliberately bash 3.2 compatible (macOS ships 3.2): no associative arrays, no mapfile, no ${x,,}.

# ---------------------------------------------------------------------------------------------
# Where the registry lives
#
# Two layouts have to work: a git checkout (lib/ and agents/ side by side) and an installation
# (a copy of both under ~/.local/share/docker-code). Resolving from this file's own location
# covers both without a search path.
# ---------------------------------------------------------------------------------------------
if [ -z "${DOCKER_CODE_ROOT:-}" ]; then
    _agents_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    DOCKER_CODE_ROOT="$(dirname "${_agents_sh_dir}")"
    unset _agents_sh_dir
fi
AGENTS_DIR="${DOCKER_CODE_AGENTS_DIR:-${DOCKER_CODE_ROOT}/agents}"

# Every key an agent.env may set. A file that sets anything else is a typo we want to hear about
# rather than silently ignore, and the list doubles as the documentation of the contract.
AGENT_KEYS="AGENT_ID AGENT_TITLE AGENT_BIN AGENT_WRAPPER AGENT_HOSTNAME AGENT_ALIASES \
AGENT_YOLO_ARGS AGENT_YOLO_SKIP AGENT_PERMISSION_FLAGS AGENT_ROOT_ENV AGENT_ENV_VARS \
AGENT_DOMAINS AGENT_LOCAL_MODE AGENT_LOCAL_ENV AGENT_LOCAL_ARGS AGENT_NOTE"

AGENT_REQUIRED_KEYS="AGENT_ID AGENT_BIN AGENT_WRAPPER"

# ---------------------------------------------------------------------------------------------
# Parsing
#
# agent.env is read, not sourced. It is repo-local data, but a file format that executes whatever
# it contains is a bad contract to hand to "just add a folder" — and a parser is something the
# test suite can point at malformed input without running it.
# ---------------------------------------------------------------------------------------------

agents_clear() {
    local key
    for key in ${AGENT_KEYS}; do
        unset "${key}"
    done
}

# agent_parse_file <path>
#
# Sets the AGENT_* variables from the file. Blank lines and # comments are skipped; values may be
# bare, 'single' or "double" quoted; a trailing # comment is only stripped from bare values, so a
# quoted value can contain a #.
agent_parse_file() {
    local file="$1"
    local line raw key value known pending=""

    [ -f "${file}" ] || return 1

    while IFS= read -r raw || [ -n "${raw}" ]; do
        # A comment is never a continuation, so a stray backslash at the end of a sentence cannot
        # swallow the line below it.
        if [ -z "${pending}" ]; then
            case "${raw}" in
                ''|'#'*) continue ;;
            esac
        else
            raw="${pending}${raw#"${raw%%[![:space:]]*}"}"
            pending=""
        fi

        # A trailing backslash continues the value on the next line. The long lists (env vars,
        # domains) are unreadable on one line, and an unreadable contract does not get maintained.
        case "${raw}" in
            *\\)
                pending="${raw%\\}"
                pending="${pending%"${pending##*[![:space:]]}"} "
                continue
                ;;
        esac
        line="${raw}"

        case "${line}" in
            *=*) ;;
            *) echo "docker-code: ${file}: not a KEY=value line: ${line}" >&2; return 1 ;;
        esac

        key="${line%%=*}"
        value="${line#*=}"

        # Leading and trailing whitespace around the key, e.g. an indented file.
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        case "${key}" in
            [A-Z]*) ;;
            *) echo "docker-code: ${file}: not a valid key: ${key}" >&2; return 1 ;;
        esac

        known=0
        for k in ${AGENT_KEYS}; do
            [ "${k}" = "${key}" ] && known=1 && break
        done
        if [ "${known}" != "1" ]; then
            echo "docker-code: ${file}: unknown key ${key} (see ai/adding-an-agent.md for the contract)" >&2
            return 1
        fi

        value="${value#"${value%%[![:space:]]*}"}"

        case "${value}" in
            \"*\")  value="${value#\"}"; value="${value%\"}" ;;
            \'*\')  value="${value#\'}"; value="${value%\'}" ;;
            *)
                # Bare value: strip a trailing comment, then trailing whitespace.
                value="${value%%#*}"
                value="${value%"${value##*[![:space:]]}"}"
                ;;
        esac

        eval "${key}=\${value}"
    done <"${file}"
}

# agent_load <id>
#
# Clears any previously loaded agent, then populates AGENT_* for this one. Defaults are filled in
# here rather than repeated in every agent file: only the three required keys are ever mandatory.
agent_load() {
    local id="$1"
    local file="${AGENTS_DIR}/${id}/agent.env"

    agents_clear

    if [ ! -f "${file}" ]; then
        echo "docker-code: unknown agent '${id}'; known agents: $(agent_ids | tr '\n' ' ')" >&2
        return 1
    fi

    agent_parse_file "${file}" || return 1

    if [ "${AGENT_ID:-}" != "${id}" ]; then
        echo "docker-code: ${file}: AGENT_ID is '${AGENT_ID:-}' but the directory is '${id}'" >&2
        return 1
    fi

    AGENT_TITLE="${AGENT_TITLE:-${AGENT_ID}}"
    AGENT_HOSTNAME="${AGENT_HOSTNAME:-${AGENT_ID}}"
    AGENT_LOCAL_MODE="${AGENT_LOCAL_MODE:-none}"
    AGENT_ALIASES="${AGENT_ALIASES:-}"
    AGENT_YOLO_ARGS="${AGENT_YOLO_ARGS:-}"
    AGENT_YOLO_SKIP="${AGENT_YOLO_SKIP:-}"
    # Default: a user who already typed the bypass flag themselves gets it left alone.
    AGENT_PERMISSION_FLAGS="${AGENT_PERMISSION_FLAGS:-${AGENT_YOLO_ARGS}}"
    AGENT_ROOT_ENV="${AGENT_ROOT_ENV:-}"
    AGENT_ENV_VARS="${AGENT_ENV_VARS:-}"
    AGENT_DOMAINS="${AGENT_DOMAINS:-}"
    AGENT_LOCAL_ENV="${AGENT_LOCAL_ENV:-}"
    AGENT_LOCAL_ARGS="${AGENT_LOCAL_ARGS:-}"
    AGENT_NOTE="${AGENT_NOTE:-}"
}

# Sorted, so `docker-code list` and the CI matrix are in a stable order regardless of the
# filesystem's idea of directory order.
agent_ids() {
    local dir id
    for dir in "${AGENTS_DIR}"/*/; do
        [ -f "${dir}agent.env" ] || continue
        id="${dir%/}"
        id="${id##*/}"
        printf '%s\n' "${id}"
    done | sort
}

# agent_for_wrapper <name>
#
# The reverse lookup the launcher does on its own basename. Matches AGENT_WRAPPER first, then any
# name in AGENT_ALIASES, so a tool can be reachable under more than one command.
agent_for_wrapper() {
    local want="$1"
    local id alias

    for id in $(agent_ids); do
        agent_load "${id}" >/dev/null 2>&1 || continue
        if [ "${AGENT_WRAPPER}" = "${want}" ]; then
            printf '%s\n' "${id}"
            return 0
        fi
        for alias in ${AGENT_ALIASES}; do
            if [ "${alias}" = "${want}" ]; then
                printf '%s\n' "${id}"
                return 0
            fi
        done
    done
    return 1
}

# Every wrapper name the installer should create, one per line, in `<id> <wrapper>` form.
agent_wrappers() {
    local id alias
    for id in $(agent_ids); do
        agent_load "${id}" >/dev/null 2>&1 || continue
        printf '%s %s\n' "${id}" "${AGENT_WRAPPER}"
        for alias in ${AGENT_ALIASES}; do
            printf '%s %s\n' "${id}" "${alias}"
        done
    done
}

# agent_validate <id>
#
# Everything that must hold for one agent in isolation. Cross-agent uniqueness is
# agents_validate_all's job, because it is the only check that needs to see all of them.
agent_validate() {
    local id="$1"
    local key value ok=0

    agent_load "${id}" || return 1

    for key in ${AGENT_REQUIRED_KEYS}; do
        eval "value=\${${key}:-}"
        if [ -z "${value}" ]; then
            echo "docker-code: agent '${id}': ${key} is required" >&2
            return 1
        fi
    done

    # The whole point of the suffix is that `claude-docker` cannot be mistaken for `claude`.
    case "${AGENT_WRAPPER}" in
        *-docker) ;;
        *) echo "docker-code: agent '${id}': AGENT_WRAPPER must end in -docker, got '${AGENT_WRAPPER}'" >&2
           return 1 ;;
    esac

    case "${AGENT_LOCAL_MODE}" in
        none|ollama-anthropic|openai-compat|litellm-gemini|litellm-openai|litellm-anthropic) ok=1 ;;
    esac
    if [ "${ok}" != "1" ]; then
        echo "docker-code: agent '${id}': unknown AGENT_LOCAL_MODE '${AGENT_LOCAL_MODE}'" >&2
        return 1
    fi

    if [ "${AGENT_LOCAL_MODE}" != "none" ] && [ -z "${AGENT_LOCAL_ENV}" ]; then
        echo "docker-code: agent '${id}': AGENT_LOCAL_MODE is set but AGENT_LOCAL_ENV is empty" >&2
        return 1
    fi

    if [ ! -f "${AGENTS_DIR}/${id}/Dockerfile" ]; then
        echo "docker-code: agent '${id}': agents/${id}/Dockerfile is missing" >&2
        return 1
    fi
}

# The check the test suite and `docker-code doctor` both run: every agent is valid on its own, and
# no two agents claim the same id, wrapper name, command or state directory.
agents_validate_all() {
    local id seen_wrappers="" seen_bins="" entry wrapper rc=0

    for id in $(agent_ids); do
        agent_validate "${id}" || rc=1
    done
    [ "${rc}" = "0" ] || return 1

    while read -r id wrapper; do
        [ -n "${wrapper}" ] || continue
        case " ${seen_wrappers} " in
            *" ${wrapper} "*)
                echo "docker-code: wrapper name '${wrapper}' is claimed by more than one agent" >&2
                rc=1 ;;
        esac
        seen_wrappers="${seen_wrappers} ${wrapper}"
    done <<EOF
$(agent_wrappers)
EOF

    for id in $(agent_ids); do
        agent_load "${id}" >/dev/null 2>&1 || continue
        entry="${AGENT_BIN}"
        case " ${seen_bins} " in
            *" ${entry} "*)
                echo "docker-code: command '${entry}' is claimed by more than one agent" >&2
                rc=1 ;;
        esac
        seen_bins="${seen_bins} ${entry}"
    done

    return "${rc}"
}
