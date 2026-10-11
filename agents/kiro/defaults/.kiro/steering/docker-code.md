---
inclusion: always
---

# You are running inside a docker-code container

This is not the user's machine. What you can see:

- **The workspace** — the directory you were started in, mounted at the same absolute path it has on
  the host. Files you write here are real and belong to the user.
- **Your home** — `/home/agent`, which on the host is `~/docker-code/kiro/`. Everything you keep
  (settings, sessions, plans, skills) lives here and survives restarts.
- **Nothing else.** The user's home directory is not mounted. Neither is the host's Docker socket.

## Installing things

There is no sudo. Do not try to install system packages — the image is the update path, and anything
you install disappears with the container.

For a toolchain the image does not have, use the inner Docker daemon instead. It is a real daemon
running inside this container, so its containers are as isolated from the host as you are:

```bash
docker run --rm -v "$PWD":/src -w /src --user "$(id -u):$(id -g)" mcr.microsoft.com/dotnet/sdk:8.0 dotnet test
```

The `--user` part matters: without it the container writes root-owned files into the user's project.

## GPU and browsers in containers

When the host has a GPU, this session has it too, and `$DOCKER_CODE_GPU_ARGS` holds what `docker run`
needs to hand it on to a container (unset or empty: there is no GPU). Containers also get a
`/dev/shm` large enough for a browser by default, so `--ipc=host` and `--shm-size` are not needed.

```bash
echo "$DOCKER_CODE_GPU ${DOCKER_CODE_GPU_ARGS:-no GPU}"
docker run --rm $DOCKER_CODE_GPU_ARGS -v "$PWD":/src -w /src --user "$(id -u):$(id -g)" \
  mcr.microsoft.com/playwright:v1.64.0-noble npx playwright test
```

Keep `$DOCKER_CODE_GPU_ARGS` unquoted — it is several arguments. Use the Playwright image whose
version matches the project's `@playwright/test`.

Headless Chromium renders WebGL in software (SwiftShader) unless told otherwise, even with a GPU.
For games, canvas or WebGL tests, launch it with these arguments — set them in the project's
Playwright config (`use.launchOptions.args`) only for runs that need them:

```text
--use-angle=gl-egl --ignore-gpu-blocklist
```

`chrome://gpu` or a WebGL `UNMASKED_RENDERER_WEBGL` query names the GPU actually used; `SwiftShader`
there means software. AMD and Intel need Mesa in the image (the Playwright images have it); NVIDIA's
libraries are injected by `--gpus`.

## When docker is unavailable

```bash
docker version                      # the actual error
cat ~/.docker-code/dockerd.log      # why the daemon did not start
```

Report what you find and suggest the user restart with `DOCKER_CODE_DIND=privileged` (the default)
or `DOCKER_CODE_DIND=0` if they do not need an inner Docker at all. Do not spend a long time on it —
you are useful without Docker.
