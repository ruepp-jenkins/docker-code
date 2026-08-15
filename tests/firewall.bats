#!/usr/bin/env bats
# image/init-firewall.sh, checked without installing any rules.
#
# The rules themselves need NET_ADMIN and a namespace to write into, so what is asserted here is the
# shape: that the allowlist is built before the policy flips, that the per-agent domains come from
# agent.env rather than from a list in the script, and that the script verifies itself instead of
# trusting that it worked. A firewall that silently failed open is worse than none, because the
# session proceeds believing it is contained.

load helper

FIREWALL="${BATS_TEST_DIRNAME}/../image/init-firewall.sh"

@test "the vendor domains come from agent.env, not from a list in the script" {
    grep -q 'agent_get AGENT_DOMAINS' "${FIREWALL}"

    # A tool name hard-coded here would mean the eighth agent needs an edit in this file.
    for id in $(all_agent_ids); do
        first_domain="$(agent_field "${id}" AGENT_DOMAINS)"
        first_domain="${first_domain%% *}"
        grep -q "${first_domain}" "${FIREWALL}" && {
            echo "init-firewall.sh hard-codes ${first_domain}, which belongs in agents/${id}/agent.env"
            return 1
        }
    done
    return 0
}

@test "the common domains are the package registries any agent reaches for" {
    block="$(sed -n '/^COMMON_DOMAINS=(/,/^)/p' "${FIREWALL}")"
    [ -n "${block}" ]
    eval "${block}"
    [ "${#COMMON_DOMAINS[@]}" -gt 0 ]

    for domain in registry.npmjs.org pypi.org; do
        printf '%s\n' "${COMMON_DOMAINS[@]}" | grep -qxF "${domain}" || {
            echo "${domain} is missing from COMMON_DOMAINS"; return 1
        }
    done
}

@test "the image registries are added only when there is an inner Docker" {
    block="$(sed -n '/^REGISTRY_DOMAINS=(/,/^)/p' "${FIREWALL}")"
    eval "${block}"
    printf '%s\n' "${REGISTRY_DOMAINS[@]}" | grep -qxF registry-1.docker.io
    grep -q 'case "${DOCKER_CODE_DIND:-0}" in' "${FIREWALL}"
}

@test "the allowlist is resolved before the policy becomes DROP" {
    # Once OUTPUT is DROP, DNS and the GitHub metadata fetch would be blocked by the very rules being
    # installed.
    resolve_line="$(grep -n 'resolve_into_set "${domain}"' "${FIREWALL}" | head -n 1 | cut -d: -f1)"
    drop_line="$(grep -n '^iptables -P OUTPUT DROP' "${FIREWALL}" | cut -d: -f1)"
    [ -n "${resolve_line}" ] && [ -n "${drop_line}" ]
    [ "${resolve_line}" -lt "${drop_line}" ]
}

@test "DNS stays open, because the allowlist is built from names" {
    grep -q 'iptables -A OUTPUT -p udp --dport 53 -j ACCEPT' "${FIREWALL}"
}

@test "the container's own networks stay reachable, which is what keeps local models working" {
    # Ollama and LiteLLM sit on a user-defined network, so they are covered by this rule rather than
    # needing a name in the allowlist.
    grep -q 'ip -o -f inet route show scope link' "${FIREWALL}"
}

@test "IPv6 is dropped, since the allowlist is IPv4-only" {
    grep -q 'ip6tables -P OUTPUT DROP' "${FIREWALL}"
}

@test "existing chains are appended to, not flushed" {
    # A privileged inner dockerd has already written its NAT and forwarding rules by the time this
    # runs, and wiping them breaks every nested container's networking.
    [ "$(grep -c '^iptables -F ' "${FIREWALL}")" -eq 0 ]
    grep -q 'iptables -F DOCKER-USER' "${FIREWALL}"
}

@test "the script proves egress is actually restricted before returning" {
    grep -q 'https://example.com' "${FIREWALL}"
    grep -q 'egress is NOT restricted' "${FIREWALL}"
}

@test "the positive control is the agent's own first domain" {
    grep -q 'probe="${AGENT_DOMAINS%% \*}"' "${FIREWALL}" ||
        grep -q 'probe="${AGENT_DOMAINS%% ' "${FIREWALL}"
    grep -q 'cannot work' "${FIREWALL}"
}

@test "an unresolvable domain degrades that one service, not the whole firewall" {
    grep -q 'WARNING: could not resolve' "${FIREWALL}"
}

@test "extra domains can be added without editing the image" {
    grep -q 'DOCKER_CODE_ALLOW_DOMAINS' "${FIREWALL}"
    # The launcher has to know the knob, or the hook is unreachable. That it actually reaches the
    # container is asserted behaviourally in wrapper.bats, through the dry-run seam — a grep here
    # would only prove the string exists, and the launcher composes these names rather than
    # spelling them out.
    grep -q 'ALLOW_DOMAINS' "${REPO_ROOT}/bin/docker-code"
}
