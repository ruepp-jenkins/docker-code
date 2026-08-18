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

# The progress helpers live in bin/docker-code, which cannot be sourced — it dispatches at the end —
# so they are lifted out of it by name.
progress_preamble() {
    printf 'SELF_NAME=docker-code\n'
    grep '^PROGRESS_FRAMES=' "${REPO_ROOT}/bin/docker-code"
    sed -n '/^progress_tick()/,/^}/p' "${REPO_ROOT}/bin/docker-code"
    sed -n '/^progress_done()/,/^}/p' "${REPO_ROOT}/bin/docker-code"
    sed -n '/^with_progress()/,/^}/p' "${REPO_ROOT}/bin/docker-code"
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

# gateway_allows <domain> <gateway list, newline separated>
#
# Whether squid built from that list would let the domain through: either the entry is there verbatim,
# or a wildcard in the list covers it.
#
# The wildcard half has to be filtered to leading-dot entries before egress_domain_covered sees it.
# That function documents itself as matching against *wildcards*, and egress_prune_domains only ever
# hands it those — but it derives its suffix with `${candidate#.}`, so a bare `crates.io` passed in
# would "cover" `index.crates.io`, which squid does not. Handing it the unfiltered list made an
# earlier version of these tests pass against an allowlist that had lost its wildcards entirely.
gateway_allows() {
    local domain="$1" gateway="$2" wildcards

    printf '%s\n' "${gateway}" | grep -qxF "${domain}" && return 0

    wildcards="$(printf '%s\n' "${gateway}" | grep '^\.' || true)"
    [ -n "${wildcards}" ] || return 1

    bash -c "
        . '${REPO_ROOT}/lib/egress.sh'
        egress_domain_covered '${domain}' '${wildcards}'
    "
}

# assert_gateway_covers <firewall array name> <gateway array name>
#
# Two mechanisms, one promise: a host reachable under NET=restricted but not under NET=gateway is a
# difference nobody would predict from the names of the modes. The firewall names hosts one at a time
# because it resolves them into an ipset, while the gateway matches names and can say `.crates.io`, so
# the check is coverage rather than equality.
assert_gateway_covers() {
    local firewall_list="$1" gateway_list="$2" domain gateway

    block="$(sed -n "/^${firewall_list}=(/,/^)/p" "${REPO_ROOT}/image/init-firewall.sh")"
    [ -n "${block}" ] || { echo "${firewall_list} not found in init-firewall.sh"; return 1; }
    eval "${block}"
    eval "set -- \"\${${firewall_list}[@]}\""

    gateway="$(bash -c ". '${REPO_ROOT}/lib/egress.sh'; printf '%s\n' \"\${${gateway_list}[@]}\"")"
    [ -n "${gateway}" ] || { echo "${gateway_list} could not be read"; return 1; }

    for domain in "$@"; do
        gateway_allows "${domain}" "${gateway}" || {
            echo "${domain} is allowed under NET=restricted, but nothing in ${gateway_list}"
            echo "covers it — so the same fetch would be refused under NET=gateway"
            return 1
        }
    done
}

@test "the common domains match the in-container firewall's list" {
    assert_gateway_covers COMMON_DOMAINS EGRESS_COMMON_DOMAINS
}

@test "every registry the in-container firewall names is reachable under the gateway too" {
    # The same promise, for the registry half: a `docker pull` from ghcr.io or quay.io that works
    # under NET=restricted but hangs under NET=gateway.
    assert_gateway_covers REGISTRY_DOMAINS EGRESS_REGISTRY_DOMAINS
}

@test "every OS package archive the firewall names is reachable under the gateway too" {
    assert_gateway_covers OS_PACKAGE_DOMAINS EGRESS_OS_PACKAGE_DOMAINS
}

