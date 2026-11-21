<!-- docker-code:begin — managed by the image and rewritten on every start; write your own notes outside this block -->
# You are running inside a docker-code container

This is not the user's machine. What you can see:

- **The workspace** — the directory you were started in, mounted at the same absolute path it has on
  the host. Files you write here are real and belong to the user.
- **Your home** — `/home/agent`, which on the host is `~/docker-code/opencode/`. Everything you keep
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

## Do not kill the inner Docker daemon

The inner Docker daemon is a process of this very container, and nothing restarts it: if it dies,
every `docker` command fails with "Cannot connect to the Docker daemon" until the user restarts the
whole container. You run as root in the same process namespace, so it is easy to kill by accident.

- Never run `pkill`, `killall` or `kill` with a pattern or a wildcard (`pkill -f docker`, `killall node`,
  `kill -9 -1`). Look up the PID of the one process you mean and kill only that.
- Never touch `dockerd`, `containerd`, `containerd-shim` or `docker-init`, and never stop, restart or
  reconfigure the daemon (`service docker …`, `systemctl …`, editing `daemon.json`, a second `dockerd`).
- Do not start containers with `--pid=host`, `--network=host`, `--cgroupns=host` or `--privileged`
  unless the task cannot be done otherwise. They share this container's processes, network rules and
  cgroups, so a cleanup or an `iptables` flush inside one reaches the daemon too.
- Clean up by name or label, not wholesale: `docker rm -f <name>`, not `docker rm -f $(docker ps -aq)`,
  and no `docker system prune` or `docker volume prune` unless the user asked for it.
- Limit what a test container may use (`--memory`, `--cpus`, `--pids-limit`) and remove it afterwards
  (`--rm`), so a runaway one cannot exhaust this container's memory or process table.
- If `docker` stops answering ("Cannot connect to the Docker daemon"), first check `pgrep -x dockerd`.
  A dead daemon can be started again without restarting the container, and this is the only
  way you may start one. Run it once, then wait up to 30 seconds for `docker info`:

  ```bash
  rm -f /var/run/docker.pid /var/run/docker.sock   # a killed dockerd leaves a zombie and a stale pid file
  args=(--host=unix:///var/run/docker.sock --group docker)
  [ -z "${DOCKER_CODE_SHM_SIZE:-}" ] || args+=(--default-shm-size "${DOCKER_CODE_SHM_SIZE}")
  if [ -n "${DOCKER_CODE_MIRROR_URL:-}" ]; then
      args+=(--registry-mirror "${DOCKER_CODE_MIRROR_URL}")
      case "${DOCKER_CODE_MIRROR_URL}" in http://*) m="${DOCKER_CODE_MIRROR_URL#http://}"; args+=(--insecure-registry "${m%%/*}") ;; esac
  fi
  for h in ${DOCKER_CODE_INSECURE_REGISTRIES//,/ }; do args+=(--insecure-registry "$h"); done
  if [ -n "${DOCKER_CODE_PROXY:-}" ]; then
      export HTTP_PROXY="${DOCKER_CODE_PROXY}" HTTPS_PROXY="${DOCKER_CODE_PROXY}" NO_PROXY="localhost,127.0.0.1"
  fi
  setsid nohup dockerd "${args[@]}" >>"$HOME/.docker-code/dockerd.log" 2>&1 </dev/null &
  ```

  This applies to `DOCKER_CODE_DIND=privileged` (the default). With `rootless` the daemon is not
  `dockerd` in this namespace, and with `0` there is none: do not start one, report it instead.
  Tell the user that the daemon died and was restarted, and read the end of
  `~/.docker-code/dockerd.log` for the reason. If it does not come back, stop and ask the user to
  restart the container.

## When docker is unavailable

```bash
docker version                      # the actual error
cat ~/.docker-code/dockerd.log      # why the daemon did not start
```

Report what you find and suggest the user restart with `DOCKER_CODE_DIND=privileged` (the default)
or `DOCKER_CODE_DIND=0` if they do not need an inner Docker at all. Do not spend a long time on it —
you are useful without Docker.
<!-- docker-code:end -->
