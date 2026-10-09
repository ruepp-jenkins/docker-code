---
name: remote
description: Create a compose.yml in the current project that keeps this agent running in the background with remote control on, so it can be driven from the vendor's web or mobile app and restarts with Docker. Use when the user types /remote, or asks for a compose file, a permanent or always-on remote session, or to run this session via docker compose. An optional argument is the session name.
---

# /remote — a compose.yml for a remote session

You run inside a docker-code container. The launcher on the host left a template for exactly this
session — same image, workspace, settings (network mode, egress gateway, YOLO, inner Docker, …) —
with the session name still open. The command `docker-code-compose` fills in the name and writes
`compose.yml` into the current directory. Under `DOCKER_CODE_NET=gateway` the file contains the
filtering proxy as a second service, so the session stays filtered.

## Steps

1. Take the session name from the user's arguments, if they gave one (`/remote my-project`).
   Without one, leave it out: the default is the name of the current directory, the same name
   `<agent>-docker-remote` would use here.

2. If `compose.yml` already exists in the workspace, show the user its first lines and ask before
   replacing it. Only then pass `--force`.

3. Run it from the workspace root:

   ```bash
   docker-code-compose [--force] ["<name>"]
   ```

   If it fails, report its message as it is; it says what to run on the host instead. Do not write
   a compose file by hand as a workaround: host paths, the image and the Docker store names are not
   visible from inside this container, and a guessed file starts a different session than the user
   asked for.

   The settings are those of this session. If the user wants different ones (another network mode,
   no YOLO, …), tell them to run `docker-code compose <agent>` on the host instead: it asks for them
   one by one and writes the same kind of file.

4. Tell the user what to do next, **on the host** in this directory (not in this container, which
   has no access to the host's Docker):

   ```bash
   docker compose up -d                        # starts it; it restarts with Docker and the host
   docker-code attach <container_name>         # into the TUI; Ctrl-P Ctrl-Q leaves it running
   docker compose down                         # stop and remove it
   ```

   `<container_name>` is printed by `docker-code-compose` and stands in the file.

5. Mention the points that commonly matter:
   - Variables listed without a value under `environment` (API keys, TERM, …) are taken from the
     shell that runs `docker compose up`. No secret is written into the file, so it is safe to
     commit — but it contains absolute host paths, so it is specific to this machine.
   - Remote control needs the vendor sign-in inside the agent's home; see docs/REMOTE.md of
     docker-code for the per-agent setup.
   - The same session can be started without compose with `<agent>-docker-remote`; both use the
     same container name, so only one of them runs at a time.

Do not run `docker compose` yourself: the Docker daemon inside this container is a different one
from the host's, and a session started there would end with this one.
