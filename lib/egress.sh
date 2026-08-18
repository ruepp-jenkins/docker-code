# shellcheck shell=bash
# The egress gateway: a filtering proxy in front of a session, for DOCKER_CODE_NET=gateway.
#
# Why this exists next to image/init-firewall.sh, which already restricts egress:
#
#   - That firewall matches on destination IP. Names are only an input at boot, resolved once into an
#     ipset before the policy flips to DROP, so a CDN that rotates its edge addresses breaks a
#     session that was working minutes earlier. A proxy matches the name the client asked for, and
#     never looks at the address at all.
#   - It runs *inside* the container it restricts, which is why restricted mode has to hand the
#     session NET_ADMIN. With the default privileged inner Docker, a nested container shares that
#     network namespace and can flush the rules meant to bound it. A gateway keeps enforcement
#     somewhere the session cannot reach, and the session needs no capabilities at all.
#
# Containment here is topological rather than rule-based: the session's only network is created
# --internal, so there is no route off the host except the proxy. Nothing to flush, nothing to
# escape. It also means the session has no external DNS — Docker's embedded resolver answers
# SERVFAIL for outside names on an internal network — which closes DNS as an exfiltration channel.
# Proxy clients never resolve the target themselves, so this costs nothing; peer names on the network
# still resolve, which is how the gateway is reached.
#
# One gateway per agent, so each agent's AGENT_DOMAINS stays its own bound rather than being unioned
# with every other tool's vendor. Sessions of the same agent share one.
#
# See docs/EGRESS.md.

EGRESS_LABEL="com.ruepp.docker-code"
EGRESS_IMAGE="${DOCKER_CODE_EGRESS_IMAGE:-ubuntu/squid:6.6-24.04_edge}"
EGRESS_PORT="${DOCKER_CODE_EGRESS_PORT:-3128}"

# The one network in this file that is *not* internal: the gateways' own way out. Shared by all of
# them, because there is nothing per-agent about "the internet".
EGRESS_OUT_NETWORK="${DOCKER_CODE_EGRESS_OUT_NETWORK:-docker-code-egress-out}"

# The id used for the gateway that fronts the shared services rather than an agent.
EGRESS_SERVICES_ID="services"

# Deliberately no fixed subnet, unlike the mirror's 172.30.30.0/24 and the model network's
# 172.30.31.0/24. Those were pinned so they could be named in a route or a corporate firewall
# exception; an internal network has no route out, so there is nothing to name — and reserving a
# range per agent to say so would burn nine /24s for no reader.

# The three lists below are assembled into one allowlist by session_egress in bin/docker-code, which
# is the only consumer — hence the disables; they are the interface of this file, not dead weight.
#
# Package registries any agent reaches for when it launches an MCP server or installs a dependency.
#
# One per mainstream language, because an agent that cannot run the project's own build is not much
# use on it: a session pointed at a .NET repository that cannot reach nuget.org fails at `dotnet
# restore`, before it has read a line of the code it was asked about. These are the same class of host
# as npm and PyPI, which were always here — a public, versioned artifact store — so allowing them
# changes the size of the bound rather than its shape.
#
# Wildcards where the ecosystem splits metadata and artifacts across hosts, which most of them do:
# crates.io serves the index from index.crates.io and the .crate from static.crates.io, and allowing
# only the first gets `cargo build` as far as resolving versions and no further.
#
# Kept in step with COMMON_DOMAINS in image/init-firewall.sh; tests/egress.bats compares the two.
# shellcheck disable=SC2034
EGRESS_COMMON_DOMAINS=(
    # JavaScript. registry.yarnpkg.com is a separate host, not an alias Yarn resolves to npm's.
    registry.npmjs.org
    registry.yarnpkg.com
    jsr.io

    # Python. files.pythonhosted.org is where pypi.org's metadata points for the wheel itself.
    pypi.org
    files.pythonhosted.org

    # .NET. api.nuget.org carries both the service index and the flat container packages come from;
    # globalcdn.nuget.org is what the client is redirected to for the .nupkg.
    .nuget.org

    # Java, Kotlin, Scala. repo.maven.apache.org is the canonical name and repo1.maven.org the host it
    # is a CNAME for; clients use both. Gradle fetches plugins and its own distribution from its.
    repo.maven.apache.org
    .maven.org
    .gradle.org

    # Go. The module proxy, the checksum database and the index are three separate names, and a build
    # that cannot reach sum.golang.org fails verification rather than falling back.
    .golang.org

    # Rust. Sparse index on index.crates.io, artifacts on static.crates.io, and rustup's toolchains on
    # static.rust-lang.org — a toolchain a project pins in rust-toolchain.toml is fetched on demand.
    .crates.io
    .rust-lang.org

    # Ruby, PHP, Dart, Elixir. Composer resolves most dist URLs to codeload.github.com, which is why
    # PHP works in practice only with ALLOW_GITHUB on; pub.dev keeps its archives on GCS.
    .rubygems.org
    .packagist.org
    getcomposer.org
    pub.dev
    .hex.pm
    storage.googleapis.com

    # The other two source forges. Not only for `git clone`: a Go module outside the proxy is fetched
    # straight from its host, and Composer resolves most dist URLs to a forge, so these are as much a
    # dependency source as the registries above. GitHub is the third and arrives separately, because
    # DOCKER_CODE_ALLOW_GITHUB can turn it off.
    gitlab.com
    bitbucket.org
    api.bitbucket.org

    raw.githubusercontent.com
)

