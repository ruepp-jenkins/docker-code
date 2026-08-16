# Project instructions

docker-code runs eight TUI coding agents (Claude Code, Codex, Gemini, Qwen, Mistral Vibe, OpenCode,
Cursor, and Copilot) in per-agent containers. Each agent has a persistent home directory under
`~/docker-code/`, and the containers share local-model services.

`AGENTS.md` is the canonical AI instruction file. Tool-specific instruction filenames at the
repository root are symbolic links to this file; do not maintain separate copies.

## Language

Everything written into this repository must be in English, including documentation, code comments,
identifiers, commit messages, PR descriptions, test names, errors, and log messages.

Some existing files and comments are still in German and are being migrated. Do not translate them
wholesale as a side effect of unrelated work. When modifying a section, write the changed or newly
added text in English.

## Commands

```bash
bats tests/                          # Entire suite; no Docker daemon needed
bats tests/models.bats               # One test file
bats tests/models.bats -f "GPU"      # One test selected by name regex
shellcheck --external-sources --source-path=. bin/docker-code lib/*.sh image/*.sh scripts/*.sh

./scripts/test.sh                    # CI parity: test stage plus JUnit report
./scripts/build.sh                   # Build the base image and every agent
./scripts/build.sh base claude       # Build selected targets

DOCKER_CODE_DRY_RUN=1 ./bin/qwen-docker  # Print the docker run argv
DOCKER_CODE_SHELL=1 ./bin/qwen-docker    # Open a container shell instead of the agent
./bin/docker-code doctor
./bin/docker-code list
./bin/docker-code models status
```

The first group requires `bats` and `shellcheck`. `./scripts/test.sh` requires Docker and runs the
same suite in the `test` stage of `base/Dockerfile`.

## Architecture

Changes generally belong to one of two sides:

- **Host side:** `bin/docker-code` and `lib/*.sh`. Before the final `exec`, this code constructs the
  `docker run` arguments from the environment. `DOCKER_CODE_DRY_RUN=1` exposes that boundary, which
  lets the test suite exercise the launcher with a stubbed `docker` and no daemon.
- **Container side:** `image/*.sh`. This entrypoint chain reads `/etc/docker-code/agent.env` at
  runtime and does not know individual tools by name. `entrypoint.sh` runs as root and prepares the
  user, defaults, inner Docker daemon, firewall, and port bridge. `user-init.sh` starts rootless
  Docker as `agent`. `launch.sh` assembles the agent arguments and executes the tool as `agent`.

This boundary affects observability: `AGENT_LOCAL_ENV` is expanded on the host and appears in a dry
run, while `AGENT_LOCAL_ARGS` is applied by `launch.sh` in the container and does not.

### Agent registry

`agents/<id>/agent.env` is the only registry of supported agents. Wrappers, the installer, CI build
matrix, and tests all discover agents from those files. `lib/agents.sh` reads the files as data rather
than sourcing them, and rejects unknown keys with a line number.

For the complete workflow and `agent.env` schema, read [Adding an agent](ai/adding-an-agent.md) before
adding an agent or changing the registry contract.

### Configuration resolution

Every session setting must use `agent_knob NAME [default]` in `bin/docker-code`:

```text
DOCKER_CODE_<AGENT>_<NAME> > DOCKER_CODE_<NAME> > default
```

Reading a setting directly from the environment silently breaks the per-agent override. The lint
tests compare the README setting table with `agent_knob` usage.

### Shared services

`lib/models.sh` starts one Ollama service and one LiteLLM service with fixed names on
`docker-code-net`, allowing sessions to reuse them. Failures degrade to a warning and a session
without local models. `lib/mirror.sh` follows the same pattern for the Docker Hub pull-through
cache. `image/local-models.sh` forwards container-local ports `11434` and `4000` because some agents
hard-code localhost. See [Local models](docs/LOCAL-MODELS.md) and
[Registry and image tags](docs/REGISTRY.md).

## Project constraints

- Never install an agent into `/home/agent` in a Dockerfile. The first real start replaces that path
  with a bind mount. Redirect installers elsewhere; see `agents/cursor/Dockerfile` and
  `agents/mistral/Dockerfile`.
- Documentation is tested. Behavioral changes often require a matching documentation change. Tests
  validate, among other things, documented GPU values, API-key names, setting resolution, and AMD
  configuration.
- Comments should explain why a choice exists, especially the failure or constraint that motivated
  it, rather than narrating the code.
- An agent installed from a package registry needs a `URLTriggerEntry` in `Jenkinsfile`, because
  self-updaters are disabled in the images. `tests/pipeline.bats` enforces this for npm packages.
- If an agent Dockerfile adds an apt repository, pin and verify the signing-key fingerprint. See
  `agents/claude/Dockerfile`.

## Task-specific instructions

Keep detailed procedures out of the always-loaded context. Read the relevant file before performing
one of these tasks:

- [Adding an agent](ai/adding-an-agent.md) — create an `agents/<id>/` entry, define `agent.env`, build
  its Dockerfile, add defaults, and wire package-release CI triggers.
