#!/bin/bash
# Default-deny egress with an allowlist, for DOCKER_CODE_NET=restricted.
#
# The point is not to protect the host — the container boundary does that. It is to bound what a
# session that runs without permission prompts can reach, so that a prompt injection or a hostile
# dependency has nowhere to send what it can read.
#
# Which vendor hosts to allow is the agent's business, not this script's: AGENT_DOMAINS in
# /etc/docker-code/agent.env is the per-tool list, and the first domain in it is also what the
# verification at the bottom probes. A tool added later gets a working restricted mode by naming its
# hosts, with no change here.
set -euo pipefail

IPSET_NAME="allowed-domains"
AGENT_ENV_FILE="${DOCKER_CODE_AGENT_ENV:-/etc/docker-code/agent.env}"

# Hosts every agent needs regardless of vendor: the package registries an agent reaches for when it
# launches an MCP server or installs a dependency in the workspace. Keep one domain per line — the
# test suite reads this list straight out of the file.
COMMON_DOMAINS=(
    registry.npmjs.org         # npx-launched MCP servers, plugin dependencies
    raw.githubusercontent.com  # release notes, raw config fetches
    pypi.org                   # pip, uvx-launched MCP servers
    files.pythonhosted.org     # the payloads behind pypi.org
)

# The registries the inner Docker daemon pulls from. Added only when there is an inner daemon at all,
# so a session without one keeps the smaller allowlist.
#
# Docker Hub is in here for the case where the pull-through cache is switched off. With the cache on,
# Hub pulls never leave the container's own network — the mirror runs on the host, outside these
# rules — which is also why `restricted` and an inner Docker work together at all.
REGISTRY_DOMAINS=(
    registry-1.docker.io             # Docker Hub, registry API
    auth.docker.io                   # Docker Hub, pull tokens
    production.cloudflare.docker.com # Docker Hub, blob storage
    mcr.microsoft.com                # Microsoft Container Registry
)

log() { echo "firewall: $*" >&2; }
die() { echo "firewall: ERROR: $*" >&2; exit 1; }

command -v ipset >/dev/null || die "ipset is not installed"
command -v iptables >/dev/null || die "iptables is not installed"
[ "$(id -u)" -eq 0 ] || die "must run as root (the container needs NET_ADMIN)"

# The awk pass joins a value continued with a trailing backslash. AGENT_DOMAINS is written across
# several lines for most agents, and taking only the first of them would build the allowlist from
# half a vendor's hosts — a restricted session that fails somewhere in the middle of a download.
agent_get() {
    awk -v key="$1" '
        pending != "" { sub(/^[[:space:]]+/, ""); $0 = pending " " $0; pending = "" }
        /\\[[:space:]]*$/ { sub(/[[:space:]]*\\[[:space:]]*$/, ""); pending = $0; next }
        index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
    ' "${AGENT_ENV_FILE}" 2>/dev/null | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

AGENT_ID="$(agent_get AGENT_ID)"
AGENT_DOMAINS="$(agent_get AGENT_DOMAINS)"

if [ -z "${AGENT_DOMAINS}" ]; then
    log "WARNING: ${AGENT_ENV_FILE} names no AGENT_DOMAINS; ${AGENT_ID:-this agent} will not reach"
    log "         its own API. Add them to agents/${AGENT_ID:-<id>}/agent.env."
fi

# ---------------------------------------------------------------------------------------------
# Resolve the allowlist first, while the network still works. Once the OUTPUT policy is DROP, DNS
# and the GitHub metadata fetch below would be blocked by the very rules we are installing.
# ---------------------------------------------------------------------------------------------
ipset create "${IPSET_NAME}" hash:net -exist
ipset flush "${IPSET_NAME}"

add_ip() {
    # A hash:net set rejects anything that is not an address or CIDR, and dig happily returns CNAME
    # targets, so filter rather than let a malformed answer abort the script.
    case "$1" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) ipset add "${IPSET_NAME}" "$1" -exist ;;
        *) return 1 ;;
    esac
}