# What a Dockerfile needs to get past its first RUN line.
#
# Added only when there is an inner daemon, exactly like the image registries, and for the same
# reason: without one there is nothing here that could install a package. The agent's own container
# has no sudo, so this is never about apt inside the session — it is about `docker build`, which is
# most of why the inner daemon exists and which fails on almost any real Dockerfile without these.
# The base image resolves, the pull succeeds, and then `RUN apt-get update` cannot reach a mirror.
#
# Kept in step with OS_PACKAGE_DOMAINS in image/init-firewall.sh; tests/egress.bats compares the two.
# shellcheck disable=SC2034
EGRESS_OS_PACKAGE_DOMAINS=(
    # Canonical. The wildcard carries the regional and cloud mirrors a base image is likely to be
    # configured for — us.archive, de.archive, azure.archive — and ports.ubuntu.com, which is where
    # everything that is not amd64 gets its packages.
    .ubuntu.com

    # Debian, including security.debian.org: an image that skips it builds without its patches.
    .debian.org

    # Alpine, whose dl-cdn host is what `apk add` reads.
    .alpinelinux.org
)

# The image registries, and the reason this whole mode exists.
#
# These are wildcards where init-firewall.sh has to name hosts one at a time. A Docker Hub pull takes
# its token from auth.docker.io, its manifest from registry-1.docker.io, and then follows a 307 to
# whichever CDN Hub picked for the layer — Cloudflare or CloudFront, on unrelated networks. Listing
# one and not the other is what made `docker run hello-world` time out halfway through a pull.
# `.docker.com` covers both, and covers the next CDN Hub adds without an edit here.
#
# The same split applies to every registry below, which is why each one contributes an API host *and*
# wherever it hands the layer off to. The pull-through cache in lib/mirror.sh does not help here: it
# proxies Docker Hub only, because that is all `--registry-mirror` does, so a ghcr.io or quay.io pull
# goes out on its own account whether the mirror is running or not.
#
# Kept in step with REGISTRY_DOMAINS in image/init-firewall.sh; tests/egress.bats compares the two.
# shellcheck disable=SC2034
EGRESS_REGISTRY_DOMAINS=(
    # Docker Hub: registry-1/index/auth under .docker.io, both blob CDNs under .docker.com.
    .docker.io
    .docker.com

    # Microsoft. The wildcard is not decoration: mcr.microsoft.com answers a blob request with a
    # redirect to a regional <region>.data.mcr.microsoft.com, which is what the old exact entry here
    # missed — authentication and manifest succeeded and the first layer hung.
    .mcr.microsoft.com

    # GitHub. Blobs come from pkg-containers.githubusercontent.com, a different host from the API
    # one. Listed rather than left to EGRESS_GITHUB_DOMAINS, because ALLOW_GITHUB=0 must not take
    # ghcr.io down with it; the pruning in egress_prune_domains drops it again when both are on.
    ghcr.io
    pkg-containers.githubusercontent.com

    # Red Hat. Layers come from cdn.quay.io and the numbered cdn01…cdn03 siblings.
    .quay.io

    # GitLab, Google Container Registry and Artifact Registry. All three sign a GCS URL for the blob,
    # so storage.googleapis.com is the shared half; .pkg.dev covers the regional Artifact Registry
    # hosts (us-docker.pkg.dev and the rest).
    registry.gitlab.com
    .gcr.io
    .pkg.dev
    storage.googleapis.com

    # Amazon's public registry and the Kubernetes one. registry.k8s.io picks a backend by client
    # geography — .pkg.dev and storage.googleapis.com above cover its GCP side, and the S3 side needs
    # a bucket named per region, which is what DOCKER_CODE_ALLOW_DOMAINS is for.
    public.ecr.aws
    registry.k8s.io
)

