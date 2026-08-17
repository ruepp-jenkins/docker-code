# The egress gateway

`DOCKER_CODE_NET=gateway` filters a session's outbound traffic **by domain name**, in a separate
container the session cannot reach into.

```bash
DOCKER_CODE_NET=gateway codex-docker
```

## Why, next to `NET=restricted`

`restricted` has worked since the beginning and is not going away. But it has two properties that
this mode exists to change.

**It filters by address.** `image/init-firewall.sh` resolves the allowlist once at startup into an
ipset, and `iptables` then matches on destination IP. The name is gone by the time any packet is
checked. A CDN that rotates its edge addresses therefore breaks a session that worked minutes
earlier — `production.cloudfront.docker.com` was observed moving from `108.138.36.x` to
`18.66.102.x` inside two minutes. Naming a host is not enough when the host is a moving target.

**It runs inside the container it restricts.** That is why `restricted` has to grant the session
`NET_ADMIN`. With the default `DIND=privileged`, the inner daemon shares the session's network
namespace, so a nested privileged container can flush the rules meant to bound it. Against a careless
agent that never happens; against a prompt injection or a hostile dependency — the threat the mode
names — it is exactly the actor who would.

Under `gateway`, the session gets **no capabilities at all**, and the allowlist is a list of names:

```squid
acl allowed_domains dstdomain .docker.com api.openai.com
```

A leading dot is squid's wildcard: `.docker.com` matches `production.cloudfront.docker.com`,
`production.cloudflare.docker.com`, and whatever CDN Docker Hub adds next. Without the dot it matches
that host exactly.

## How it is contained

```
                    ┌─ internal network, no route off the host ─┐
  session ──────────┤   docker-code-egress-codex (squid)        ├────── internet
  no NET_ADMIN      └──────────────────┬────────────────────────┘
                                       ├──→ docker-code-ollama / -litellm
                                       └──→ docker-code-registry
```

Containment is **topological, not rule-based**. The session's only network is created `--internal`,
so there is no route off the host except the proxy. There are no rules inside the container to flush
and no capability with which to flush them.

Two consequences worth knowing:

- **The session has no external DNS.** Docker's embedded resolver answers `SERVFAIL` for outside
  names on an internal network. This costs nothing — a proxy client sends a hostname in `CONNECT` and
  never resolves the target itself — and it closes DNS as an exfiltration channel, which `restricted`
  leaves open because it has to accept all port 53 to build its allowlist from names. Peer names on
  the network still resolve, which is how the gateway is reached.
- **A blocked call is logged.** Under `restricted` a denied request is a silent timeout with no record
  anywhere. Here both decisions are in the access log:

```bash
docker-code egress logs codex
#   TCP_TUNNEL/200 CONNECT api.openai.com:443   ← allowed
#   TCP_DENIED/403 CONNECT example.com:443      ← refused
```

## One gateway per agent

`docker-code-egress-<agent>`, started on demand, shared by sessions of the same agent, stopped when
the last one exits. Per agent rather than one shared proxy so that each agent's `AGENT_DOMAINS` stays
its own bound — a single gateway would have to allow the union, and a Codex session could then reach
`api.anthropic.com`.

```bash
docker-code egress status              # which gateways are up, and where their allowlist is
docker-code egress logs <agent>        # what was allowed and what was refused
docker-code egress stop [agent...]     # all of them, or named ones
```

The allowlist is regenerated on **every** start, unlike the LiteLLM config in `lib/models.sh` which is
written once and left to you. This file *is* the policy; a stale copy is a wrong policy. Edit
`AGENT_DOMAINS` or `DOCKER_CODE_ALLOW_DOMAINS`, not `squid.conf`.

## What is on the list

| source | contents |
|---|---|
| `AGENT_DOMAINS` from `agents/<id>/agent.env` | the agent's own vendor, verbatim |
| built in | `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`, `raw.githubusercontent.com` |
| built in, when there is an inner Docker | the image registries — see below |
| `DOCKER_CODE_ALLOW_GITHUB=1` (the default) | `.github.com`, `.githubusercontent.com` |
| `DOCKER_CODE_ALLOW_DOMAINS` | yours, verbatim — names or CIDRs |

### The image registries

A session with an inner Docker daemon gets these, so that `docker pull` works against the registries
people actually use rather than Docker Hub alone. Each entry pairs the registry's API host with
whatever it redirects the layer to, because a pull that is allowed to fetch a manifest but not a blob
hangs until the daemon reports an i/o timeout — which reads as a broken network, not as a policy
decision.

| registry | allowed |
|---|---|
| Docker Hub | `.docker.io`, `.docker.com` |
| Microsoft (MCR) | `.mcr.microsoft.com` — the wildcard carries the regional `*.data.mcr.microsoft.com` blob endpoints |
| GitHub (ghcr.io) | `ghcr.io`, `pkg-containers.githubusercontent.com` |
| Red Hat (Quay) | `.quay.io` — covers `cdn.quay.io` and `cdn01`…`cdn03` |
| GitLab | `registry.gitlab.com` + `storage.googleapis.com` |
| Google (GCR, Artifact Registry) | `.gcr.io`, `.pkg.dev` + `storage.googleapis.com` |
| Amazon ECR Public | `public.ecr.aws` |
| Kubernetes | `registry.k8s.io` |