# Two resolvers, not one.
#
# dig talks to the nameserver in resolv.conf itself; getent goes through glibc. They fail
# independently — a container whose every dig timed out while curl kept working is a real report,
# and with only dig in the picture that session ends with an empty allowlist and a dead firewall.
# Whichever answers first is good enough for an ipset.
resolve_into_set() {
    local domain="$1" ips ip count=0

    # grep for addresses rather than taking dig's output as-is: `dig +short` reports its own failures
    # on *stdout*, not stderr —
    #     ;; communications error to 10.0.0.1#53: timed out
    #     ;; no servers could be reached
    # — so a plain emptiness check sees "output" and never reaches the fallback below. Filtering also
    # drops the CNAME lines dig mixes in with the A records.
    ips="$(dig +short +time=3 +tries=2 A "${domain}" 2>/dev/null |
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
    if [ -z "${ips}" ]; then
        ips="$(getent ahostsv4 "${domain}" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    fi

    # shellcheck disable=SC2086  # one address per line is exactly what should be split here
    for ip in ${ips}; do
        if add_ip "${ip}"; then
            count=$((count + 1))
        fi
    done

    if [ "${count}" -eq 0 ]; then
        # Not fatal on its own. A single unresolvable domain should degrade that one service, not
        # leave the container with no firewall at all — but see the check after the loop below.
        log "WARNING: could not resolve ${domain}"
        return 1
    fi
    return 0
}

agent_resolved=0
# shellcheck disable=SC2086  # a space-separated list from agent.env is the documented format
for domain in ${AGENT_DOMAINS}; do
    if resolve_into_set "${domain}"; then
        agent_resolved=$((agent_resolved + 1))
    fi
done

# Not one of the agent's own hosts could be resolved. That is not "one service degraded", it is a
# broken resolver — and carrying on would install a default-deny policy around an allowlist that
# cannot contain the one API this agent needs. The session would come up unable to reach anything
# and die at the verification below, several confusing steps later.
#
# Stopping here instead leaves the container's network exactly as it was: no policy has been
# changed yet, and the message names the actual problem.
if [ -n "${AGENT_DOMAINS}" ] && [ "${agent_resolved}" -eq 0 ]; then
    log "not one of ${AGENT_ID:-this agent}'s domains could be resolved, so the allowlist would be"
    log "empty. This is a DNS failure inside the container, not a firewall decision — nothing has"
    log "been changed. Check with:"
    log "    DOCKER_CODE_SHELL=1 ${AGENT_ID:-<agent>}-docker -c 'cat /etc/resolv.conf; getent hosts ${AGENT_DOMAINS%% *}'"
    log "Start with DOCKER_CODE_NET=full to run without the allowlist."
    die "refusing to install a default-deny firewall with an empty allowlist"
fi

for domain in "${COMMON_DOMAINS[@]}"; do
    resolve_into_set "${domain}" || true
done

case "${DOCKER_CODE_DIND:-0}" in
    0|false|none)
        ;;
    *)
        log "inner Docker is on, so the image registries are allowed as well"
        for domain in "${REGISTRY_DOMAINS[@]}"; do
            resolve_into_set "${domain}" || true
        done
        ;;
esac

# Anything else this environment needs: internal registries, a proxy, a package mirror. Without this
# hook the restricted mode is unusable outside a plain internet-facing setup.
if [ -n "${DOCKER_CODE_ALLOW_DOMAINS:-}" ]; then
    # shellcheck disable=SC2086  # a comma/space separated list is the documented interface
    for domain in ${DOCKER_CODE_ALLOW_DOMAINS//,/ }; do
        log "allowing extra domain ${domain}"
        case "${domain}" in
            [0-9]*.[0-9]*.[0-9]*.[0-9]*) add_ip "${domain}" || true ;;
            *) resolve_into_set "${domain}" || true ;;
        esac
    done
fi

# GitHub publishes its ranges as CIDRs, which is why the set is hash:net. Cloning and `gh` are close
# enough to table stakes for a coding agent to be in the default list.
if [ "${DOCKER_CODE_ALLOW_GITHUB:-1}" = "1" ]; then
    meta="$(curl -fsSL --max-time 10 https://api.github.com/meta 2>/dev/null || true)"
    if [ -n "${meta}" ]; then
        # shellcheck disable=SC2046  # one CIDR per line, splitting is the point
        for cidr in $(echo "${meta}" | jq -r '(.web // [])[], (.api // [])[], (.git // [])[]' 2>/dev/null | grep -v ':' || true); do
            ipset add "${IPSET_NAME}" "${cidr}" -exist 2>/dev/null || true
        done
    else
        log "WARNING: could not fetch api.github.com/meta; GitHub access will be blocked"
    fi