# Cloning and `gh` are close enough to table stakes for a coding agent to be on by default. Two names
# replace fetching api.github.com/meta and parsing it into CIDRs, which is a network call that could
# fail and leave GitHub blocked with a warning nobody reads.
# shellcheck disable=SC2034
EGRESS_GITHUB_DOMAINS=(
    .github.com
    .githubusercontent.com
)

# What the shared services need for their own upstream fetches. Only ever used by the services
# gateway, never by an agent's.
EGRESS_SERVICE_UPSTREAM_DOMAINS=(
    .docker.io
    .docker.com
    .ollama.com
    .ollama.ai
)

egress_container() { printf 'docker-code-egress-%s\n' "$1"; }
egress_network()   { printf 'docker-code-egress-%s\n' "$1"; }
egress_url()       { printf 'http://%s:%s\n' "$(egress_container "$1")" "${EGRESS_PORT}"; }
egress_dir()       { printf '%s\n' "${DOCKER_CODE_EGRESS_HOME:-${STORAGE_ROOT%/}/egress}/$1"; }

# ---------------------------------------------------------------------------------------------
# The allowlist
#
# Regenerated on every start, unlike the LiteLLM config in lib/models.sh which is written once and
# then left to the user. That file is a preference; this one *is* the policy, and a stale copy is a
# wrong policy rather than a preserved choice — an agent whose domains changed, or an
# ALLOW_DOMAINS that was dropped from the environment, has to be reflected here immediately.
# ---------------------------------------------------------------------------------------------

# egress_domain_covered <domain> <newline-separated wildcards>
#
# True when one of the wildcards already matches the domain. Needed because squid treats a redundant
# dstdomain entry as *fatal*, not as something to ignore:
#
#   ERROR: 'raw.githubusercontent.com' is a subdomain of '.githubusercontent.com'
#   FATAL: Bungled squid.conf line 9: acl allowed_domains dstdomain …
#
# The whole gateway then refuses to start. That pairing is not hypothetical — it is the default, since
# raw.githubusercontent.com is a common domain and .githubusercontent.com comes with
# DOCKER_CODE_ALLOW_GITHUB=1 — and a user writing DOCKER_CODE_ALLOW_DOMAINS=.openai.com next to an
# agent.env that already names api.openai.com hits the same wall.
egress_domain_covered() {
    local domain="$1" list="$2" candidate suffix

    while IFS= read -r candidate; do
        [ -n "${candidate}" ] || continue
        [ "${domain}" = "${candidate}" ] && continue
        suffix="${candidate#.}"
        case "${domain}" in
            "${suffix}"|*".${suffix}") return 0 ;;
        esac
    done <<EOF
${list}
EOF
    return 1
}

# egress_prune_domains <domains...>
#
# Drops exact duplicates, then anything a broader wildcard in the same list already covers. The
# broader entry always wins: it is the one that was asked for, and keeping the narrower one alongside
# is what squid refuses.
#
# Newline-separated strings rather than arrays throughout, because lib/agents.sh sets the bar at bash
# 3.2 and expanding a possibly-empty array under set -u is one of the ways that bash differs.
egress_prune_domains() {
    local all wildcards exacts kept result entry

    all="$(printf '%s\n' "$@" | grep -v '^[[:space:]]*$' | awk '!seen[$0]++' || true)"
    wildcards="$(printf '%s\n' "${all}" | grep '^\.' || true)"
    exacts="$(printf '%s\n' "${all}" | grep -v '^\.' || true)"

    kept=""
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        egress_domain_covered "${entry}" "${wildcards}" && continue
        kept="${kept}${entry}
"
    done <<EOF
${wildcards}
EOF

    result="${kept}"
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        egress_domain_covered "${entry}" "${kept}" && continue
        result="${result}${entry}
"
    done <<EOF
${exacts}
EOF

    printf '%s' "${result}" | grep -v '^[[:space:]]*$' || true
}