@test "a Dockerfile can get past its first RUN line" {
    # `docker build` is most of why the inner daemon exists, and almost every real Dockerfile starts
    # by installing packages. Without these the base image pulls and then `apt-get update` cannot
    # reach a mirror — which looks like a broken build rather than an egress policy.
    gateway="$(bash -c ". '${REPO_ROOT}/lib/egress.sh'; printf '%s\n' \"\${EGRESS_OS_PACKAGE_DOMAINS[@]}\"")"

    for pair in \
        "Ubuntu:archive.ubuntu.com" \
        "Ubuntu security:security.ubuntu.com" \
        "Ubuntu on arm64:ports.ubuntu.com" \
        "Debian:deb.debian.org" \
        "Debian security:security.debian.org" \
        "Alpine:dl-cdn.alpinelinux.org"
    do
        distro="${pair%%:*}"
        domain="${pair##*:}"
        gateway_allows "${domain}" "${gateway}" || {
            echo "${distro} cannot reach ${domain}, so a build installing packages would fail"
            return 1
        }
    done
}

@test "the OS package archives are added only when there is an inner Docker" {
    # Nothing in a session without a daemon could install a system package — there is no sudo — so a
    # non-dind session keeps the smaller allowlist, exactly as the image registries do.
    grep -q 'OS_PACKAGE_DOMAINS' "${REPO_ROOT}/image/init-firewall.sh"
    block="$(sed -n '/^case "\${DOCKER_CODE_DIND:-0}" in/,/^esac/p' "${REPO_ROOT}/image/init-firewall.sh")"
    [ -n "${block}" ]
    [[ "${block}" == *"OS_PACKAGE_DOMAINS"* ]] || {
        echo "init-firewall.sh resolves the OS package archives outside the inner-Docker gate"
        return 1
    }

    # And the same gate on the host side, which is a different file and a different mechanism.
    block="$(sed -n '/^session_egress()/,/^}/p' "${REPO_ROOT}/bin/docker-code")"
    [[ "${block}" == *"EGRESS_OS_PACKAGE_DOMAINS"* ]]
    dind="$(printf '%s\n' "${block}" | sed -n '/case "${DIND_MODE}" in/,/esac/p')"
    [[ "${dind}" == *"EGRESS_OS_PACKAGE_DOMAINS"* ]] || {
        echo "session_egress adds the OS package archives outside the DIND_MODE gate"
        return 1
    }
}

@test "the forges whose registries are allowed can also be cloned from" {
    # registry.gitlab.com without gitlab.com is the asymmetry this catches: images pullable, repos
    # not. Always on rather than gated, because a Go module outside the proxy and most Composer dist
    # URLs are fetched from the forge during an ordinary dependency install.
    gateway="$(bash -c ". '${REPO_ROOT}/lib/egress.sh'; printf '%s\n' \"\${EGRESS_COMMON_DOMAINS[@]}\"")"
    for domain in gitlab.com bitbucket.org; do
        gateway_allows "${domain}" "${gateway}" || {
            echo "${domain} cannot be reached, so a clone from it would fail"
            return 1
        }
    done
}

@test "each mainstream language can fetch its dependencies" {
    # An agent that cannot run the project's own build is not much use on it, and the failure arrives
    # early and opaquely: `dotnet restore` or `cargo build` times out before the agent has read any of
    # the code it was asked about. One representative host per ecosystem, checked against the gateway
    # list because the firewall list is held to it by the test above.
    gateway="$(bash -c ". '${REPO_ROOT}/lib/egress.sh'; printf '%s\n' \"\${EGRESS_COMMON_DOMAINS[@]}\"")"

    for pair in \
        "JavaScript:registry.npmjs.org" \
        "Python:pypi.org" \
        ".NET:api.nuget.org" \
        "Java:repo.maven.apache.org" \
        "Go:proxy.golang.org" \
        "Rust:index.crates.io" \
        "Ruby:rubygems.org" \
        "PHP:repo.packagist.org" \
        "Dart:pub.dev" \
        "Elixir:repo.hex.pm"
    do
        language="${pair%%:*}"
        domain="${pair##*:}"
        gateway_allows "${domain}" "${gateway}" || {
            echo "${language} cannot reach ${domain}, so its dependency install would fail"
            return 1
        }
    done
}

