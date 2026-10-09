#!/bin/bash
# docker-code-compose [--force] [--stdout] [name]
#
# Writes compose.yml into the current directory: this agent, in this workspace, with this session's
# settings, kept running in the background with remote control on. It is what the /remote skill runs.
#
# The file cannot be built in here — the host paths, the image and the inner Docker store are things
# only the launcher on the host knows. So the launcher renders it at every session start, with the
# session name left open, and points DOCKER_CODE_COMPOSE_TEMPLATE at the result (bin/docker-code,
# session_compose_template). All this script adds is the name.
set -euo pipefail

say() { echo "docker-code-compose: $*" >&2; }
die() { say "$*"; exit 1; }

# The container's copy of compose_slug and compose_fill in lib/compose.sh, which the image does not
# contain. tests/lint.bats checks that the two still agree.
COMPOSE_NAME_PLACEHOLDER="__DOCKER_CODE_NAME__"
COMPOSE_SLUG_PLACEHOLDER="__DOCKER_CODE_SLUG__"

compose_slug() {
    local slug
    slug="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9_-' '-' | tr -s '-')"
    slug="$(printf '%s' "${slug}" | sed -e 's/^[-_]*//' -e 's/[-_]*$//')"
    printf '%s\n' "${slug:-session}"
}

compose_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\$\$}"
    printf '"%s"' "${value}"
}

compose_fill() {
    local name="$1" slug content quoted
    slug="$(compose_slug "${name}")"
    quoted="$(compose_quote "${name}")"
    quoted="${quoted#\"}"
    quoted="${quoted%\"}"
    content="$(cat)"
    content="${content//"${COMPOSE_NAME_PLACEHOLDER}"/"${quoted}"}"
    content="${content//"${COMPOSE_SLUG_PLACEHOLDER}"/"${slug}"}"
    printf '%s\n' "${content}"
}

force=0
to_stdout=0
name=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --force|-f) force=1 ;;
        --stdout) to_stdout=1 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1 (--force, --stdout, [name])" ;;
        *) [ -z "${name}" ] || die "one name only; quote it if it has spaces"
           name="$1" ;;
    esac
    shift
done

# The same default the host uses for <agent>-docker-remote, so the file and the command name a
# session for this directory alike, and the second one finds the first rather than starting twice.
[ -n "${name}" ] || name="$(basename "${PWD}")"

template="${DOCKER_CODE_COMPOSE_TEMPLATE:-}"
if [ -z "${template}" ]; then
    die "this session was started without a compose template. That is the case for an agent" \
        "without remote control and for a docker-code older than this image. On the host," \
        "\`docker-code compose <agent>\` writes the file directly."
fi
[ -s "${template}" ] ||
    die "${template} is missing: the launcher could not render it when this session started." \
        "On the host, \`docker-code compose <agent>\` shows why."

if [ "${to_stdout}" = "1" ]; then
    compose_fill "${name}" <"${template}"
    exit 0
fi

target="${PWD}/compose.yml"
for existing in compose.yaml docker-compose.yml docker-compose.yaml; do
    [ ! -e "${PWD}/${existing}" ] ||
        say "note: ${existing} exists as well; docker compose prefers compose.yaml over compose.yml"
done
if [ -e "${target}" ] && [ "${force}" != "1" ]; then
    die "${target} already exists; --force replaces it, --stdout prints the file instead"
fi

compose_fill "${name}" <"${template}" >"${target}"

slug="$(compose_slug "${name}")"
container="$(sed -n 's/^    container_name: "\(.*\)"$/\1/p' "${target}" | head -n 1)"
say "wrote ${target} for the session \"${name}\" (container ${container:-${slug}})"
say "on the host, in this directory:"
say "  docker compose up -d                 start it in the background"
say "  docker-code attach ${container:-<name>}"
say "  docker compose down                  stop and remove it"
