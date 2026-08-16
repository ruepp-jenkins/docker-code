# Images and registry

## The names

One repository per image, not one repository with agent-prefixed tags — no one reads a tag list with eight tools nested inside each other.

```
ruepp/docker-code-base        shared base layer
ruepp/docker-code-claude      base + Claude Code
ruepp/docker-code-codex       base + Codex CLI
ruepp/docker-code-gemini      …
ruepp/docker-code-qwen  -opencode  -cursor  -copilot
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
Prepare  →  Base (amd64 ‖ arm64)  →  Base manifest  →  Agents (8 × 2)  →  Agent manifests
```

The base manifest must exist before an agent build starts: agent Dockerfiles resolve their base image through a tag, and the manifest step is what writes it. On a branch, they use the base image from **that branch**, so all eight agents test a base-image change before it reaches `master`.

The test suite runs exactly once, in the `test` stage of `base/Dockerfile`. `verified` denies the image if it was red, and each agent image copies that stamp — so a red test blocks all eight.

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

```bash
docker-code registry start|stop|status
```

## Behavior

- The container uses its own network and publishes **no** host port. It still works with
  `DOCKER_CODE_NET=restricted` because the container firewall allows attached Docker networks.
- Container labels record the upstream and storage location and are checked at every start. A
  mismatch recreates the container without deleting cached blobs, which are addressed by digest.
- Sessions are counted by label **across all eight agents**. A running Claude session therefore
  keeps the mirror alive while a Codex session starts.
- Every failure becomes a warning and the session continues without the mirror. A cache must never
  prevent an agent session from starting.

## Other registries

The mirror only applies to Docker Hub — this is how `--registry-mirror` works in Docker. For an internal registry via simple HTTP:

```bash
export DOCKER_CODE_INSECURE_REGISTRIES="registry.intern:5000"
```

This passes the host through to the inner daemon; Without this the pull fails with "server gave HTTP response to HTTPS client" because by default only `127.0.0.0/8` is excluded.

In `DOCKER_CODE_NET=restricted` it also needs a place in the allow list:

```bash
export DOCKER_CODE_ALLOW_DOMAINS="registry.intern"
```