# egress_write_config <id> <domains...>
#
# A leading dot is squid's "this domain and every subdomain"; without one, dstdomain matches that
# host exactly. Entries are passed through verbatim so the caller decides which it wants — deriving
# `.openai.com` from `api.openai.com` here would silently widen every agent's bound.
egress_write_config() {
    local id="$1"
    shift

    local dir conf domain_list address_list entry
    dir="$(egress_dir "${id}")"
    conf="${dir}/squid.conf"

    mkdir -p "${dir}" || return 1

    # An address or CIDR cannot be a dstdomain; squid rejects the whole config rather than that one
    # line. DOCKER_CODE_ALLOW_DOMAINS has always accepted both, so sort them into the two ACL types
    # instead of making the user care which list a value belongs in.
    domain_list=""
    address_list=""
    for entry in "$@"; do
        [ -n "${entry}" ] || continue
        case "${entry}" in
            *[0-9].[0-9]*/[0-9]*|[0-9]*.[0-9]*.[0-9]*.[0-9]*)
                address_list="${address_list}${entry}
" ;;
            *)
                domain_list="${domain_list}${entry}
" ;;
        esac
    done

    # shellcheck disable=SC2046  # one domain per line is exactly what should be split here
    domain_list="$(egress_prune_domains $(printf '%s' "${domain_list}"))"
    address_list="$(printf '%s' "${address_list}" | awk '!seen[$0]++' || true)"

    # One space-separated line per ACL, which is how squid wants them.
    domain_list="$(printf '%s' "${domain_list}" | tr '\n' ' ')"
    address_list="$(printf '%s' "${address_list}" | tr '\n' ' ')"
    domain_list="${domain_list% }"
    address_list="${address_list% }"

    {
        echo "# Generated by docker-code on every start of the ${id} gateway. Do not edit:"
        echo "# this file is the allowlist, and it is rewritten from the environment each time."
        echo
        echo "http_port ${EGRESS_PORT}"
        echo "coredump_dir /var/spool/squid"

        # Both carried over from the conf.d/debian.conf this config deliberately does not include.
        echo "logfile_rotate 0"
        echo "max_filedescriptors 1024"
        echo

        # The stock squid.conf ends with `include /etc/squid/conf.d/*.conf`, and the image ships
        # conf.d/debian.conf containing `http_access allow localnet` — an allow for every RFC1918
        # source. squid is first-match-wins and the session sits on a 172.x network, so inheriting
        # that include would allow everything and leave the rules below as decoration. Hence a whole
        # file rather than a drop-in.
        if [ -n "${domain_list}" ]; then
            printf 'acl allowed_domains dstdomain %s\n' "${domain_list}"
        fi
        if [ -n "${address_list}" ]; then
            printf 'acl allowed_addresses dst %s\n' "${address_list}"
        fi

        echo "acl SSL_ports port 443"
        echo "acl Safe_ports port 80 443"

        # squid refuses CONNECT to anything outside 443/563 by default. The shared services speak
        # plain HTTP on their own ports, and without these a session with local models or the
        # registry mirror fails in a way that looks nothing like a port rule.
        echo "acl service_ports port 11434 4000 5000"
        echo "acl CONNECT method CONNECT"
        echo

        # squid's own cache manager, which the stock config denies and this one has to deny for
        # itself — dropping conf.d dropped that rule along with `http_access allow localnet`. Today a
        # manager request is refused anyway, because it is addressed to the gateway's own name and no
        # allowlist contains that. One wildcard in DOCKER_CODE_ALLOW_DOMAINS broad enough to cover it
        # would change that quietly, and `manager` is built in, so saying it costs a line.
        echo "http_access deny manager"
        echo "http_access deny !Safe_ports !service_ports"
        if [ -n "${domain_list}" ]; then
            echo "http_access allow CONNECT allowed_domains SSL_ports"
            echo "http_access allow CONNECT allowed_domains service_ports"
            echo "http_access allow allowed_domains Safe_ports"
            echo "http_access allow allowed_domains service_ports"
        fi
        if [ -n "${address_list}" ]; then
            echo "http_access allow CONNECT allowed_addresses SSL_ports"
            echo "http_access allow allowed_addresses Safe_ports"
        fi
        echo "http_access deny all"
        echo

        # To the file the image's entrypoint.sh tails, not /dev/stdout: that tail is what surfaces
        # decisions in `docker logs`. Both an allow and a deny are recorded, which is the first time
        # anything in docker-code says what a session tried to reach — a blocked call under
        # NET=restricted is a silent timeout with no record anywhere.
        echo "access_log stdio:/var/log/squid/access.log squid"

        # A filter, not a cache. The pull-through registry in lib/mirror.sh is what caches.
        echo "cache deny all"
    } >"${conf}" || return 1

    printf '%s\n' "${conf}"
}

