# Remote control

Three of the agents can be driven from their vendor's web or mobile app while they run in a
docker-code container: you start a task at the desk and answer its questions from your phone. The
agent keeps running here, with this container's workspace, tools and network policy; the app is a
window onto it.

| Agent | Driven from | Sign-in it needs | Status upstream |
|---|---|---|---|
| Claude Code | [claude.ai/code](https://claude.ai/code), Claude app (iOS, Android) | claude.ai subscription (Pro, Max, Team, Enterprise) | generally available |
| GitHub Copilot CLI | github.com, GitHub Mobile | GitHub account with Copilot | generally available |
| OpenAI Codex CLI | ChatGPT app | ChatGPT account with Codex access | experimental from the CLI |

Each of the three has a command of its own for it, next to the normal one:

```bash
claude-docker-remote      codex-docker-remote      copilot-docker-remote
```

It starts the agent **in the background with remote control switched on**, takes the same arguments
and settings as the normal wrapper, and leaves that one untouched — `claude-docker` stays a plain
session in your terminal.

Gemini CLI, Qwen Code, Mistral Vibe, OpenCode, Cursor and Kiro have no remote control, and so no
`-remote` command.

## How it works here

Every one of these connects **outbound** to its vendor, which relays between the app and the
session. No port is published, nothing on the host listens, and the network modes need no change:
under `NET=restricted` and `NET=gateway` the hosts these tools use are already on the allowlists.

The one thing remote control does need is a process that keeps running. A docker-code session ends
with its terminal, which is why the `-remote` commands start in the background and print the
container name:

```bash
$ cd ~/src/myproject
$ claude-docker-remote
claude-docker-remote: Claude Code is running in the background as claude-docker-remote_myproject.
```

A session that is already running gets there with **Ctrl-P Ctrl-Q**: the terminal is released, the
container keeps going. From then on:

```bash
docker-code sessions                                 # what is running, foreground or detached
docker-code attach claude-docker-remote_myproject    # back into the TUI (Ctrl-P Ctrl-Q leaves again)
docker stop claude-docker-remote_myproject           # end the session
```

### The session name

A remote session is named after the directory it was started in, or after `DOCKER_CODE_NAME`:

```bash
DOCKER_CODE_NAME="Release 2.0" claude-docker-remote
```

The name is used twice. Claude Code lists the session under it in the app (Copilot and Codex have no
name of their own to set, so for them it is only the container's). And the container is called
`<agent>-docker-remote_<name>`, lowercased and with everything but letters, digits, `-` and `_`
replaced — `claude-docker-remote_release-2-0` above.

One name is one session. Starting `claude-docker-remote` again in the same directory while it runs
is refused with the `attach` command to use instead; a second session for the same directory needs
a second name. Each named session has an inner Docker store of its own, so it does not compete with
the numbered sessions for theirs.

### It restarts by itself

A restarted Claude session continues the previous conversation in that directory (`--continue`, added
automatically once a transcript exists); the first start begins a new one.

A remote session in the background is started with Docker's restart policy `unless-stopped`: when
the agent exits, the Docker daemon restarts or the host reboots, it comes back on its own — with a
new conversation, since the old process is gone. `docker stop` ends it for good.

Because Docker refuses a restart policy together with `--rm`, a stopped session stays behind as a
stopped container. The next `claude-docker-remote` in that directory replaces it; `docker rm` removes
it by hand. `DOCKER_CODE_RESTART` sets another policy (`always`, `on-failure[:N]`) or `no`, which
brings back `--rm`. It only applies in the background; a session in the terminal ends with it.

The shared services follow suit only partly: the local models have their own `unless-stopped`, the
registry mirror and the `NET=gateway` proxy do not. After a reboot, a `NET=gateway` session comes
back without its gateway and so without a way out — it fails closed — until it is started again with
`claude-docker-remote`. The compose file below has no such gap: its gateway is a service of its own
and restarts with the session.

### With docker compose

The same session as a `compose.yml`, for those who manage their long-running containers that way:

```bash
cd ~/src/myproject
docker-code compose claude                   # asks, then writes ./compose.yml
docker compose up -d                         # start; restarts with Docker and the host
docker-code attach claude-docker-remote_myproject
docker compose down                          # stop and remove (-v would also delete its inner Docker store)
```

In a terminal, the command first shows the `DOCKER_CODE_*` settings exported in this shell and asks
whether the file should use them. Declined, or with none set, it asks for the ones that decide what
kind of session this is — name, network mode (and for `gateway` the policy and extra domains), YOLO,
inner Docker, restart policy:

```text
docker-code: docker-code settings in this shell:
docker-code:   DOCKER_CODE_YOLO=1
docker-code: Use them for the compose file? (y n) [y] n
docker-code: Session name? [myproject]
docker-code: Network? (full restricted gateway none) [full] gateway
docker-code: Gateway policy: only the agent's domains, or the internet minus the LAN? (allowlist open) [allowlist]
...
```

`--yes` skips the questions and takes the shell's settings as they are, which is also what happens
without a terminal; `--ask` asks even then. `--stdout` prints the file instead of writing it, and
`--force` replaces an existing `compose.yml`.

The file is generated from exactly the `docker run` that `claude-docker-remote` would execute with
those settings, so `DOCKER_CODE_YOLO`, `DIND`, `LOCAL`, `MOUNT`, the detected GPU
([GPU.md](GPU.md#with-docker-compose)) and the rest carry over, and the
container name is the same — compose and the command replace each other rather than running side by
side.

**`NET=gateway`** becomes a second service, `egress`, with the same squid policy the launcher would
generate, written into the file under `configs:`. The topology is the launcher's too: the session's
only network is `internal`, shared with the gateway alone, and only the gateway has a network with a
route out. The session starts once the gateway reports ready, and both restart together — unlike the
launcher's gateway, which `<agent>-docker-remote` sessions cannot bring back after a reboot.
`docker compose logs egress` shows what was allowed and refused. The policy is fixed when the file is
written; to change it, write the file again. `DOCKER_CODE_EGRESS_POOL` does not apply: the two
networks belong to the compose project and take their ranges from Docker.

What does not fit into a compose file is left out or refused, with a message:

- `REGISTRY_MIRROR=1` is left out: the mirror is started and stopped by docker-code sessions. The
  inner Docker pulls from Docker Hub.
- `LOCAL=1` works, but the model services have to be up: `docker-code models up` once.
- A flag in `DOCKER_CODE_RUN_ARGS` that has no translation is refused by name.

Variables passed through from your shell — API keys, `TERM`, proxies — appear in the file by name
only, and compose takes their values from the shell that runs `docker compose up`. No secret is
written into the project directory. The file does contain absolute host paths, so it belongs to this
machine.

#### From inside the agent: /remote

Claude Code, Codex and Copilot come with a skill for this, `remote`. It uses the settings of the
session it runs in, without questions — for others, `docker-code compose` on the host asks. In Claude Code `/remote` writes
the same `compose.yml` into the workspace, `/remote "Release 2.0"` with a name; Codex invokes it as
`$remote`, and Copilot and Codex also pick it up when asked for "a compose file for remote". Every session of these
agents leaves the template for its own settings in its home (`~/.docker-code/compose-*.yml`), and
the command `docker-code-compose` in the image fills in the name — the agent cannot run the launcher,
which is on the host. `docker compose up -d` is then yours to run, on the host.

The skill is seeded into `~/docker-code/<agent>/` on the next start, like the other defaults, and
never overwrites a skill of that name you already have.

The machine itself has to stay on and online. A detached session also keeps the shared services it
uses — the registry mirror, the egress gateways — running after it ends; the next foreground session
to end last switches them off, or `docker-code registry stop` and `docker-code egress stop` do.

Behind the command are two ordinary settings, for the rare case that the command does not fit:

- `DOCKER_CODE_REMOTE=1` switches remote control on, with each tool's own mechanism (each agent's
  section below says which).
- `DOCKER_CODE_DETACH=1` starts any session in the background, with or without remote control.
  `DOCKER_CODE_DETACH=0 claude-docker-remote` keeps a remote session in the terminal instead.

Neither belongs in a `.bashrc`: exported there, it would apply to every session of that agent.

---

## Claude Code

### Set up once

1. **Sign in with your claude.ai account**, inside the container:

   ```bash
   claude-docker auth login            # choose the claude.ai option
   ```

   The login is stored in `~/docker-code/claude/` and survives restarts. Remote Control refuses
   every other kind of credential, so none of these may reach the session:

   - `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` exported in your shell (docker-code passes both
     through when set) or an `apiKeyHelper` in the settings
   - `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`: that token may only make model requests
   - `DOCKER_CODE_LOCAL=1`, which points `ANTHROPIC_BASE_URL` at Ollama
   - `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` (or `DISABLE_GROWTHBOOK`), which also switches off
     the feature flag Remote Control depends on

2. **Team and Enterprise:** an owner has to enable Remote Control in the
   [Claude Code admin settings](https://claude.ai/admin-settings/claude-code) first.

3. **Trust the workspace** by starting `claude-docker` there once in the foreground. The server mode
   below cannot ask when nobody is attached.

4. Install the Claude app on the phone, signed in to the same account. `/mobile` inside Claude Code
   shows a QR code to the app store.

### Use

Three ways, all of them in a session that keeps running:

```bash
# An interactive session that is also reachable from the app (adds --remote-control)
claude-docker-remote

# Under another name than the directory's
DOCKER_CODE_NAME="docker-code" claude-docker-remote

# Server mode: no local conversation, sessions are started from the app
claude-docker-remote remote-control --name "docker-code"
```

In a session that is already running, `/remote-control` (or `/rc`) does the same — then
Ctrl-P Ctrl-Q, and the terminal is free. `/remote-control` a second time shows the URL and a QR code,
or disconnects.

On the phone or at [claude.ai/code](https://claude.ai/code), the session appears in the session list
with a computer icon and a green dot. Permission prompts are forwarded to the app, so a session
without `DOCKER_CODE_YOLO` stays usable from there.

To have every session connect without the setting, run `/config` and set **Enable Remote Control for
all sessions**, or put `"remoteControlAtStartup": true` into `~/docker-code/claude/.claude/settings.json`.

The session is listed under its [session name](#the-session-name) — the directory, or
`DOCKER_CODE_NAME`. A name typed after `--remote-control` yourself wins over both. Sessions started
from the app in server mode are named by Claude Code with a prefix, the hostname `claude-code` by
default; `CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX` is passed through to change that.

### When it does not connect

| Message | Cause |
|---|---|
| `Remote Control requires a claude.ai subscription.` | not signed in with claude.ai: `claude-docker auth login` |
| `Remote Control requires claude.ai subscription auth.` | an API key or token is set; the message names which one |
| `Workspace not trusted` | step 3 above |
| Remote Control does not appear at all | `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` or a foreign `ANTHROPIC_BASE_URL` |

Upstream documentation: [Remote Control](https://code.claude.com/docs/en/remote-control).

---

## GitHub Copilot CLI

### Set up once

1. **Sign in**, inside the container: start `copilot-docker` and run `/login`, or pass a token with
   `GH_TOKEN` / `GITHUB_TOKEN`, which docker-code forwards.
2. **Copilot Business and Enterprise:** an administrator has to enable the remote control and CLI
   policies first.
3. Install GitHub Mobile on the phone, signed in to the same account.

### Use

```bash
copilot-docker-remote
```

The command adds `--remote`. In a running session, `/remote on` does the same. The CLI
then shows a link and a QR code; `/remote` shows them again later.

Open the link, scan the code with GitHub Mobile, or find the session on github.com: a workspace that
is a GitHub repository lists it in that repository's **Agents** tab, any other directory under
[github.com/copilot/agents](https://github.com/copilot/agents). From there you can steer the running
turn, send new messages, switch modes and answer permission requests.

`--no-remote` on the command line wins over the `--remote` the command would add.

### When it does not connect

GitHub's allowlist reference names no hosts specific to remote control. If it works with `NET=full`
and not with `NET=restricted` or `NET=gateway`, look for the refused host in
`docker-code egress logs copilot` and add it with `DOCKER_CODE_ALLOW_DOMAINS`.

Upstream: [changelog announcing general availability](https://github.blog/changelog/2026-05-18-remote-control-for-copilot-cli-sessions-now-generally-available-on-mobile-web-and-vs-code/).

---

## OpenAI Codex CLI

**Experimental, and untested here beyond the daemon starting.** OpenAI's documented route to the
ChatGPT app starts pairing from the ChatGPT *desktop* app on macOS or Windows; the CLI commands below
are listed as experimental in the developer-commands reference, and that reference does not say where
in the ChatGPT app a pairing code is entered. Treat this section as a starting point.

### Set up once

1. **Sign in with your ChatGPT account**, inside the container: `codex-docker login`. An
   `OPENAI_API_KEY` is not an account sign-in; leave it unset for this.
2. Workspace admins may have to enable remote access for the workspace.

### Use

Remote control in Codex is not a flag on the TUI but a daemon, the shared app-server, which the TUI
joins by default:

```bash
codex-docker-remote
```

The command runs `codex remote-control start` before the TUI starts. If that fails — not
signed in, for example — the session prints a warning and starts anyway. Attach and pair the phone:

```bash
docker exec --user "$(id -u)" -e HOME=/home/agent codex-docker_1 codex remote-control pair
```

`pair` prints a short-lived code; run it again once it expires. The `--user` and `HOME` make the
command run as the session does, which is your own uid, so it finds that session's daemon rather than
starting a second one as root.

Without a TUI, `codex remote-control` runs the daemon in the foreground, which in a detached container
is the server mode:

```bash
codex-docker-remote remote-control
```

### When it does not connect

`Error: Remote control is enabled on codex-cli but the connection is errored.` means the daemon
started and could not reach or authenticate with OpenAI — in practice, a missing ChatGPT sign-in.
`pair` then fails with `remote control pairing is unavailable until enrollment completes`.

Upstream: [developer commands](https://learn.chatgpt.com/docs/developer-commands),
[remote connections](https://learn.chatgpt.com/docs/remote-connections).

---

## For agent maintainers

Two `agent.env` keys carry this, both applied by `image/launch.sh` only when `DOCKER_CODE_REMOTE=1`
and never in front of a subcommand from `AGENT_YOLO_SKIP`:

- `AGENT_REMOTE_ARGS` — flags prepended to the agent's arguments, unless the user typed the flag or
  its `--no-` form. A word `%n` becomes the session name as one argument, or is dropped without one.
- `AGENT_REMOTE_RESUME_ARGS` and `AGENT_REMOTE_RESUME_DIR` — on a restart the session rejoins its
  conversation: the flags are added only when the directory already holds a transcript, so the first
  start creates the session and every later one continues it. A resume flag the user typed
  (`-c`, `-r`, `--resume`, `--session-id`) wins.
- `AGENT_REMOTE_START` — a subcommand of `AGENT_BIN` run before the agent, for tools whose remote
  control is a daemon.

An agent that sets either of them gets `<wrapper>-remote` automatically: `agent_wrappers` in
`lib/agents.sh` and `wrapper_names` in `install.sh` derive it, and the checkout needs the symlink
`ln -s docker-code bin/<wrapper>-remote`, which `tests/registry.bats` asks for. It also needs the
`/remote` skill in its defaults, at the path its tool reads skills from — a copy of
`agents/claude/defaults/.claude/skills/remote/SKILL.md`, which `tests/lint.bats` compares.

See [Adding an agent](../ai/adding-an-agent.md).
