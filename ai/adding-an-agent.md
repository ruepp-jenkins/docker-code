# Adding an agent

Adding a tool requires one directory under `agents/`. Wrappers, the installer, CI matrix, and tests
discover the registry from `agents/*/agent.env`; do not add a second enumeration elsewhere.

```text
agents/mytool/
├── agent.env      Required metadata
├── Dockerfile     Required, usually about 20 lines
└── defaults/      Optional configuration seeded on first start
```

Then run:

```bash
ln -s docker-code bin/mytool-docker
bats tests/registry.bats
./scripts/build.sh mytool
DOCKER_CODE_DRY_RUN=1 ./bin/mytool-docker
```

## `agent.env`

This is a flat `KEY=value` format. It is read, not sourced. Unknown keys are errors that include the
line number. Values may be double-quoted, single-quoted, or unquoted, and a line may continue onto the
next with `\`.

### Required keys

| Key | Meaning |
|---|---|
| `AGENT_ID` | Must equal the directory name |
| `AGENT_BIN` | Command executed in the container |
| `AGENT_WRAPPER` | Host command; must end in `-docker` and differ from `AGENT_BIN` |

### Optional keys

| Key | Default | Meaning |
|---|---|---|
| `AGENT_TITLE` | `AGENT_ID` | Human-readable name in messages |
| `AGENT_HOSTNAME` | `AGENT_ID` | Container hostname |
| `AGENT_ALIASES` | — | Additional space-separated wrapper names |
| `AGENT_YOLO_ARGS` | — | Arguments prepended when `DOCKER_CODE_YOLO=1` |
| `AGENT_YOLO_SKIP` | — | Subcommands that must not receive YOLO arguments, such as `mcp` or `login` |
| `AGENT_PERMISSION_FLAGS` | `AGENT_YOLO_ARGS` | User-supplied flags that suppress YOLO injection |
| `AGENT_ROOT_ENV` | — | Variables set when the container runs as root, such as `IS_SANDBOX=1` |
| `AGENT_ENV_VARS` | — | Variables passed through from the host |
| `AGENT_DOMAINS` | — | Hosts allowed by `DOCKER_CODE_NET=restricted`; the first is the connectivity probe |
| `AGENT_LOCAL_MODE` | `none` | Local-model wire format and gateway selection |
| `AGENT_LOCAL_ENV` | — | Semicolon-separated `NAME=value` entries; `%u` is the gateway URL and `%m` the model |
| `AGENT_LOCAL_ARGS` | — | Additional local-model arguments; `%m` is the model name |
| `AGENT_NOTE` | — | One-sentence limitation; required when `AGENT_LOCAL_MODE=none` |

### `AGENT_LOCAL_MODE`

| Mode | Target | Use when the tool... |
|---|---|---|
| `none` | — | Cannot use local models; set `AGENT_NOTE` |
| `openai-compat` | Ollama on `:11434` | Accepts an OpenAI-compatible base URL |
| `ollama-anthropic` | Ollama on `:11434` | Speaks the Anthropic Messages format |
| `litellm-gemini` | Gateway on `:4000` | Speaks only Google's native format |
| `litellm-openai` | Gateway on `:4000` | Needs translation from OpenAI format |
| `litellm-anthropic` | Gateway on `:4000` | Needs translation from Anthropic format |

Both endpoints appear as localhost inside the agent container. Port forwarding provides this because
several tools hard-code localhost below their configuration surface. See
[Local models](../docs/LOCAL-MODELS.md).

## Dockerfile

The build context is always the repository root, not the agent directory.

```dockerfile
# syntax=docker/dockerfile:1
ARG BASE_IMAGE=ruepp/docker-code-base:latest
FROM ${BASE_IMAGE}

ARG MYTOOL_VERSION=latest
RUN set -eux; \
    npm install -g "mytool@${MYTOOL_VERSION}"; \
    npm cache clean --force

COPY agents/mytool/agent.env /etc/docker-code/agent.env
COPY agents/mytool/defaults/ /opt/docker-code/defaults/

RUN set -eux; \
    env HOME=/root mytool --version; \
    rm -rf /root/.mytool
```

`tests/registry.bats` and `tests/image.bats` enforce three requirements:

1. Copy `agents/<id>/agent.env` to `/etc/docker-code/agent.env`; `launch.sh` and
   `init-firewall.sh` read it at runtime.
2. Run `<bin> --version` as a build smoke test. This catches architecture-specific binaries that
   cannot execute before an image is published.
3. Run the smoke test with `HOME=/root` and remove generated state. The image's normal home is the
   bind-mount target, where a root-owned build artifact would break the first real start.

Never install the tool under `/home/agent`; the bind mount replaces it at runtime. If an installer
insists on writing there, redirect its home and link the executable into `/usr/local/bin`, as in
`agents/cursor/Dockerfile`.

When adding an apt repository, pin its signing key to the expected fingerprint. See
`agents/claude/Dockerfile`. An unverified repository key is a supply-chain vulnerability in an image
designed to run a highly privileged coding agent.

A tool that ships as a downloaded archive rather than a package needs the same treatment: verify its
checksum against the vendor's own manifest before unpacking it. See `agents/kiro/Dockerfile`.

## Defaults

The `defaults/` tree mirrors the user's home directory. For example,
`defaults/.codex/config.toml` becomes `~/.codex/config.toml`.

Seeding operates per file and never overwrites an existing file. Existing installations can
therefore receive newly introduced defaults without losing user configuration. Seeding happens at
every start because Docker does not prepopulate a bind mount from image contents as it does an empty
named volume.

## CI release trigger

If the Dockerfile installs the tool from npm, add a `URLTriggerEntry` to `Jenkinsfile`; otherwise a
new package release will not trigger an image build because agent self-updaters are disabled.
`tests/pipeline.bats` reports a missing npm trigger by package name.

A tool from somewhere other than a package registry needs the entry just as much, pointed at
whatever endpoint states its current version — the release manifest for Kiro CLI, for example. Only
the npm case is enforced by a test, because only that one has a URL shape worth guessing.

The rest of the pipeline, including its build matrix and manifest steps, discovers agents from the
`agents/` directory and requires no manual enumeration.
