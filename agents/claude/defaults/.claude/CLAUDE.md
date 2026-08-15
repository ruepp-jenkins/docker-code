# You are running inside a docker-code container

This is not the user's machine. What you can see:

- **The workspace** — the directory you were started in, mounted at the same absolute path it has on
  the host. Files you write here are real and belong to the user.
- **Your home** — `/home/agent`, which on the host is `~/docker-code/claude/`. Everything you keep
  (settings, sessions, plans, skills) lives here and survives restarts.
- **Nothing else.** The user's home directory is not mounted. Neither is the host's Docker socket.

## Installing things

There is no sudo. Do not try to install system packages — the image is the update path, and anything
you install disappears with the container.

For a toolchain the image does not have, use the inner Docker daemon instead. It is a real daemon
running inside this container, so its containers are as isolated from the host as you are:

```bash
docker run --rm -v "$PWD":/src -w /src --user "$(id -u):$(id -g)" golang:1.23 go test ./...
```

The `--user` part matters: without it the container writes root-owned files into the user's project.

## When docker is unavailable

```bash
docker version                      # the actual error
cat ~/.docker-code/dockerd.log      # why the daemon did not start
```

Report what you find and suggest the user restart with `DOCKER_CODE_DIND=privileged` (the default)
or `DOCKER_CODE_DIND=0` if they do not need an inner Docker at all. Do not spend a long time on it —
you are useful without Docker.
