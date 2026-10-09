# shellcheck shell=bash
# A remote session as a compose.yml, for `docker compose up -d` instead of `<agent>-docker-remote`.
#
# Translated from the very `docker run` argv the launcher builds rather than written from a template
# of its own: every setting that shapes a session — DIND, NET, LOCAL, MOUNT, the passthrough list —
# then reaches the compose file through the code that already gets it right, and a new one cannot
# be forgotten here without the translation below refusing the flag it does not know.
#
# The session name is not filled in yet. The file comes out with two placeholders, so that the same
# output serves `docker-code compose`, which substitutes the name at once, and the template a session
# leaves in its home for the /remote skill, which substitutes the name the user gives inside the
# container. image/compose.sh carries the container's copy of compose_slug and compose_fill; a test
# keeps the two in step.

COMPOSE_NAME_PLACEHOLDER="__DOCKER_CODE_NAME__"
COMPOSE_SLUG_PLACEHOLDER="__DOCKER_CODE_SLUG__"

# NET=gateway, as part of the same file. The launcher's gateway is a container it configures, starts
# and removes around the session; in a compose project it becomes a second service with the same
# squid config, on the same two-network topology: the session sits on an internal network whose only
# other member is the gateway, and only the gateway has a network with a route out. Both restart
# together, which the launcher's gateway — removed with the last session — never could.
#
# Set by session_egress in compose mode; empty means no gateway. The session's argv names the
# internal network by COMPOSE_EGRESS_INTERNAL, which is how the renderer tells it from the external
# networks of the shared services.
COMPOSE_EGRESS_SERVICE="egress"
COMPOSE_EGRESS_INTERNAL="egress-internal"
COMPOSE_EGRESS_OUT="egress-out"
COMPOSE_EGRESS_CONF=""
COMPOSE_EGRESS_IMAGE=""
compose_egress_networks=()

# compose_slug <name>
#
# The session name as it can appear in a container name, a volume name and a compose project name at
# once. The project name is the strictest of the three — lowercase letters, digits, - and _, starting
# with a letter or digit — so that is the rule for all of them, and one name per session stays one
# name everywhere it is shown.
compose_slug() {
    local slug
    slug="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9_-' '-' | tr -s '-')"
    slug="$(printf '%s' "${slug}" | sed -e 's/^[-_]*//' -e 's/[-_]*$//')"
    printf '%s\n' "${slug:-session}"
}

# compose_quote <value>
#
# A YAML double-quoted scalar that compose reads back unchanged: backslash and quote escaped for
# YAML, and $ doubled because compose interpolates ${VAR} in every value — a path or name containing
# a dollar sign would otherwise be rewritten from the shell of whoever runs `docker compose up`.
compose_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\$\$}"
    printf '"%s"' "${value}"
}

# compose_fill <name>  (stdin: the rendered file, stdout: the file for that session)
compose_fill() {
    local name="$1" slug content quoted
    slug="$(compose_slug "${name}")"
    # Quoted for YAML the same way compose_quote does it, minus the surrounding quotes: the
    # placeholder always sits inside a quoted scalar already.
    quoted="$(compose_quote "${name}")"
    quoted="${quoted#\"}"
    quoted="${quoted%\"}"
    content="$(cat)"
    # The replacement is quoted, because bash 5.2 otherwise reads an & in it as "the matched text".
    content="${content//"${COMPOSE_NAME_PLACEHOLDER}"/"${quoted}"}"
    content="${content//"${COMPOSE_SLUG_PLACEHOLDER}"/"${slug}"}"
    printf '%s\n' "${content}"
}

