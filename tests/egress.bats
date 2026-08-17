#!/usr/bin/env bats
# lib/egress.sh and the NET=gateway session, checked without a Docker daemon.
#
# What matters here is not that a proxy runs — that needs a daemon and belongs to a manual pass — but
# that the generated allowlist is a *deny-by-default* one, that the session is given no way around it,
# and that the two failure modes which would silently unfilter a session cannot come back:
#
#   - inheriting squid's stock `include /etc/squid/conf.d/*.conf`, which ships
#     `http_access allow localnet` and would allow every RFC1918 source, i.e. the session
#   - falling back to an unfiltered session when the gateway will not start
#
# Both are cheap to reintroduce and invisible once they are, which is why they are asserted directly.

load helper

setup() {
    setup_wrapper_env
    export DOCKER_CODE_ROOT="${REPO_ROOT}"
    export STORAGE_ROOT="${BATS_TEST_TMPDIR}/state"
    mkdir -p "${STORAGE_ROOT}"
}

# Generate a config through lib/egress.sh exactly as the launcher does, and print its path.
write_config() {
    local id="$1"
    shift
    run bash -c "
        STORAGE_ROOT='${STORAGE_ROOT}'
        warn() { :; }
        die() { echo \"\$*\" >&2; exit 1; }
        . '${REPO_ROOT}/lib/egress.sh'
        egress_write_config '${id}' $*
    "
    [ "${status}" -eq 0 ] || {
        echo "egress_write_config failed: ${output}"
        return 1
    }
    CONFIG="${output}"
}

dry() {
    local wrapper="$1"
    shift
    run "${REPO_ROOT}/bin/${wrapper}" "$@"
    [ "${status}" -eq 0 ] || {
        echo "wrapper exited ${status}: ${output}"
        return 1
    }
}

# ---------------------------------------------------------------------------------------------
# The allowlist
# ---------------------------------------------------------------------------------------------

@test "the config never includes squid's conf.d, which would allow every private source" {
    # ubuntu/squid ships /etc/squid/conf.d/debian.conf containing `http_access allow localnet`.
    # squid is first-match-wins and a session sits on a 172.16/12 address, so inheriting that include
    # allows everything and leaves the rest of this file decorative.
    write_config codex api.openai.com
    ! grep -q 'conf.d' "${CONFIG}" || {
        echo "the generated config pulls in conf.d, which allows localnet:"
        grep -n 'conf.d' "${CONFIG}"
        return 1
    }
    ! grep -q 'allow localnet' "${CONFIG}"
}

@test "the allowlist denies by default, and the deny is last" {
    write_config codex api.openai.com
    grep -q '^http_access deny all$' "${CONFIG}"

    # Anything after the catch-all deny is unreachable, and an allow placed there reads as effective
    # while doing nothing — or worse, a future edit moves it up.
    local last
    last="$(grep -c '^http_access' "${CONFIG}")"
    [ "$(grep -n '^http_access' "${CONFIG}" | tail -n 1 | cut -d: -f2- )" = "http_access deny all" ] || {
        echo "the last http_access rule is not the catch-all deny (${last} rules):"
        grep -n '^http_access' "${CONFIG}"
        return 1
    }
}

@test "a domain becomes a dstdomain rule, so filtering is by name and not by address" {
    write_config codex api.openai.com auth.openai.com
    grep -qE '^acl allowed_domains dstdomain .*api\.openai\.com' "${CONFIG}"
    grep -qE '^acl allowed_domains dstdomain .*auth\.openai\.com' "${CONFIG}"
}

@test "a leading dot is passed through, because that is squid's wildcard" {
    write_config codex .openai.com
    grep -qE '^acl allowed_domains dstdomain .*\s\.openai\.com|^acl allowed_domains dstdomain \.openai\.com' "${CONFIG}"
}

@test "an address or CIDR becomes a dst rule rather than a dstdomain squid would reject" {
    # DOCKER_CODE_ALLOW_DOMAINS has always taken both, and one address in the dstdomain list makes
    # squid refuse the whole config — so the session would fail to start, not merely mis-filter.
    write_config codex api.openai.com 10.0.0.0/8 192.168.1.5
    grep -qE '^acl allowed_addresses dst .*10\.0\.0\.0/8' "${CONFIG}"
    grep -qE '^acl allowed_addresses dst .*192\.168\.1\.5' "${CONFIG}"
    ! grep -E '^acl allowed_domains dstdomain' "${CONFIG}" | grep -q '10\.0\.0\.0/8'
}

@test "the shared services' ports are allowed through CONNECT" {
    # squid refuses CONNECT outside 443/563 by default. Ollama on 11434, LiteLLM on 4000 and the
    # registry mirror on 5000 all speak plain HTTP, and without this a session with local models
    # fails in a way that looks nothing like a port rule.
    write_config codex api.openai.com
    grep -qE '^acl service_ports port .*11434' "${CONFIG}"
    grep -qE '^acl service_ports port .*4000' "${CONFIG}"
    grep -qE '^acl service_ports port .*5000' "${CONFIG}"
}

@test "both Docker Hub CDNs are covered by one wildcard, not enumerated" {
    # The bug this mode exists for: a Hub pull follows a 307 to Cloudflare or CloudFront, and naming
    # one host and not the other timed out halfway through a pull. `.docker.com` covers both, and the
    # next CDN Hub adds, without an edit.
    run bash -c ". '${REPO_ROOT}/lib/egress.sh'; printf '%s\n' \"\${EGRESS_REGISTRY_DOMAINS[@]}\""
    [ "${status}" -eq 0 ]
    printf '%s\n' "${output}" | grep -qxF '.docker.com'
    printf '%s\n' "${output}" | grep -qxF '.docker.io'

    # And no CDN hostname anywhere, which would mean the wildcard is not being relied on.
    ! printf '%s\n' "${output}" | grep -q 'cloudfront\|cloudflare'
}

@test "the common domains match the in-container firewall's list" {
    # Two mechanisms, one promise. A package registry reachable under NET=restricted but not under
    # NET=gateway is a difference nobody would predict from the names of the modes.
    block="$(sed -n '/^COMMON_DOMAINS=(/,/^)/p' "${REPO_ROOT}/image/init-firewall.sh")"
    eval "${block}"
    run bash -c ". '${REPO_ROOT}/lib/egress.sh'; printf '%s\n' \"\${EGRESS_COMMON_DOMAINS[@]}\""
    [ "${status}" -eq 0 ]

    for domain in "${COMMON_DOMAINS[@]}"; do
        printf '%s\n' "${output}" | grep -qxF "${domain}" || {
            echo "${domain} is in init-firewall.sh's COMMON_DOMAINS but not EGRESS_COMMON_DOMAINS"
            return 1
        }
    done
}

@test "a host a wildcard already covers is pruned, because squid calls that fatal" {
    # Not a tidiness rule. squid refuses the whole config:
    #   ERROR: 'raw.githubusercontent.com' is a subdomain of '.githubusercontent.com'
    #   FATAL: Bungled squid.conf line 9: acl allowed_domains dstdomain ...
    # and the gateway never starts. This exact pair is the default — raw.githubusercontent.com is a
    # common domain, .githubusercontent.com arrives with DOCKER_CODE_ALLOW_GITHUB=1 — so without the
    # pruning every gateway session fails to launch.
    write_config codex raw.githubusercontent.com .githubusercontent.com
    grep -q '\.githubusercontent\.com' "${CONFIG}"
    ! grep -qE 'dstdomain.*[[:space:]]raw\.githubusercontent\.com' "${CONFIG}" || {
        echo "the covered host survived, which squid rejects:"
        grep -n 'dstdomain' "${CONFIG}"
        return 1
    }
}

@test "the broader entry is the one kept, so pruning never narrows the allowlist" {
    # Dropping the wildcard instead would silently reduce what the session may reach, which is the
    # failure that would not show up until something stopped working.
    run bash -c "
        . '${REPO_ROOT}/lib/egress.sh'
        egress_prune_domains api.openai.com .openai.com sub.api.openai.com
    "
    [ "${status}" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | grep -c .)" = "1" ]
    [ "${output}" = ".openai.com" ]
}

@test "an exact duplicate is dropped, wherever the two copies came from" {
    # agent.env and DOCKER_CODE_ALLOW_DOMAINS naming the same host is ordinary, and squid warns about
    # the repetition.
    run bash -c "
        . '${REPO_ROOT}/lib/egress.sh'
        egress_prune_domains api.openai.com pypi.org api.openai.com
    "
    [ "${status}" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | grep -c '^api\.openai\.com$')" = "1" ]
}

@test "unrelated domains that merely share a suffix are both kept" {
    # The pruning must key on a dot boundary. `.docker.io` does not cover `.docker.com`, and
    # `notopenai.com` is not covered by `.openai.com`.
    run bash -c "
        . '${REPO_ROOT}/lib/egress.sh'
        egress_prune_domains .docker.io .docker.com notopenai.com .openai.com
    "
    [ "${status}" -eq 0 ]
    for domain in .docker.io .docker.com notopenai.com .openai.com; do
        printf '%s\n' "${output}" | grep -qxF "${domain}" || {
            echo "${domain} was pruned but nothing covers it"; return 1
        }
    done
}

@test "the default allowlist for every agent is one squid will actually accept" {
    # The generated config is only useful if squid parses it, and the pairing above proves a plausible
    # list can be fatal. Assert the shape squid checks — no entry left that another entry covers —
    # for every agent's real domains plus every built-in list.
    for id in $(all_agent_ids); do
        domains="$(agent_field "${id}" AGENT_DOMAINS)"
        run bash -c "
            . '${REPO_ROOT}/lib/egress.sh'
            egress_prune_domains ${domains} \
                \"\${EGRESS_COMMON_DOMAINS[@]}\" \
                \"\${EGRESS_REGISTRY_DOMAINS[@]}\" \
                \"\${EGRESS_GITHUB_DOMAINS[@]}\"
        "
        [ "${status}" -eq 0 ]

        # No survivor may be covered by another survivor: that is exactly what squid rejects.
        while IFS= read -r entry; do
            [ -n "${entry}" ] || continue
            run bash -c "
                . '${REPO_ROOT}/lib/egress.sh'
                egress_domain_covered '${entry}' '$(printf '%s\n' "${output}")' && echo COVERED
            "
            [[ "${output}" != *COVERED* ]] || {
                echo "agent ${id}: ${entry} is still covered by another entry; squid would refuse"
                return 1
            }
        done <<EOF
${output}
EOF
    done
}

@test "the allowlist is rewritten on every start, not preserved like a preference" {
    # Unlike the LiteLLM config in lib/models.sh, this file *is* the policy. A stale copy is a wrong
    # policy: an agent whose domains changed, or an ALLOW_DOMAINS dropped from the environment, has to
    # take effect immediately.
    write_config codex api.openai.com
    grep -q 'api.openai.com' "${CONFIG}"

    write_config codex api.anthropic.com
    ! grep -q 'api.openai.com' "${CONFIG}"
    grep -q 'api.anthropic.com' "${CONFIG}"
}

# ---------------------------------------------------------------------------------------------
# The session
# ---------------------------------------------------------------------------------------------

@test "NET=gateway asks for no capabilities at all" {
    # The point of the mode: enforcement lives outside the container, so the session has nothing to
    # flush. NET_ADMIN here would hand it back the ability to undo its own containment.
    export DOCKER_CODE_NET=gateway
    dry codex-docker
    [[ "${output}" != *"--cap-add"* ]] || {
        echo "gateway mode granted a capability: ${output}"
        return 1
    }
}

@test "NET=restricted still gets the capabilities its firewall needs" {
    # The no-regression half of the pair above: the existing mode is untouched.
    export DOCKER_CODE_NET=restricted
    dry codex-docker
    [[ "${output}" == *"--cap-add NET_ADMIN"* ]]
    [[ "${output}" == *"--cap-add NET_RAW"* ]]
}

@test "NET=gateway attaches the session to its own gateway network and no other" {
    export DOCKER_CODE_NET=gateway
    dry codex-docker
    [[ "${output}" == *"--network docker-code-egress-codex"* ]]

    # One --network only. A second one with a route off the host would be a way around the proxy.
    [ "$(printf '%s\n' "${output}" | grep -o '\-\-network' | wc -l | tr -d ' ')" = "1" ]
}

@test "NET=gateway points the session's tools at the proxy" {
    export DOCKER_CODE_NET=gateway
    dry codex-docker
    for var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
        [[ "${output}" == *"${var}=http://docker-code-egress-codex:3128"* ]] || {
            echo "${var} is not set for the session"; return 1
        }
    done
    # Loopback only: the local-model bridge listens there and tunnels onward itself, while the
    # service names must go through the proxy. The dry run quotes with printf %q, which escapes the
    # comma, so match the parts rather than the literal value.
    [[ "${output}" == *"NO_PROXY=localhost"* ]]
    [[ "${output}" == *"127.0.0.1"* ]]
    [[ "${output}" != *"NO_PROXY=localhost"*"docker-code-ollama"* ]]
}

@test "the gateway is per agent, so one agent's domains are not another's" {
    export DOCKER_CODE_NET=gateway
    dry codex-docker
    [[ "${output}" == *"docker-code-egress-codex"* ]]
    dry claude-docker
    [[ "${output}" == *"docker-code-egress-claude"* ]]
    [[ "${output}" != *"docker-code-egress-codex"* ]]
}

@test "local models in gateway mode do not attach the session to the model network" {
    # That network has a route off the host. The gateway joins it instead and the loopback bridge
    # tunnels through the proxy, which is why the bridge spec is still handed over.
    export DOCKER_CODE_NET=gateway DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3-coder:7b
    dry qwen-docker
    [[ "${output}" != *"--network docker-code-net"* ]] || {
        echo "the session joined the model network, which routes around the gateway"
        return 1
    }
    [[ "${output}" == *"DOCKER_CODE_LOCAL_BRIDGE=11434:docker-code-ollama:11434"* ]]
    [[ "${output}" == *"--network docker-code-egress-qwen"* ]]
}

@test "the inner daemon is told about the proxy, since a pull reads it from the environment" {
    export DOCKER_CODE_NET=gateway
    dry codex-docker
    [[ "${output}" == *"DOCKER_CODE_PROXY=http://docker-code-egress-codex:3128"* ]]
    grep -q 'DOCKER_CODE_PROXY' "${REPO_ROOT}/image/entrypoint.sh"
    grep -q 'DOCKER_CODE_PROXY' "${REPO_ROOT}/image/user-init.sh"
}

@test "a gateway that will not start ends the session instead of unfiltering it" {
    # The one shared service in docker-code that must not degrade to a warning. A missing model
    # gateway costs local models; a missing egress gateway would leave a session that asked to be
    # filtered running wide open.
    block="$(sed -n '/^session_egress()/,/^}/p' "${REPO_ROOT}/bin/docker-code")"
    [ -n "${block}" ]
    [[ "${block}" == *"egress_start"* ]]
    [[ "${block}" == *"die"* ]] || {
        echo "session_egress does not die when the gateway fails to start"
        return 1
    }
    [[ "${block}" != *"warn \"could not start"* ]]
}

@test "the session-facing network is internal, which is what removes the route out" {
    grep -q 'docker network create --internal' "${REPO_ROOT}/lib/egress.sh"

    # And the gateway's own way out is a separate, deliberately non-internal network, so an
    # --internal added to the wrong one cannot pass unnoticed.
    block="$(sed -n '/^egress_ensure_out_network()/,/^}/p' "${REPO_ROOT}/lib/egress.sh")"
    [ -n "${block}" ]
    [[ "${block}" != *"--internal"* ]]
}

@test "git over SSH is called out rather than left to fail mysteriously" {
    # A CONNECT proxy does not carry SSH. It fails closed, which is right, but silently.
    export DOCKER_CODE_NET=gateway DOCKER_CODE_SSH=1
    export SSH_AUTH_SOCK="${BATS_TEST_TMPDIR}/agent.sock"
    : >"${SSH_AUTH_SOCK}"
    run "${REPO_ROOT}/bin/codex-docker"
    [[ "${output}" == *"SSH"* ]]
    [[ "${output}" == *"docs/EGRESS.md"* ]]
}

# ---------------------------------------------------------------------------------------------
# Shared services
# ---------------------------------------------------------------------------------------------

@test "a service egress setting takes 1, 0 or a URL, and refuses anything else" {
    run bash -c "
        warn() { :; }
        die() { echo \"\$*\" >&2; exit 1; }
        . '${REPO_ROOT}/lib/egress.sh'
        egress_service_proxy sideways
    "
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"1, 0, or the URL"* ]]
}

@test "a service egress of 0 means no proxy, and a URL is used as given" {
    run bash -c "
        warn() { :; }
        die() { exit 1; }
        . '${REPO_ROOT}/lib/egress.sh'
        printf '[%s]\n' \"\$(egress_service_proxy 0)\"
        printf '[%s]\n' \"\$(egress_service_proxy http://proxy.example:3128)\"
    "
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[]"* ]]
    [[ "${output}" == *"[http://proxy.example:3128]"* ]]
}

@test "LiteLLM is never handed a proxy, which would break its only call" {
    # It reaches Ollama by container name and NO_PROXY covers loopback only, so a proxy would route
    # that call through a gateway with no reason to allow it.
    block="$(sed -n '/^models_start_litellm()/,/^}/p' "${REPO_ROOT}/lib/models.sh")"
    [ -n "${block}" ]
    [[ "${block}" != *"egress_proxy_env"* ]]
}

@test "the shared services are not silently claimed to be contained" {
    # They keep a network with a route out, because non-gateway sessions attach to it for their own
    # egress, so pointing them at a proxy is advisory. The docs must not read as containment.
    grep -qi 'advisory' "${REPO_ROOT}/docs/EGRESS.md"
}