# ---------------------------------------------------------------------------------------------
# Lifecycle
#
# Shaped like lib/mirror.sh: create-or-adopt the network, start on demand, reuse what is already
# running, and let the last session out turn off the light. The one difference that matters is that
# a failure here is *not* degradable — see egress_start.
# ---------------------------------------------------------------------------------------------
egress_create_network() {
    local name="$1" err
    egress_network_create=(docker network create --internal
        --label "${EGRESS_LABEL}=egress" "${name}")

    err="$("${egress_network_create[@]}" 2>&1 >/dev/null)" && return 0

    # Losing the race to a session that started at the same moment is not a failure.
    docker network inspect "${name}" >/dev/null 2>&1 && return 0
    [ -z "${err}" ] || warn "${err}"
    return 1
}

egress_ensure_network() {
    local name="$1"

    docker network inspect "${name}" >/dev/null 2>&1 && return 0
    egress_create_network "${name}"
}

# The gateways' shared route out. Not internal, obviously, and created separately so that an
# `--internal` typo can never accidentally apply to it.
egress_ensure_out_network() {
    docker network inspect "${EGRESS_OUT_NETWORK}" >/dev/null 2>&1 && return 0

    egress_out_create=(docker network create --label "${EGRESS_LABEL}=egress-out" "${EGRESS_OUT_NETWORK}")
    "${egress_out_create[@]}" >/dev/null 2>&1 && return 0
    docker network inspect "${EGRESS_OUT_NETWORK}" >/dev/null 2>&1
}

# egress_connect <container> <network>
#
# Idempotent: a gateway started for a session without local models has to gain the model network when
# a later session of the same agent asks for them, and re-connecting an attached network is an error
# worth swallowing rather than reporting.
egress_connect() {
    local container="$1" network="$2"

    docker network inspect "${network}" >/dev/null 2>&1 || return 1
    case " $(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
        "${container}" 2>/dev/null || true) " in
        *" ${network} "*) return 0 ;;
    esac
    docker network connect "${network}" "${container}" >/dev/null 2>&1
}