fi

log "allowlist holds $(ipset list "${IPSET_NAME}" | grep -c '^[0-9]' || echo 0) entries"

# ---------------------------------------------------------------------------------------------
# Rules
#
# Existing chains are left alone rather than flushed. A privileged inner dockerd has already written
# its NAT and forwarding rules by the time this runs, and wiping them breaks every nested container's
# networking. The allowlist is expressed as appended OUTPUT rules plus DOCKER-USER, which is the hook
# Docker documents for exactly this.
# ---------------------------------------------------------------------------------------------
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# Return traffic for connections we allowed on the way out.
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# DNS has to stay open: the allowlist is built from names, and the resolver is Docker's, not ours.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# The container's own attached networks, so the gateway, the embedded DNS resolver and sibling
# services on a user-defined network stay reachable. This is also what keeps the shared Ollama and
# LiteLLM containers reachable in restricted mode: they are on a user-defined network, so they are
# covered here rather than needing a name in the allowlist. Read from the link-scope routes, which
# are already expressed as networks — an interface address would need masking first.
# shellcheck disable=SC2046  # one network per line, splitting is the point
for network in $(ip -o -f inet route show scope link | awk '{print $1}'); do
    iptables -A OUTPUT -d "${network}" -j ACCEPT
done

iptables -A OUTPUT -m set --match-set "${IPSET_NAME}" dst -j ACCEPT

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Nested containers (privileged mode only — rootless traffic is relayed through the parent namespace
# and already passes the OUTPUT rules above). DOCKER-USER is consulted before Docker's own accept
# rules, and RETURN means "carry on into them".
if iptables -L DOCKER-USER -n >/dev/null 2>&1; then
    iptables -F DOCKER-USER
    iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    iptables -A DOCKER-USER -p udp --dport 53 -j RETURN
    iptables -A DOCKER-USER -m set --match-set "${IPSET_NAME}" dst -j RETURN
    # Container-to-container traffic on the inner bridges, so compose stacks keep working.
    for private in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
        iptables -A DOCKER-USER -d "${private}" -j RETURN
    done
    iptables -A DOCKER-USER -j REJECT --reject-with icmp-port-unreachable
fi

# The allowlist is IPv4-only, so leaving IPv6 open would be a way around all of the above.
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    ip6tables -P INPUT DROP 2>/dev/null || true
    ip6tables -P FORWARD DROP 2>/dev/null || true
    ip6tables -P OUTPUT DROP 2>/dev/null || true
fi

# ---------------------------------------------------------------------------------------------
# Prove it works. A firewall that silently failed open is worse than none, because the session
# proceeds believing it is contained.
# ---------------------------------------------------------------------------------------------
if curl -fsS --max-time 5 https://example.com >/dev/null 2>&1; then
    die "verification failed: example.com is still reachable, egress is NOT restricted"
fi

# The agent's own first domain is the positive control. Most of these answer 4xx without
# credentials, and curl -f turns that into a failure, so only a connection-level failure counts.
probe="${AGENT_DOMAINS%% *}"
if [ -n "${probe}" ]; then
    if ! curl -sS --max-time 10 -o /dev/null "https://${probe}/" 2>/dev/null; then
        # The policy is already DROP at this point, so the container is going to be torn down. Say
        # what to do about it rather than only what went wrong: this is the one failure a user meets
        # while their session refuses to start.
        log "the allowlist is in place but ${probe} does not answer through it."
        log "Usually one of:"
        log "  - the address moved since it was resolved a moment ago (CDN, short TTL)"
        log "  - the host needs more names than agents/${AGENT_ID:-<id>}/agent.env lists"
        log "  - egress here goes through a proxy that is not in the allowlist"
        log "Add what is missing and try again:"
        log "    DOCKER_CODE_ALLOW_DOMAINS=\"host.example,proxy.example\" ${AGENT_ID:-<agent>}-docker"
        log "Or run without the allowlist: DOCKER_CODE_NET=full ${AGENT_ID:-<agent>}-docker"
        die "verification failed: ${probe} is unreachable, ${AGENT_ID:-this agent} cannot work"
    fi
    log "egress restricted; ${probe} reachable, example.com blocked"
else
    log "egress restricted; example.com blocked (no agent domain to probe)"
fi
