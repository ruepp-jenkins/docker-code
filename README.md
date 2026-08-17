# docker-code

Nine TUI coding agents, each in its own container, each with its own persistent directory — and a common local model store that they all share.

| Call | Tool | Local Models |
|---|---|---|
| `claude-docker` | [Claude Code](https://docs.claude.com/en/docs/claude-code) | yes, through Ollama |
| `codex-docker` | [OpenAI Codex CLI](https://github.com/openai/codex) | yes, through Ollama |
| `gemini-docker` | [Gemini CLI](https://github.com/google-gemini/gemini-cli) | yes, via the LiteLLM gateway |
| `qwen-docker` | [Qwen Code](https://github.com/QwenLM/qwen-code) | yes, through Ollama |
| `mistral-docker` | [Mistral Vibe](https://github.com/mistralai/mistral-vibe) | yes, through Ollama |
| `opencode-docker` | [OpenCode](https://opencode.ai) | yes, through Ollama |
| `cursor-agent-docker` | [Cursor CLI](https://cursor.com/docs/cli/overview) | no (cloud only) |
| `copilot-docker` | [GitHub Copilot CLI](https://github.com/github/copilot-cli) | no (cloud only) |
| `kiro-docker` | [Kiro CLI](https://kiro.dev/docs/cli/) | no (cloud only) |

The suffix `-docker` is intentional: `claude` remains `claude`, `gemini` remains `gemini`. Nothing you installed today will be hidden.

---

## Installation

```bash
git clone https://github.com/ruepp-jenkins/docker-code.git
./docker-code/install.sh --local
```

The installer places the tree under `~/.local/share/docker-code` and links `docker-code` plus one wrapper per agent to `~/.local/bin`. It uses **no** sudo, writes to **no** shell startup file, and creates **no** alias.

Fetching goes through git, for installs and for `docker-code self-update` alike. GitHub throttles its archive endpoints — `codeload` and `raw.githubusercontent.com` — separately from the rest of the API and considerably harder, so a download-based installer fails with `HTTP 429` at moments when cloning the same repository works fine. Every machine this runs on has git anyway.

```bash
cd ~/my-project
claude-docker              # Start
```

---

## Storage layout

A single directory, `~/docker-code`:

```
~/docker-code/
├── claude/      ← the complete HOME of the Claude container
├── codex/       ← the complete HOME of the Codex container
├── gemini/  qwen/  mistral/  opencode/  cursor/  copilot/  kiro/
├── shared/      optional, mounted as ~/shared in every agent
├── models/      model weights shared by all agents
│   ├── ollama/  gguf/  hf/  litellm/
└── registry/    pull-through cache for Docker Hub
```

`~/docker-code/gemini/` **is** `/home/agent` in the Gemini container. Everything the tool creates - login, sessions, settings, MCP server, shell history - ends up there and survives every restart. On the host it is a normal folder: `ls`, `du`, `tar`, `rm`.

```bash
tar czf backup.tar.gz -C ~ docker-code     # Backup
rm -rf ~/docker-code/gemini                # Reset Gemini only
```

To use another location, set `export DOCKER_CODE_HOME=/absolute/path`.

---

## What a container sees

| reachable | not reachable |
|---|---|
| `~/docker-code/<agent>/` (rw) — its HOME | your real home directory |
| the directory from which you started it (rw) | any other path on the host |
| `~/docker-code/models/` (ro, only with `DOCKER_CODE_LOCAL=1`) | `/var/run/docker.sock` — **never** mounted |
| explicit extras via `DOCKER_CODE_MOUNT` | `~/.gitconfig`, `$SSH_AUTH_SOCK` (opt-in, off by default) |

Starting from the home directory or from `/` is **rejected**, not just criticized. `tests/isolation.bats` keeps this list as a negative assertion so that it doesn't grow unnoticed.

**Honestly:** The inner Docker daemon runs `privileged` by default because that's the only mode that works on all tested hosts - both on Linux and macOS. A privileged container is therefore **no security boundary to the host**. What is written above is a file system shield: your home and your credentials are excluded. It is not an outbreak protection. Whoever wants it: `DOCKER_CODE_DIND=0` (no inner daemon, no `--privileged`) and `DOCKER_CODE_NET=restricted`.

---

## Configuration

Everything via environment variable so that it composes itself with the wrapper. Prefix `DOCKER_CODE_`, for a single agent `DOCKER_CODE_<AGENT>_` (e.g. `DOCKER_CODE_CODEX_IMAGE`).

| variable | Default | Effect |
|---|---|---|
| `YOLO=1` | `0` | without authorization queries — the right flag for each tool |
| `NET=restricted` | `full` | Egress only to the tool's domains (iptables + ipset) |
| `NET=gateway` | | Egress only to the tool's domains, filtered by **name** in a proxy container ([EGRESS.md](docs/EGRESS.md)) |
| `NET=none` | | no network at all |
| `DIND=0` \| `rootless` \| `privileged` | `privileged` | inner docker daemon |
| `LOCAL=1` | `0` | use the common local models |
| `LOCAL_MODEL=<name>` | | which (`docker-code models list`) |
| `SHELL=1` | `0` | instead of the agent a bash in the container |
| `SHARED=1` | `0` | Mount `~/docker-code/shared` under `~/shared` |
| `MOUNT="/a:/a:ro /b:/b"` | | additional bind mounts |
| `ENV="GH_TOKEN,FOO"` | | pass through additional variables |
| `GITCONFIG=1` / `SSH=1` | `0` | Pass through `~/.gitconfig` (ro) or the SSH agent |
| `REGISTRY_MIRROR=1` | `0` | Pull-through cache before Docker Hub ([REGISTRY.md](docs/REGISTRY.md)) |
| `DRY_RUN=1` | `0` | output the `docker run` instead of executing it |

```bash
DOCKER_CODE_YOLO=1 DOCKER_CODE_NET=restricted claude-docker
DOCKER_CODE_SHELL=1 opencode-docker           # Inspect the container
DOCKER_CODE_DRY_RUN=1 qwen-docker             # Show what would happen
```

### Permanent, in the `.bashrc`

`DOCKER_CODE_<AGENT>_<SETTING>` overrides `DOCKER_CODE_<SETTING>`, which overrides the default. This applies to every setting in the table:

```bash
export PATH="$HOME/.local/bin:$PATH"

export DOCKER_CODE_QWEN_LOCAL=1               # Run Qwen locally
export DOCKER_CODE_QWEN_LOCAL_MODEL=qwen3:14b
export DOCKER_CODE_NET=restricted             # Restrict egress for every agent
export DOCKER_CODE_CODEX_NET=full             # Except Codex
```

The complete block for local models - including the variables that **don't** belong here because they would also affect sessions without local models - is in [LOCAL-MODELS.md](docs/LOCAL-MODELS.md#permanent-the-bashrc-block).

Check without starting anything:

```bash
DOCKER_CODE_DRY_RUN=1 qwen-docker
```

---

## Environment variables passed through

An explicit list, not a blanket copy: a Gemini container has nothing to do with the `ANTHROPIC_API_KEY` exported in your shell.

- **Per agent**: `AGENT_ENV_VARS` in `agents/<id>/agent.env` — for example, `ANTHROPIC_API_KEY` for Claude,
  `OPENAI_*` for Codex and Qwen, `GH_TOKEN` for Copilot.
- **For all**: `TERM`, `COLORTERM`, `TZ`, `LANG`, the proxy variables, `NODE_EXTRA_CA_CERTS`,
  `DO_NOT_TRACK`.
- **Additionally**: `DOCKER_CODE_ENV="MY_TOKEN,ANOTHER_ONE"`.

Only set variables are passed - an unset one remains unset inside, instead of overwriting a container default as an empty string.

---

## Local models in three lines

```bash
docker-code models up
docker-code models pull qwen2.5-coder:14b
DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen2.5-coder:14b qwen-docker
```

This means you don't have to adjust anything manually. If you still configure yourself and are asked for an **API key**: **`docker-code-local`**, for all endpoints. `docker-code models status` displays it along with the URLs. Everything else in [LOCAL-MODELS.md](docs/LOCAL-MODELS.md).

Claude Code, Codex, Qwen, Mistral Vibe, OpenCode, and Gemini CLI support local models. Cursor, Copilot, and Kiro use provider-hosted models and report that limitation when requested.

On the **GPU** instead of the CPU: NVIDIA is recognized, AMD is one line — `DOCKER_CODE_MODELS_GPU=rocm` passes the card through *and* takes the ROCm image. Both, including `HSA_OVERRIDE_GFX_VERSION` for cards that ROCm does not recognize by itself, are available under [GPU](docs/LOCAL-MODELS.md#gpu).

---

## Further documentation

- **[LOCAL-MODELS.md](docs/LOCAL-MODELS.md)** — the shared model store, Ollama and the gateway.
- **[REGISTRY.md](docs/REGISTRY.md)** — Images, tags and the pull-through cache.

```bash
docker-code list       # List available agents
docker-code doctor     # Show what is installed, valid, and built
docker-code help       # List all commands
```

---

## Updates

Two separate things, and therefore two commands: the **images** (a tool has a new version) and **docker-code itself** (an agent is added, a wrapper changes).

```bash
docker-code update            # Pull every image
docker-code update claude     # Pull one image
docker-code build claude      # Build locally instead of pulling

docker-code self-update       # Update docker-code, agent definitions, and wrappers
```

`self-update` knows where your installation comes from: `install.sh` stores this in `.install-source` when installing. An installation from the network gets the same branch again, one built with `--local` updates from exactly the checkout - no silent switching to GitHub. Move another stand:

```bash
docker-code self-update --ref v2
```

New agents bring with them a new wrapper; `self-update` creates the symlink and states the number of linked commands. After that, all that's missing is the image: `docker-code update <agent>` or `docker-code build <agent>`.

If you're working directly in checkout - the wrappers point there - `git pull` is the update, and `self-update` tells you that instead of pretending it did something.

The tools themselves are installed system-wide in the image, with the auto-updater switched off. A new image is the only way a new tool version will reach you - and it doesn't affect your `~/docker-code`: no new login, no lost sessions. The CI rebuilds when one of the tools releases a new version or the Ubuntu base image moves.

Uninstall without losing state:

```bash
install.sh --uninstall        # Remove commands and installation; keep ~/docker-code
```

---

## Development

```bash
bats tests/            # Entire suite, without a Docker daemon
./scripts/test.sh      # Same suite as CI, with a JUnit report
./scripts/build.sh     # Build the base and all agents locally
```

The suite runs in the `test` stage of `base/Dockerfile`, and `verified` refuses the image when it is red. Every agent image copies this stamp - so a red test blocks every agent, not just the one whose Dockerfile was currently touched.

This is possible thanks to the dry run seam: everything `bin/docker-code` does before the start is pure command construction, i.e. a function from the environment to an argv — testable without a daemon.