# egress_start <id> <domains...>
#
# Returns non-zero on any failure, and callers must treat that as fatal for the session. This is the
# one shared service in docker-code that does not degrade to a warning: a missing model gateway
# costs you local models, but a missing egress gateway would leave a session that asked to be
# filtered running unfiltered, which is worse than not starting at all.
egress_start() {
    local id="$1"
    shift

    local container network conf listed
    container="$(egress_container "${id}")"
    network="$(egress_network "${id}")"

    conf="$(egress_write_config "${id}" "$@")" || {
        warn "could not write the allowlist for the ${id} gateway under $(egress_dir "${id}")"
        return 1
    }

    egress_ensure_network "${network}" || return 1
    egress_ensure_out_network || return 1

    # The allowlist is regenerated every start, so a gateway that is already running is holding an
    # older one. Recreate rather than adopt: adopting would silently apply the previous session's
    # policy to this one. Safe because a squid restart drops no state worth keeping — it is a filter,
    # not a cache — and a session already attached keeps its network either way.
    listed="$(docker ps -aq --filter "name=^${container}$" 2>/dev/null || true)"
    if [ -n "${listed}" ]; then
        egress_remove "${container}"
    fi

    ensure_image "${EGRESS_IMAGE}" "the ${id} egress gateway" || return 1

    # The size of the allowlist, said out loud. A gateway that came up around an allowlist of two
    # entries because AGENT_DOMAINS was empty looks exactly like a healthy one until something is
    # refused, and this is the cheapest place to notice.
    local allowed
    allowed="$(awk '/^acl allowed_domains dstdomain/{print NF-3; exit}' "${conf}" 2>/dev/null || true)"
    say "starting the egress gateway for ${id} (${allowed:-0} domains allowed)"

    egress_create=(docker run --detach --rm
        --name "${container}"
        --network "${network}"
        --label "${EGRESS_LABEL}=egress"
        --label "${EGRESS_LABEL}.egress-for=${id}"
        --volume "${conf}:/etc/squid/squid.conf:ro"
        "${EGRESS_IMAGE}")

    "${egress_create[@]}" >/dev/null 2>&1 || {
        # Not a lost name race: the container was removed a few lines up, so this is a real failure.
        warn "could not start the ${id} egress gateway (${EGRESS_IMAGE})"
        return 1
    }

    # Second interface, after the run: the session-facing network is internal, so without this the
    # gateway has no more route out than the session does and every request would fail closed.
    egress_connect "${container}" "${EGRESS_OUT_NETWORK}" || {
        warn "the ${id} gateway has no route out; ${EGRESS_OUT_NETWORK} could not be attached"
        docker rm -f "${container}" >/dev/null 2>&1 || true
        return 1
    }

    egress_wait_ready "${container}" "waiting for the ${id} egress gateway to accept connections"
}

# squid parses its config, binds, and only then serves. A session that starts talking in between
# gets a connection refused that looks like a broken allowlist, so wait for the port rather than
# hand that race to every agent.
egress_wait_ready() {
    local container="$1" label="$2" tries=0 interval elapsed=0

    # Roughly 30 seconds in total, but not sampled evenly: squid usually binds within a second or two,
    # and polling once a second would charge every single session a full second it did not need. Eight
    # quick looks cover the normal case, then it backs off so a genuine failure does not spin.
    while [ "${tries}" -lt 36 ]; do
        [ "$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null || true)" = "true" ] || {
            progress_done
            warn "the egress gateway exited during startup; its log follows"
            docker logs --tail 15 "${container}" >&2 2>&1 || true
            return 1
        }
        if docker exec "${container}" sh -c \
            "grep -q 'Accepting HTTP Socket connections' /var/log/squid/cache.log 2>/dev/null" \
            >/dev/null 2>&1; then
            progress_done
            return 0
        fi

        if [ "${tries}" -lt 8 ]; then
            interval=0.25
            elapsed=$(( tries / 4 ))
        else
            interval=1
            elapsed=$(( tries - 6 ))
        fi

        progress_tick "${label}" "${tries}" "${elapsed}"
        sleep "${interval}"
        tries=$((tries + 1))
    done

    # Running but never announced itself. Let the session proceed — the port is usually up by the
    # time the agent's first request happens — but say so, because if it is not, the symptom is a
    # connection refused rather than a policy decision.
    progress_done
    warn "the egress gateway did not report readiness within 30s; continuing"
    return 0
}

# egress_stop <id>
#
# The last session of *that agent* turns off its gateway. Counted by the labels bin/docker-code
# already puts on every session container, filtered to one agent, because a claude session must not
# keep the codex gateway alive or vice versa.
# shellcheck disable=SC2317  # reached through the trap installed before the run, not by a call
egress_stop() {
    local id="$1" remaining container
    container="$(egress_container "${id}")"

    remaining="$(docker ps --filter "label=${EGRESS_LABEL}=session" \
        --filter "label=${EGRESS_LABEL}.agent=${id}" --format '{{.Names}}' 2>/dev/null || true)"
    if [ -n "${container_name:-}" ]; then
        remaining="$(printf '%s\n' "${remaining}" | grep -vxF "${container_name}" || true)"
    fi
    [ -z "${remaining}" ] || return 0

    egress_remove "${container}"

    # The network goes too, so a changed allowlist never inherits a stale one, and an agent that is
    # not running leaves nothing behind. It refuses while anything is attached, which is the correct
    # answer and needs no handling.
    docker network rm "$(egress_network "${id}")" >/dev/null 2>&1 || true
}