This applies whether or not the [pull-through cache](REGISTRY.md) is running: `--registry-mirror`
proxies Docker Hub and nothing else, so every other registry here is fetched from directly either way.

Two registries need a word of warning. `registry.k8s.io` chooses a backend by client geography, and
its AWS side signs a per-region S3 bucket that cannot be named in advance; the same is true of
Amazon ECR Public's layer bucket. If a pull from either stalls after the manifest, add the bucket the
redirect names to `DOCKER_CODE_ALLOW_DOMAINS`. Under `NET=gateway` the refusal is in the proxy log —
`docker logs docker-code-egress-<agent>` — which is the fastest way to find out which host it wanted.

`AGENT_DOMAINS` is emitted exactly as written, never widened into a wildcard. Those names still have
to resolve for `NET=restricted`, and `.openai.com` resolves to nothing — and deriving a subtree from a
hostname would quietly widen every agent's bound.

`DOCKER_CODE_ALLOW_DOMAINS` accepts both names and addresses and sorts them for you:

```bash
DOCKER_CODE_ALLOW_DOMAINS=".example.com,registry.intern,10.0.0.0/8" DOCKER_CODE_NET=gateway codex-docker
```

An address in a `dstdomain` list makes squid reject the whole config, so a CIDR becomes a `dst` rule
instead. Both live in one ruleset — domains and IPs together.

## Settings

| variable | default | meaning |
|---|---|---|
| `DOCKER_CODE_EGRESS_IMAGE` | `ubuntu/squid:6.6-24.04_edge` | the proxy image; matches the base image's Ubuntu |
| `DOCKER_CODE_EGRESS_PORT` | `3128` | the port the gateway listens on |
| `DOCKER_CODE_EGRESS_HOME` | `~/docker-code/egress` | where the generated allowlists live |
| `DOCKER_CODE_EGRESS_OUT_NETWORK` | `docker-code-egress-out` | the gateways' shared route out |
| `DOCKER_CODE_REGISTRY_EGRESS` | `1` | the registry mirror's own upstream fetch: `1` via the services gateway, `0` direct, or a proxy URL |
| `DOCKER_CODE_MODELS_EGRESS` | `1` | the same for Ollama's model pulls |

These are global rather than per-agent, unlike the session knobs in README.md: the services they
govern are shared across every agent by design, so a per-agent spelling would promise something it
cannot deliver.

Deliberately **no** fixed subnet, unlike the mirror's `172.30.30.0/24`. Those ranges were pinned so
they could be named in a route or a corporate firewall exception; an internal network has no route
out, so there is nothing to name.

## The shared services are a different question

The gateway bounds **the session**. It says nothing about the shared services, which sit on the host
and fetch upstream on their own account: the registry mirror pulls from Docker Hub, `docker-code
models pull` pulls from ollama.com.

Under `gateway` those are pointed at a second, shared gateway — `docker-code-egress-services`, with a
fixed allowlist of `.docker.io`, `.docker.com`, `.ollama.com`, `.ollama.ai` — unless you say otherwise:

```bash
DOCKER_CODE_REGISTRY_EGRESS=0 DOCKER_CODE_NET=gateway codex-docker   # mirror goes straight to Hub
DOCKER_CODE_MODELS_EGRESS=http://proxy.corp:3128 …                   # your proxy instead
```

**This is advisory, not containment, and the difference matters.** A session is contained because it
has no route out. A service is merely *pointed* at the proxy through `HTTP_PROXY`, and keeps a normal
network — it has to, because non-gateway sessions attach to that same model network for their own
egress. A service could ignore the setting.

That is an acceptable trade here and would not be for a session: these containers run fixed upstream
software, not agent-controlled code, and a pull-through registry can only fetch from the one upstream
it was configured with. What it buys is a bound on where they fetch from and a log of it — not
containment of a hostile actor. Do not read it as more than that.

Both settings apply only when a service is started **for a gateway-mode session**. A machine that
never uses `gateway` gets no extra container and no change in behaviour. A service already running
with the other setting is left alone with a warning rather than restarted mid-pull; `docker-code
registry stop` applies it.

## Known limitation: git over SSH

A `CONNECT` proxy carries HTTP and HTTPS. SSH does not go through it unaided, so `git clone git@…`
fails under `gateway` — closed, which is correct, but it fails. Most sessions are unaffected:
`DOCKER_CODE_SSH` is `0` by default and the container is meant to be unable to act as you, so cloning
happens over HTTPS with a token.

If you need it, socat is already in the image:

```
# ~/.ssh/config inside the session
Host github.com
    ProxyCommand socat - PROXY:docker-code-egress-<agent>:%h:%p,proxyport=3128
```

The gateway must also allow `CONNECT` to port 22, which the generated config does not do by default.

## Choosing between the modes

| | `restricted` | `gateway` |
|---|---|---|
| filters on | destination IP, resolved once at startup | domain name, per request |
| wildcards | no | yes — `.docker.com` |
| session holds `NET_ADMIN` | yes | no |
| survives a CDN rotating addresses | no | yes |
| external DNS | open (needed to build the list) | closed |
| refused calls are logged | no | yes |
| extra containers | none | one per active agent |
| git over SSH | works | needs a `ProxyCommand` |

`restricted` remains the right choice for a session with `DIND=0` that wants no extra containers.
`gateway` is the one to pick when the allowlist has to hold.
