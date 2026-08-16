# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

docker-code runs eight TUI coding agents (Claude Code, Codex, Gemini, Qwen, Mistral Vibe, OpenCode,
Cursor, Copilot) in per-agent containers, each with a persistent home directory under
`~/docker-code/`, plus shared local-model services every agent reaches.

## Commands

```bash
bats tests/                          # whole suite; no Docker daemon needed
bats tests/models.bats               # one file
bats tests/models.bats -f "GPU"      # one test, by regex on its name
shellcheck --external-sources --source-path=. bin/docker-code lib/*.sh image/*.sh scripts/*.sh

./scripts/test.sh                    # CI parity: suite inside the base image build + JUnit report
./scripts/build.sh                   # base, then every agent
./scripts/build.sh base claude       # only these

DOCKER_CODE_DRY_RUN=1 ./bin/qwen-docker            # the main dev loop: print the docker run argv
DOCKER_CODE_SHELL=1 ./bin/qwen-docker              # a shell in the container instead of the agent
./bin/docker-code doctor | list | models status
```

`bats` and `shellcheck` have to be installed for the first block; `./scripts/test.sh` needs only
Docker, because it runs the same suite inside `base/Dockerfile`'s `test` stage.

## Architecture

**Two sides, and knowing which one a change belongs to is the recurring question.**

*Host side* — `bin/docker-code` plus `lib/*.sh`. Everything it does before the final `exec` is pure
command construction: environment in, `docker run` argv out. That seam is what `DOCKER_CODE_DRY_RUN=1`
exposes and what lets the suite test the launcher against a stubbed `docker` with no daemon.

*Container side* — `image/*.sh`, an entrypoint chain that reads `/etc/docker-code/agent.env` at
runtime and knows no tool by name:

| | runs as | does |
|---|---|---|
| `entrypoint.sh` | root | match container user to host user, seed the home, inner dockerd, firewall, port bridge |
| `user-init.sh` | `agent` | the rootless dockerd, which root cannot start |
| `launch.sh` | `agent` | assemble argv (YOLO flags, local-model args), `exec` the tool |

The split matters when wiring a feature: `AGENT_LOCAL_ENV` is expanded host-side and *is* visible in
a dry run; `AGENT_LOCAL_ARGS` is applied by `launch.sh` inside the container and is *not*.

**The agent registry.** `agents/<id>/agent.env` is the only place agents are enumerated — wrappers,
`install.sh`, the CI matrix and the tests all derive from it, so adding a tool is a folder plus a
symlink in `bin/`. `lib/agents.sh` *reads* those files rather than sourcing them: an unknown key is
an error with a line number. See [AGENTS.md](AGENTS.md) for every key; the required trio is
`AGENT_ID` (= directory name), `AGENT_BIN`, `AGENT_WRAPPER` (must end in `-docker`, must differ from
`AGENT_BIN`).

**Knob resolution.** Every session switch goes through `agent_knob NAME [default]` in
`bin/docker-code`: `DOCKER_CODE_<AGENT>_<NAME>` beats `DOCKER_CODE_<NAME>` beats the default. Reading
an environment variable directly silently breaks the per-agent form — `tests/lint.bats` checks every
knob in the README's table against `agent_knob` for exactly that reason.

**Shared services.** `lib/models.sh` starts one Ollama and one LiteLLM under fixed names on
`docker-code-net`, so a second session finds the first one's rather than starting its own; every
failure there degrades to a warning and a session without local models. `lib/mirror.sh` is the same
idea for the Docker Hub pull-through cache. `image/local-models.sh` forwards `localhost:11434` and
`:4000` into the session, because several of these CLIs hard-code localhost below their config
surface. Details in [LOCAL-MODELS.md](LOCAL-MODELS.md) and [REGISTRY.md](REGISTRY.md).

## Constraints that bite

- **Never install into `/home/agent`** in an agent Dockerfile. The bind mount replaces that directory
  on the first real start and the tool would be gone. Redirect the installer instead —
  `agents/cursor/Dockerfile` uses `HOME=/opt/cursor`, `agents/mistral/Dockerfile` sets `PIPX_HOME`
  and `PIPX_BIN_DIR`.
- **The docs are tested.** Several tests assert agreement between prose and code: the GPU values
  `LOCAL-MODELS.md` offers must exist as branches in `lib/models.sh`, the API key it names must be
  the one in the code, the README knob table must resolve through `agent_knob`, the AMD knobs it
  documents must be read somewhere. A behavior change usually needs a doc edit in the same commit.
- **Prose is German, code comments are English.** `README.md`, `AGENTS.md`, `LOCAL-MODELS.md` and
  `REGISTRY.md` are written for users in German; comments in `bin/`, `lib/`, `image/`, `scripts/` and
  `tests/` are English. Match whichever you are editing.
- **Comments carry the "why".** This codebase explains reasoning, not mechanics, and often names the
  failure that motivated a line. Keep that density when editing.
- **CI rebuild triggers.** A tool installed from a package registry needs a `URLTriggerEntry` in the
  `Jenkinsfile` (npm: `$.version`, PyPI: `$.info.version`), since the tools' own auto-updaters are
  switched off in the images. `tests/pipeline.bats` enforces this for npm packages.
