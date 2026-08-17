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

@test "both Docker Hub blob CDNs are allowed, not just one" {
    # Hub answers a layer request with a 307 to Cloudflare or to CloudFront, and which one it picks is
    # not ours to decide. Listing a single CDN produced a pull that authenticated, read its manifest,
    # and then timed out on the first layer — far enough in to look like the restriction being too
    # strict in general rather than one missing name.
    block="$(sed -n '/^REGISTRY_DOMAINS=(/,/^)/p' "${FIREWALL}")"
    eval "${block}"

    for domain in production.cloudflare.docker.com production.cloudfront.docker.com; do
        printf '%s\n' "${REGISTRY_DOMAINS[@]}" | grep -qxF "${domain}" || {
            echo "${domain} is missing from REGISTRY_DOMAINS"; return 1
        }
    done
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

@test "a domain list continued across lines is read whole" {
    # Most agents write AGENT_DOMAINS across several lines. A parser that stopped at the backslash
    # would build the allowlist from part of a vendor's hosts and leave the rest to fail one by one,
    # somewhere in the middle of a session that looks like it started fine.
    env_file="${BATS_TEST_TMPDIR}/agent.env"
    cat >"${env_file}" <<'EOF'
AGENT_ID=fake
AGENT_DOMAINS="first.example second.example \
third.example"
EOF
    eval "$(sed -n '/^agent_get()/,/^}/p' "${FIREWALL}")"
    AGENT_ENV_FILE="${env_file}"
    [ "$(agent_get AGENT_DOMAINS)" = "first.example second.example third.example" ]
}

@test "an unresolvable domain degrades that one service, not the whole firewall" {
    grep -q 'WARNING: could not resolve' "${FIREWALL}"
}

@test "resolution has a second resolver behind the first" {
    # A real report had every dig time out while curl kept working. With only dig in the picture that
    # session ends with an empty allowlist and a container that cannot reach anything.
    grep -q 'dig +short' "${FIREWALL}"
    grep -q 'getent ahostsv4' "${FIREWALL}"
}

@test "an empty allowlist stops before the policy is touched, not after" {
    # Installing default-deny around an allowlist that holds none of the agent's own hosts produces
    # a session that dies several confusing steps later. The check has to come first.
    check_line="$(grep -n 'refusing to install a default-deny firewall' "${FIREWALL}" | cut -d: -f1)"
    drop_line="$(grep -n '^iptables -P OUTPUT DROP' "${FIREWALL}" | cut -d: -f1)"
    [ -n "${check_line}" ] && [ -n "${drop_line}" ]
    [ "${check_line}" -lt "${drop_line}" ]
}

@test "the failure messages say what to do, not only what broke" {
    # Both are met by a user whose session refuses to start; a bare diagnosis leaves them stuck.
    grep -q 'DOCKER_CODE_NET=full' "${FIREWALL}"
    grep -q 'DOCKER_CODE_ALLOW_DOMAINS' "${FIREWALL}"
}

@test "extra domains can be added without editing the image" {
    grep -q 'DOCKER_CODE_ALLOW_DOMAINS' "${FIREWALL}"
    # The launcher has to know the knob, or the hook is unreachable. That it actually reaches the
    # container is asserted behaviourally in wrapper.bats, through the dry-run seam — a grep here
    # would only prove the string exists, and the launcher composes these names rather than
    # spelling them out.
    grep -q 'ALLOW_DOMAINS' "${REPO_ROOT}/bin/docker-code"
}