# Removed outright rather than stopped first, which is the opposite of what lib/mirror.sh does.
#
# `docker stop` is worth its grace period only when the process uses it. squid's image runs a bash
# entrypoint that never execs, so SIGTERM is delivered to bash and never reaches squid: the daemon
# waits out the full ten seconds and SIGKILLs regardless. Measured 10.2s against 0.26s for a forced
# removal, twice over once the services gateway is up — which was the whole of the twenty-second pause
# after closing an agent.
#
# Nothing is lost by it. The gateway is a filter and not a cache, its allowlist is a bind-mounted file
# on the host, and its log is per session.
egress_remove() {
    docker rm -f "$1" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------------------------
# The services gateway
#
# The per-agent gateways bound a session. They say nothing about the shared services, which fetch
# upstream on their own account: the registry mirror pulls from Docker Hub, `docker-code models pull`
# pulls from ollama.com. This one fronts those, with a fixed allowlist rather than an agent's.
#
# The distinction to keep straight, and docs/EGRESS.md says it too: a session is contained by having
# no route out, while a service is merely *pointed* at this proxy through HTTP_PROXY. A service could
# ignore that; it keeps a normal network because non-gateway sessions attach to the model network for
# their own egress. What this buys is a bound on where those services fetch from, and a log of it —
# not containment of a hostile actor. They run fixed upstream software, not agent-controlled code,
# which is why that is the right trade here and the wrong one for a session.
# ---------------------------------------------------------------------------------------------
egress_services_start() {
    egress_start "${EGRESS_SERVICES_ID}" "${EGRESS_SERVICE_UPSTREAM_DOMAINS[@]}"
}

egress_services_url() { egress_url "${EGRESS_SERVICES_ID}"; }

# The services gateway outlives any one session — the mirror and Ollama are shared across agents and
# are not torn down per session either — so it is stopped only when no session at all is left.
# shellcheck disable=SC2317  # reached through the trap installed before the run, not by a call
egress_services_stop() {
    local remaining container
    container="$(egress_container "${EGRESS_SERVICES_ID}")"

    remaining="$(docker ps --filter "label=${EGRESS_LABEL}=session" --format '{{.Names}}' 2>/dev/null || true)"
    if [ -n "${container_name:-}" ]; then
        remaining="$(printf '%s\n' "${remaining}" | grep -vxF "${container_name}" || true)"
    fi
    [ -z "${remaining}" ] || return 0

    egress_remove "${container}"
}

# egress_proxy_env <url>
#
# Populates egress_proxy_env_args with the flags a shared service needs to use a proxy, empty when the
# url is. A global array rather than a return value because that is how docker argv is assembled
# everywhere else here, and because compound assignment to a local is one of the places the bash
# macOS ships surprises people.
#
# Only ever applied to a service whose *outbound* traffic is what needs bounding. Notably not to
# LiteLLM: it talks to Ollama by container name, and NO_PROXY covers only loopback, so handing it a
# proxy would route its one useful call through a gateway that has no reason to allow it.
egress_proxy_env() {
    # shellcheck disable=SC2034  # read by lib/mirror.sh and lib/models.sh, which source this file
    egress_proxy_env_args=()
    [ -n "$1" ] || return 0

    # shellcheck disable=SC2034  # same
    egress_proxy_env_args=(
        --env "HTTP_PROXY=$1" --env "HTTPS_PROXY=$1"
        --env "http_proxy=$1" --env "https_proxy=$1"
        --env "NO_PROXY=localhost,127.0.0.1" --env "no_proxy=localhost,127.0.0.1")
}

# egress_service_proxy <var-value>
#
# Resolves DOCKER_CODE_REGISTRY_EGRESS / DOCKER_CODE_MODELS_EGRESS to the proxy URL a shared service
# should use, printing nothing when it should go straight out. `1` starts the services gateway, a URL
# is someone else's proxy and starts nothing, `0` is today's behaviour.
egress_service_proxy() {
    case "$1" in
        0|false|"")
            return 0
            ;;
        1|true)
            egress_services_start || {
                warn "could not start the shared-services gateway; that service goes out directly"
                return 0
            }
            egress_services_url
            ;;
        http://*|https://*)
            printf '%s\n' "$1"
            ;;
        *)
            die "a *_EGRESS setting must be 1, 0, or the URL of a proxy you run yourself, not '$1'"
            ;;
    esac
}
