#!/bin/bash
# Builds the final command line and hands the process over to the agent.
#
# This runs as the unprivileged `agent` user, last in the entrypoint chain, and its only job is to
# decide which arguments the tool is started with. It is a separate file rather than a few lines at
# the end of user-init.sh because this is the one piece of argument handling that can silently break
# `claude -c` or `codex mcp list` for the user, and a separate file is a file the test suite can call
# directly.
#
# Nothing here knows any tool by name. Everything specific comes out of /etc/docker-code/agent.env,
# which the agent's own Dockerfile put there.
set -euo pipefail

AGENT_ENV_FILE="${DOCKER_CODE_AGENT_ENV:-/etc/docker-code/agent.env}"

# The escape hatches come first, before anything that can fail. `claude-docker bash` is how you look
# around inside the container when something is wrong, and that has to work even when the agent
# metadata this script otherwise depends on is missing or malformed — which is exactly the situation
# you would be looking around to diagnose.
if [ "${DOCKER_CODE_SHELL:-0}" = "1" ]; then
    exec "${SHELL:-/bin/bash}" "$@"
fi

case "${1:-}" in
    bash|sh|shell)
        shell="$1"
        if [ "${shell}" = "shell" ]; then
            shell="bash"
        fi
        shift
        exec "${shell}" "$@"
        ;;
esac

if [ ! -f "${AGENT_ENV_FILE}" ]; then
    echo "docker-code: ${AGENT_ENV_FILE} is missing; this image was built wrong" >&2
    exit 1
fi

# Read, not source: the same restricted key=value format lib/agents.sh parses on the host, so a
# malformed line is an error rather than something that executes.
#
# The awk pass joins a value continued with a trailing backslash, because the long lists are written
# across several lines and reading only the first one is not a smaller list, it is a wrong one: a
# skip list cut in half hands the tool a subcommand dressed up as a prompt.
agent_get() {
    awk -v key="$1" '
        pending != "" { sub(/^[[:space:]]+/, ""); $0 = pending " " $0; pending = "" }
        /\\[[:space:]]*$/ { sub(/[[:space:]]*\\[[:space:]]*$/, ""); pending = $0; next }
        index($0, key "=") == 1 {
            value = substr($0, length(key) + 2)
            sub(/^[[:space:]]+/, "", value)
            # The same three cases as agent_parse_file in lib/agents.sh, which the host runs over this
            # very file: a quoted value keeps everything between the quotes, a # included, while a bare
            # one ends at the first # and loses its trailing space. Stripping only the quotes — which
            # is what this did — left `AGENT_BIN=vibe  # the binary` as a command name with a comment
            # in it. The host had already accepted that line, so nothing on that side could catch it
            # and the failure surfaced at exec, inside the container.
            if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
                value = substr(value, 2, length(value) - 2)
            } else {
                sub(/#.*$/, "", value)
                sub(/[[:space:]]+$/, "", value)
            }
            print value
            exit
        }
    ' "${AGENT_ENV_FILE}" 2>/dev/null
}

AGENT_ID="$(agent_get AGENT_ID)"
AGENT_BIN="$(agent_get AGENT_BIN)"
AGENT_YOLO_ARGS="$(agent_get AGENT_YOLO_ARGS)"
AGENT_YOLO_SKIP="$(agent_get AGENT_YOLO_SKIP)"
AGENT_PERMISSION_FLAGS="$(agent_get AGENT_PERMISSION_FLAGS)"
AGENT_ROOT_ENV="$(agent_get AGENT_ROOT_ENV)"
AGENT_LOCAL_ARGS="$(agent_get AGENT_LOCAL_ARGS)"

[ -n "${AGENT_PERMISSION_FLAGS}" ] || AGENT_PERMISSION_FLAGS="${AGENT_YOLO_ARGS}"

if [ -z "${AGENT_BIN}" ]; then
    echo "docker-code: ${AGENT_ENV_FILE} does not name an AGENT_BIN" >&2
    exit 1
fi

# Subcommands that take their own options. `codex --dangerously-bypass-… mcp list` is not worth the
# risk of an argument parser rejecting a root-level flag in front of a subcommand, and bypassing
# permissions means nothing for a command that never runs a tool.
is_subcommand() {
    local candidate="${1:-}" word
    [ -n "${candidate}" ] || return 1
    for word in ${AGENT_YOLO_SKIP}; do
        [ "${word}" = "${candidate}" ] && return 0
    done
    return 1
}

# Respect a permission choice the user made explicitly. Injecting a bypass flag next to an
# --approval-mode the user typed themselves would silently override their decision.
has_permission_flag() {
    local arg flag
    for arg in "$@"; do
        for flag in ${AGENT_PERMISSION_FLAGS}; do
            case "${arg}" in
                "${flag}"|"${flag}"=*) return 0 ;;
            esac
        done
    done
    return 1
}

args=()

if [ "${DOCKER_CODE_YOLO:-0}" = "1" ] && [ -n "${AGENT_YOLO_ARGS}" ] \
    && ! is_subcommand "${1:-}" && ! has_permission_flag "$@"; then
    # Prepended, not appended: options belong in front of the prompt argument.
    # Unquoted on purpose — AGENT_YOLO_ARGS is a flag list, and copilot's is three flags.
    # shellcheck disable=SC2206
    args=(${AGENT_YOLO_ARGS})

    # Some CLIs refuse to bypass their checks as root and skip that refusal inside a recognized
    # sandbox. When the host user is root the entrypoint had to keep the container on root too, so
    # that a root-owned workspace stays writable — and this is the container the check is talking
    # about: no host Docker socket, no host home directory, no host filesystem beyond the directory
    # you started in. Declaring it is honest, and the alternative is a YOLO flag that does not work.
    if [ "$(id -u)" -eq 0 ] && [ -n "${AGENT_ROOT_ENV}" ]; then
        echo "docker-code[${AGENT_ID}]: running as root; declaring the container a sandbox so the bypass applies" >&2
        for assignment in ${AGENT_ROOT_ENV}; do
            export "${assignment?}"
        done
    fi
fi

# Local models: the wrapper set DOCKER_CODE_LOCAL_URL and the env from AGENT_LOCAL_ENV already, but
# some tools take the model on the command line rather than from the environment.
if [ -n "${DOCKER_CODE_LOCAL_URL:-}" ] && [ -n "${AGENT_LOCAL_ARGS}" ] \
    && [ -n "${DOCKER_CODE_LOCAL_MODEL:-}" ] && ! is_subcommand "${1:-}"; then
    local_args="${AGENT_LOCAL_ARGS//%m/${DOCKER_CODE_LOCAL_MODEL}}"
    # shellcheck disable=SC2206  # a flag list, deliberately word-split
    args+=(${local_args})
fi

args+=("$@")

# exec, so the agent becomes this process: exit code, signals and the TTY all stay untouched.
exec "${AGENT_BIN}" "${args[@]}"