@test "an ecosystem that splits metadata from artifacts has both halves allowed" {
    # The failure that reads as a broken network rather than a policy decision: resolution succeeds
    # against the index and the download then hangs, which is the same shape as the mcr.microsoft.com
    # blob-endpoint bug in the registry list.
    gateway="$(bash -c ". '${REPO_ROOT}/lib/egress.sh'; printf '%s\n' \"\${EGRESS_COMMON_DOMAINS[@]}\"")"

    # index host -> the artifact host that has to accompany it
    for pair in \
        "pypi.org:files.pythonhosted.org" \
        "index.crates.io:static.crates.io" \
        "pub.dev:storage.googleapis.com" \
        "api.nuget.org:globalcdn.nuget.org"
    do
        index="${pair%%:*}"
        artifacts="${pair##*:}"
        gateway_allows "${artifacts}" "${gateway}" || {
            echo "${index} is allowed but ${artifacts} is not, so the download would hang"
            return 1
        }
    done
}

@test "each registry contributes its blob host, not only its API host" {
    # The failure this whole list exists to prevent, and the one that keeps coming back: the token
    # and the manifest succeed, then the layer request is redirected to a host nobody allowed and the
    # pull hangs until the daemon reports an i/o timeout. mcr.microsoft.com shipped that way — the
    # exact host was listed, its <region>.data.mcr.microsoft.com blob endpoint was not.
    run bash -c ". '${REPO_ROOT}/lib/egress.sh'; printf '%s\n' \"\${EGRESS_REGISTRY_DOMAINS[@]}\""
    [ "${status}" -eq 0 ]

    # api-host -> the entry that has to accompany it for a layer to arrive
    for pair in \
        "mcr.microsoft.com:.mcr.microsoft.com" \
        "ghcr.io:pkg-containers.githubusercontent.com" \
        "registry.gitlab.com:storage.googleapis.com" \
        "quay.io:.quay.io"
    do
        api="${pair%%:*}"
        blob="${pair##*:}"
        printf '%s\n' "${output}" | grep -qxF "${blob}" || {
            echo "${api} is allowed but ${blob} is not, so its layers would never arrive"
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
        say() { :; }
        ensure_image() { :; }
        progress_tick() { :; }
        progress_done() { :; }
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

# ---------------------------------------------------------------------------------------------
# Start and teardown cost
# ---------------------------------------------------------------------------------------------

@test "closing a session removes the gateway outright instead of waiting on docker stop" {
    # ubuntu/squid's entrypoint is a bash script that never execs, so SIGTERM is delivered to bash and
    # squid never sees it: `docker stop` waits out its full ten-second grace period and SIGKILLs
    # anyway. Measured 10.2s against 0.26s for a forced removal, twice over once the services gateway
    # is up — which was the whole of the twenty-second pause after closing an agent.
    make_stub docker
    run bash -c "
        warn() { :; }
        say() { :; }
        ensure_image() { :; }
        progress_tick() { :; }
        progress_done() { :; }
        die() { exit 1; }
        container_name=''
        . '${REPO_ROOT}/lib/egress.sh'
        egress_stop codex
    "
    [ "${status}" -eq 0 ]

    calls="$(stub_calls docker)"
    [[ "${calls}" == *"rm -f docker-code-egress-codex"* ]]
    [[ "${calls}" != *"stop docker-code-egress-codex"* ]] || {
        echo "the gateway is being stopped gracefully, which costs ten seconds for nothing:"
        printf '%s\n' "${calls}"
        return 1
    }
}

@test "the services gateway is torn down the same way, since it doubled the wait" {
    make_stub docker
    run bash -c "
        warn() { :; }
        say() { :; }
        ensure_image() { :; }
        progress_tick() { :; }
        progress_done() { :; }
        die() { exit 1; }
        container_name=''
        . '${REPO_ROOT}/lib/egress.sh'
        egress_services_stop
    "
    [ "${status}" -eq 0 ]
    [[ "$(stub_calls docker)" != *"stop docker-code-egress-services"* ]]
}

@test "the gateway image is pulled where the progress can be seen" {
    # egress_start sends docker run's output to /dev/null, which would swallow an implicit pull with
    # it and leave a first start looking like a hang.
    block="$(sed -n '/^egress_start()/,/^}/p' "${REPO_ROOT}/lib/egress.sh")"
    [ -n "${block}" ]
    [[ "${block}" == *"ensure_image"* ]]

    # And the pull has to come before the run, or it is not what the user is waiting on.
    pull_line="$(printf '%s\n' "${block}" | grep -n 'ensure_image' | head -n 1 | cut -d: -f1)"
    run_line="$(printf '%s\n' "${block}" | grep -n 'egress_create=' | head -n 1 | cut -d: -f1)"
    [ -n "${pull_line}" ] && [ -n "${run_line}" ]
    [ "${pull_line}" -lt "${run_line}" ]
}

@test "starting a gateway announces itself" {
    block="$(sed -n '/^egress_start()/,/^}/p' "${REPO_ROOT}/lib/egress.sh")"
    [[ "${block}" == *"say "* ]]
}

@test "the spinner writes nothing at all when stderr is not a terminal" {
    # Piped into a file, a CI log or this suite's own capture, carriage returns and escape codes are
    # noise that ends up committed in build output.
    run bash -c "
        SELF_NAME=docker-code
        $(grep '^PROGRESS_FRAMES=' "${REPO_ROOT}/bin/docker-code")
        $(sed -n '/^progress_tick()/,/^}/p' "${REPO_ROOT}/bin/docker-code")
        $(sed -n '/^progress_done()/,/^}/p' "${REPO_ROOT}/bin/docker-code")
        progress_tick 'waiting for something' 2 7
        progress_done
    "
    [ "${status}" -eq 0 ]
    [ -z "${output}" ] || {
        echo "the spinner emitted output with no tty: ${output}"
        return 1
    }
}

@test "every way out of the wait clears the spinner line" {
    # Three exits — the container died, it became ready, the budget ran out — and a line left
    # half-drawn on any of them sits above whatever the agent prints next.
    block="$(sed -n '/^egress_wait_ready()/,/^}/p' "${REPO_ROOT}/lib/egress.sh")"
    [ -n "${block}" ]
    [[ "${block}" == *"progress_tick"* ]]
    [ "$(printf '%s\n' "${block}" | grep -c 'progress_done')" -ge 3 ]
}

@test "the allowlist size is stated, so an empty one is visible before something is refused" {
    # A gateway built around two entries because AGENT_DOMAINS was empty looks exactly like a healthy
    # one until a request is denied.
    block="$(sed -n '/^egress_start()/,/^}/p' "${REPO_ROOT}/lib/egress.sh")"
    [[ "${block}" == *"domains allowed"* ]]
}

@test "a teardown step that finishes quickly says nothing at all" {
    # Closing an agent should hand the shell straight back. Narrating three steps that each take a
    # fifth of a second would put noise in front of the case nobody is waiting on.
    run bash -c "$(progress_preamble)
        with_progress 'stopping the registry mirror' true"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ] || {
        echo "a fast teardown step printed: ${output}"
        return 1
    }
}

@test "with_progress returns what the command returned" {
    # The work runs as a background child that is waited on, so a teardown that failed is still a
    # failure rather than something the spinner swallowed.
    run bash -c "$(progress_preamble)
        with_progress 'failing step' bash -c 'exit 7'"
    [ "${status}" -eq 7 ]
}

@test "with_progress leaves no process behind" {
    # A spinner that is itself backgrounded has to be killed on every path out, including the
    # interrupted ones, and one that outlives its parent spins on a terminal nobody owns.
    run bash -c "$(progress_preamble)
        with_progress 'a step' sleep 0.1
        jobs -p | grep -q . && echo LEFTOVER
        echo CLEAN"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *CLEAN* ]]
    [[ "${output}" != *LEFTOVER* ]]
}

@test "every teardown step names what it is doing" {
    block="$(sed -n '/^session_cleanup()/,/^}/p' "${REPO_ROOT}/bin/docker-code")"
    [ -n "${block}" ]
    [[ "${block}" == *"stopping the registry mirror"* ]]
    [[ "${block}" == *"egress gateway"* ]]

    # And no step is called bare, which would be one that stays silent however long it takes.
    for call in 'mirror_stop' 'egress_stop' 'egress_services_stop'; do
        printf '%s\n' "${block}" | grep -E "^[[:space:]]*${call}\b" && {
            echo "${call} is called without with_progress, so a slow one would look like a hang"
            return 1
        }
    done
    return 0
}

@test "the gateway allowlist names the shared services, or their ports ACL matches nothing" {
    # The session has no route to the model and mirror networks in this mode — the gateway joins them
    # instead — so the loopback bridge and the inner daemon reach those services by CONNECTing to
    # them by container name. squid matches CONNECT against dstdomain, so without these names the
    # service_ports ACL is paired with an allowed_domains list that can never contain the request:
    # DOCKER_CODE_LOCAL=1 under NET=gateway then failed at the proxy, which looks nothing like an
    # allowlist that is missing an entry.
    make_stub docker 'case "$*" in *State.Running*) echo true ;; esac'
    unset DOCKER_CODE_DRY_RUN
    export DOCKER_CODE_NET=gateway DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3-coder:7b
    run "${REPO_ROOT}/bin/qwen-docker"
    [ "${status}" -eq 0 ] || {
        echo "the session did not start: ${output}"
        return 1
    }

    local conf="${DOCKER_CODE_HOME}/egress/qwen/squid.conf"
    [ -f "${conf}" ] || {
        echo "no allowlist was written at ${conf}"
        return 1
    }

    for service in docker-code-ollama docker-code-litellm docker-code-registry; do
        grep -qE "^acl allowed_domains dstdomain .*(^| )${service}( |$)" "${conf}" || {
            echo "${service} is not in the allowlist, so the gateway would refuse it:"
            grep '^acl allowed_domains' "${conf}"
            return 1
        }
    done

    # And the pairing that makes them usable: they speak plain HTTP on ports squid refuses to CONNECT
    # to by default.
    grep -q '^http_access allow CONNECT allowed_domains service_ports$' "${conf}"
}

@test "NET=restricted says that a privileged inner Docker can undo it" {
    # The combination is a default DIND next to an explicitly chosen NET, so nobody opted into it:
    # the root daemon shares the session's network namespace and one nested container flushes the
    # rules. docs/EGRESS.md has said so all along; the session that is about to rely on it should too.
    export DOCKER_CODE_NET=restricted
    run "${REPO_ROOT}/bin/codex-docker"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"flush the allowlist"* ]] || {
        echo "no warning about the inner daemon: ${output}"
        return 1
    }
    [[ "${output}" == *"DOCKER_CODE_NET=gateway"* ]]
}

@test "the warning is about that daemon, not about restricted mode in general" {
    # Without an inner daemon there is nothing in the namespace to flush, and a warning that fires
    # anyway is one people learn to scroll past.
    export DOCKER_CODE_NET=restricted DOCKER_CODE_DIND=0
    run "${REPO_ROOT}/bin/codex-docker"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"flush the allowlist"* ]] || {
        echo "warned about a daemon this session does not have: ${output}"
        return 1
    }
}

@test "a YOLO session is pointed at the mode that actually holds" {
    # It used to recommend NET=restricted, which the default privileged inner Docker lets the very
    # actor this is warning about undo. Recommending the enforcement that lives outside the session
    # is the whole difference.
    export DOCKER_CODE_YOLO=1
    run "${REPO_ROOT}/bin/codex-docker"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DOCKER_CODE_NET=gateway"* ]]
    [[ "${output}" != *"Consider DOCKER_CODE_NET=restricted"* ]]
}
