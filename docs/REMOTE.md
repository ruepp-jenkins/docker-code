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

Gemini CLI, Qwen Code, Mistral Vibe, OpenCode, Cursor and Kiro have no remote control.
`DOCKER_CODE_REMOTE=1` says so for them and starts the session anyway.

## How it works here

Every one of these connects **outbound** to its vendor, which relays between the app and the
session. No port is published, nothing on the host listens, and the network modes need no change:
under `NET=restricted` and `NET=gateway` the hosts these tools use are already on the allowlists.

The one thing remote control does need is a process that keeps running. A docker-code session ends
with its terminal, so there are two ways to keep it alive:

```bash
DOCKER_CODE_DETACH=1 claude-docker     # start in the background; prints the container name
```

or press **Ctrl-P Ctrl-Q** in a session that is already running — the terminal is released, the
container keeps going. From then on:

```bash
docker-code sessions                   # what is running, foreground or detached
docker-code attach claude-docker_1     # back into the TUI (Ctrl-P Ctrl-Q leaves again)
docker stop claude-docker_1            # end the session
```

The machine itself has to stay on and online. A detached session also keeps the shared services it
uses — the registry mirror, the egress gateways — running after it ends; the next foreground session
to end last switches them off, or `docker-code registry stop` and `docker-code egress stop` do.

`DOCKER_CODE_REMOTE=1` switches remote control on at start, with each tool's own mechanism. Like
every setting it has a per-agent form, so this belongs in a `.bashrc` without touching the others:

```bash
export DOCKER_CODE_CLAUDE_REMOTE=1
```

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
# An interactive session that is also reachable from the app
DOCKER_CODE_DETACH=1 DOCKER_CODE_REMOTE=1 claude-docker

# Name it, so you find it in the list on the phone
DOCKER_CODE_DETACH=1 claude-docker --remote-control "docker-code"

# Server mode: no local conversation, sessions are started from the app
DOCKER_CODE_DETACH=1 claude-docker remote-control --name "docker-code"
```

In a session that is already running, `/remote-control` (or `/rc`) does the same — then
Ctrl-P Ctrl-Q, and the terminal is free. `/remote-control` a second time shows the URL and a QR code,
or disconnects.

On the phone or at [claude.ai/code](https://claude.ai/code), the session appears in the session list
with a computer icon and a green dot. Permission prompts are forwarded to the app, so a session
without `DOCKER_CODE_YOLO` stays usable from there.

To have every session connect without the setting, run `/config` and set **Enable Remote Control for
all sessions**, or put `"remoteControlAtStartup": true` into `~/docker-code/claude/.claude/settings.json`.

Session names default to the container's hostname, `claude-code`, which is the same for every
session. `CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX` is passed through to change that.

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
DOCKER_CODE_DETACH=1 DOCKER_CODE_REMOTE=1 copilot-docker
```

`DOCKER_CODE_REMOTE=1` adds `--remote`. In a running session, `/remote on` does the same. The CLI
then shows a link and a QR code; `/remote` shows them again later.

Open the link, scan the code with GitHub Mobile, or find the session on github.com: a workspace that
is a GitHub repository lists it in that repository's **Agents** tab, any other directory under
[github.com/copilot/agents](https://github.com/copilot/agents). From there you can steer the running
turn, send new messages, switch modes and answer permission requests.

`--no-remote` on the command line wins over `DOCKER_CODE_REMOTE=1`.

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
DOCKER_CODE_DETACH=1 DOCKER_CODE_REMOTE=1 codex-docker
```

`DOCKER_CODE_REMOTE=1` runs `codex remote-control start` before the TUI starts. If that fails — not
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
DOCKER_CODE_DETACH=1 codex-docker remote-control
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
  its `--no-` form.
- `AGENT_REMOTE_START` — a subcommand of `AGENT_BIN` run before the agent, for tools whose remote
  control is a daemon.

See [Adding an agent](../ai/adding-an-agent.md).
