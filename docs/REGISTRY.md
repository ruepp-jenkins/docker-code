# Images and registry

## The names

One repository per image, not one repository with agent-prefixed tags — no one reads a tag list with every tool nested inside it.

```
ruepp/docker-code-base        shared base layer
ruepp/docker-code-claude      base + Claude Code
ruepp/docker-code-codex       base + Codex CLI
ruepp/docker-code-gemini      …
ruepp/docker-code-qwen  -opencode  -cursor  -copilot  -kiro
```

| branch | Repositories | Tags |
|---|---|---|
| `master` / `main` | `ruepp/docker-code-<id>` | `<YYYYMMDD>` and `latest` |
| any other branch | `ruepp/docker-code-<id>-test` | `<branch>-<YYYYMMDD>` |

Another namespace, in one place:

```bash
export DOCKER_CODE_NAMESPACE=mycompany       # mycompany/docker-code-claude:latest
export DOCKER_CODE_TAG=20260815              # Pin a specific version
export DOCKER_CODE_CLAUDE_IMAGE=other/image:1 # Override one agent only
```

## No architecture tags

Both architectures are built natively on separate machines and pushed **by digest**, without a tag. `scripts/docker_manifest.sh` then combines them into a manifest list, making it the only pipeline step that writes a tag.

This avoids permanent `20260815-amd64` and `20260815-arm64` tags. A failed build leaves existing tags untouched, and a tag can never expose only one architecture.

The price: the digest has to go from the build machine to the manifest machine — that's what the `stash` in the `Jenkinsfile` is for.

## Build order

```
Prepare  →  Base (amd64 ‖ arm64)  →  Base manifest  →  Agents (9 × 2)  →  Agent manifests
```

The base manifest must exist before an agent build starts: agent Dockerfiles resolve their base image through a tag, and the manifest step is what writes it. On a branch, they use the base image from **that branch**, so every agent tests a base-image change before it reaches `master`.

The test suite runs exactly once, in the `test` stage of `base/Dockerfile`. `verified` denies the image if it was red, and each agent image copies that stamp — so a red test blocks all of them.

---

# The pull-through cache

A registry container as a proxy in front of Docker Hub. Sessions cannot share an image store — two daemons cannot share a data root, containerd holds an exclusive lock — but they can share what they pull. The second, third and fourth pull of the same base image thus becomes a copy via the local bridge.

It's also the answer to Docker Hub's rate limit: this counts anonymous pulls per IP, and an account on the mirror increases it for every session behind it.

**Off by default.** There is an additional container on your machine and that should be a decision and not a surprise.

```bash
export DOCKER_CODE_REGISTRY_MIRROR=1
```

| variable | Default | Meaning |
|---|---|---|
| `DOCKER_CODE_REGISTRY_MIRROR` | `0` | `1`, `0`, or the URL of a mirror that you run yourself |
| `DOCKER_CODE_REGISTRY_UPSTREAM` | `https://registry-1.docker.io` | what the cache sits in front of |
| `DOCKER_CODE_REGISTRY_HOME` | `~/docker-code/registry/data` | where the blobs are |
| `DOCKER_CODE_REGISTRY_SUBNET` | `172.30.30.0/24` | empty leaves the choice to Docker |
| `DOCKER_CODE_REGISTRY_USERNAME` / `_PASSWORD` | — | Docker Hub account used to raise the rate limit |
| `DOCKER_CODE_REGISTRY_EGRESS` | `1` | under `NET=gateway` only: `1` routes the cache's own Hub fetch through the shared-services gateway, `0` goes direct, or give a proxy URL ([EGRESS.md](EGRESS.md)) |

```bash
docker-code registry start|stop|status
```

## Behavior

- The container uses its own network and publishes **no** host port. It still works with
  `DOCKER_CODE_NET=restricted` because the container firewall allows attached Docker networks.
- Container labels record the upstream and storage location and are checked at every start. A
  mismatch recreates the container without deleting cached blobs, which are addressed by digest.
- Sessions are counted by label **across every agent**. A running Claude session therefore
  keeps the mirror alive while a Codex session starts.
- Every failure becomes a warning and the session continues without the mirror. A cache must never
  prevent an agent session from starting.

## Hub pulls without the mirror, under `restricted`

With the mirror off, the inner daemon pulls from Docker Hub through the container firewall, and
`image/init-firewall.sh` names the hosts that takes: the registry API, the token endpoint, and
**both** blob CDNs — Hub answers a layer request with a redirect to Cloudflare or to CloudFront, and
which one it picks is not something the client controls.

That list is resolved once, at container start, into a set of addresses. A CDN edge can rotate
within the lifetime of a long session, so a pull that worked at the start can time out later with
nothing having changed. Turning the mirror on is the durable answer: Hub traffic then goes to a
container on the host, outside the firewall, and no CDN address has to be guessed in advance.

## Other registries

The mirror only applies to Docker Hub — this is how `--registry-mirror` works in Docker. A pull from
`ghcr.io`, `quay.io`, `mcr.microsoft.com` or any other registry therefore goes out on its own account,
with the mirror on and with it off alike, and under a filtering `DOCKER_CODE_NET` it needs a place on
the allowlist to do so.

The mainstream ones are on it by default whenever the session has an inner Docker daemon — Docker Hub,
MCR, ghcr.io, Quay, GitLab, GCR and Artifact Registry, ECR Public, and `registry.k8s.io`.
[EGRESS.md](EGRESS.md#the-image-registries) lists the hosts each one contributes and applies to both
filtering modes.

What is worth knowing when one of them fails: a registry answers a layer request with a redirect to a
different host, so an allowlist that names only the API host gets you through authentication and the
manifest and then hangs on the first blob. If a pull stalls that way, the host in the redirect is what
is missing:

```bash
export DOCKER_CODE_ALLOW_DOMAINS="cdn.example-registry.io"
```

Under `DOCKER_CODE_NET=gateway` the proxy log names it for you:

```bash
docker logs docker-code-egress-claude | grep TCP_DENIED
```

Under `DOCKER_CODE_NET=restricted` there is no such log — the packet is dropped by the OUTPUT policy
and the daemon reports an i/o timeout — which is one reason `gateway` is the easier mode to debug a
registry against.

For an internal registry via simple HTTP:

```bash
export DOCKER_CODE_INSECURE_REGISTRIES="registry.intern:5000"
```

This passes the host through to the inner daemon; Without this the pull fails with "server gave HTTP response to HTTPS client" because by default only `127.0.0.0/8` is excluded.

In `DOCKER_CODE_NET=restricted` it also needs a place in the allow list:

```bash
export DOCKER_CODE_ALLOW_DOMAINS="registry.intern"
```