# compose_render <service> <docker run args...>
#
# The argv after `docker run`. Prints the compose file, or names the flag it cannot translate and
# fails — a compose file that silently lacks a mount someone set up is the one outcome worse than
# none.
compose_render() {
    local service="$1"
    shift

    local image="" container_name="" hostname="" working_dir="" restart="" pull_policy=""
    local init=0 tty=0 stdin_open=0 privileged=0 network_none=0
    # Plain globals, for the same bash-3.2 reason as the arrays in bin/docker-code.
    c_labels=() c_volumes=() c_env=() c_devices=() c_security=() c_caps=() c_networks=()
    c_named_volumes=() c_command=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --rm|--detach) ;;
            --init) init=1 ;;
            --tty) tty=1 ;;
            --interactive) stdin_open=1 ;;
            --privileged) privileged=1 ;;
            --name) container_name="$2"; shift ;;
            --hostname) hostname="$2"; shift ;;
            --workdir) working_dir="$2"; shift ;;
            --restart) restart="$2"; shift ;;
            --pull) pull_policy="$2"; shift ;;
            --label) c_labels+=("$2"); shift ;;
            --env)
                # A variable passed through by name only must not undo one the launcher set with a
                # value: under NET=gateway that is HTTP_PROXY, and the shell's own proxy in its place
                # would point the session somewhere its internal network cannot reach.
                case "$2" in
                    *=*) c_env+=("$2") ;;
                    *) compose_env_has "$2" ${c_env[@]+"${c_env[@]}"} || c_env+=("$2") ;;
                esac
                shift
                ;;
            --device) c_devices+=("$2"); shift ;;
            --security-opt) c_security+=("$2"); shift ;;
            --cap-add) c_caps+=("$2"); shift ;;
            --network)
                if [ "$2" = "none" ]; then
                    network_none=1
                else
                    c_networks+=("$2")
                fi
                shift
                ;;
            --volume)
                c_volumes+=("$2")
                # A source that is not a path is a named volume, and compose only accepts one it has
                # been told about at the top level.
                case "$2" in
                    /*) ;;
                    *) c_named_volumes+=("${2%%:*}") ;;
                esac
                shift
                ;;
            -*)
                echo "compose: '$1' has no translation here; leave it out of DOCKER_CODE_RUN_ARGS" \
                     "and add it to compose.yml by hand" >&2
                return 1
                ;;
            *)
                image="$1"
                shift
                c_command=("$@")
                break
                ;;
        esac
        shift
    done

    [ -n "${image}" ] || { echo "compose: no image in the docker run arguments" >&2; return 1; }

    local item egress=0
    [ -z "${COMPOSE_EGRESS_CONF}" ] || egress=1

    printf 'name: %s\n' "$(compose_quote "${COMPOSE_SLUG_PLACEHOLDER}")"
    printf '\nservices:\n'
    printf '  %s:\n' "${service}"
    printf '    image: %s\n' "$(compose_quote "${image}")"
    [ -z "${container_name}" ] || printf '    container_name: %s\n' "$(compose_quote "${container_name}")"
    [ -z "${hostname}" ] || printf '    hostname: %s\n' "$(compose_quote "${hostname}")"
    [ -z "${restart}" ] || printf '    restart: %s\n' "$(compose_quote "${restart}")"
    [ -z "${pull_policy}" ] || printf '    pull_policy: %s\n' "$(compose_quote "${pull_policy}")"
    [ "${init}" = "0" ] || printf '    init: true\n'
    [ "${tty}" = "0" ] || printf '    tty: true\n'
    [ "${stdin_open}" = "0" ] || printf '    stdin_open: true\n'
    [ "${privileged}" = "0" ] || printf '    privileged: true\n'
    [ -z "${working_dir}" ] || printf '    working_dir: %s\n' "$(compose_quote "${working_dir}")"
    [ "${network_none}" = "0" ] || printf '    network_mode: "none"\n'

    compose_list labels ${c_labels[@]+"${c_labels[@]}"}
    compose_list volumes ${c_volumes[@]+"${c_volumes[@]}"}
    compose_list environment ${c_env[@]+"${c_env[@]}"}
    compose_list devices ${c_devices[@]+"${c_devices[@]}"}
    compose_list security_opt ${c_security[@]+"${c_security[@]}"}
    compose_list cap_add ${c_caps[@]+"${c_caps[@]}"}
    compose_list networks ${c_networks[@]+"${c_networks[@]}"}
    compose_list command ${c_command[@]+"${c_command[@]}"}

    if [ "${egress}" = "1" ]; then
        # Started and answering before the session, as egress_wait_ready makes sure of for the
        # launcher: a session that talks to squid before it binds gets a refusal that looks like a
        # broken allowlist.
        printf '    depends_on:\n      %s:\n        condition: service_healthy\n' \
            "${COMPOSE_EGRESS_SERVICE}"

        printf '\n  %s:\n' "${COMPOSE_EGRESS_SERVICE}"
        printf '    image: %s\n' "$(compose_quote "${COMPOSE_EGRESS_IMAGE}")"
        [ -z "${container_name}" ] ||
            printf '    container_name: %s\n' "$(compose_quote "${container_name}-egress")"
        [ -z "${restart}" ] || printf '    restart: %s\n' "$(compose_quote "${restart}")"
        printf '    configs:\n      - source: squid\n        target: "/etc/squid/squid.conf"\n'
        compose_list networks "${COMPOSE_EGRESS_INTERNAL}" "${COMPOSE_EGRESS_OUT}" \
            ${compose_egress_networks[@]+"${compose_egress_networks[@]}"}
        printf '    healthcheck:\n'
        printf '      test: ["CMD-SHELL", "grep -q %s /var/log/squid/cache.log"]\n' \
            "'Accepting HTTP Socket connections'"
        printf '      interval: 2s\n      timeout: 2s\n      retries: 15\n'
    fi

    # Named after themselves rather than prefixed with the project, which is what compose would do
    # otherwise: the inner Docker store must be the one `<agent>-docker-remote` uses for this session,
    # and the networks are the ones docker-code's shared services already run on.
    if [ "${#c_named_volumes[@]}" -gt 0 ]; then
        printf '\nvolumes:\n'
        for item in "${c_named_volumes[@]}"; do
            printf '  %s:\n    name: %s\n' "${item}" "$(compose_quote "${item}")"
        done
    fi
    if [ "${#c_networks[@]}" -gt 0 ] || [ "${egress}" = "1" ]; then
        printf '\nnetworks:\n'
        # The project's own: no name, so compose prefixes them with the project and two sessions'
        # gateways never share a network.
        if [ "${egress}" = "1" ]; then
            printf '  %s:\n    internal: true\n' "${COMPOSE_EGRESS_INTERNAL}"
            printf '  %s: {}\n' "${COMPOSE_EGRESS_OUT}"
        fi
        compose_seen_networks=""
        for item in ${c_networks[@]+"${c_networks[@]}"} \
            ${compose_egress_networks[@]+"${compose_egress_networks[@]}"}; do
            [ "${item}" != "${COMPOSE_EGRESS_INTERNAL}" ] || continue
            # Listed once, though both the session and the gateway may name it.
            case " ${compose_seen_networks} " in *" ${item} "*) continue ;; esac
            compose_seen_networks="${compose_seen_networks} ${item}"
            printf '  %s:\n    name: %s\n    external: true\n' "${item}" "$(compose_quote "${item}")"
        done
    fi

    if [ "${egress}" = "1" ]; then
        # Inline rather than a file next to it, so the policy is read where the session is defined,
        # and the compose file stays the one thing to copy. $ doubled: compose interpolates here too.
        printf '\nconfigs:\n  squid:\n    content: |\n'
        printf '%s\n' "${COMPOSE_EGRESS_CONF}" | sed -e 's/\$/$$/g' -e 's/^/      /' -e 's/^ *$//'
    fi
}

compose_env_has() {
    local name="$1" entry
    shift
    for entry in "$@"; do
        case "${entry}" in "${name}"|"${name}="*) return 0 ;; esac
    done
    return 1
}

compose_list() {
    local key="$1" item
    shift
    [ "$#" -gt 0 ] || return 0
    printf '    %s:\n' "${key}"
    for item in "$@"; do
        printf '      - %s\n' "$(compose_quote "${item}")"
    done
}
