# GPU and browsers

Every session — `claude-docker`, `claude-docker-remote`, and the `compose.yml` from
`docker-code compose` or `/remote` — gets the host's GPU when there is one, and hands it on to the
containers the agent starts. Nothing to set: the launcher looks before each start and passes on what
it finds.

That second step is the point. Agents are told not to install toolchains but to run them in
containers, so a Playwright run, a PyTorch training or a browser game under test happens one level
further in — in a container *inside* the session. Both levels get the GPU, and both get a `/dev/shm`
large enough for a browser.

```text
host ── docker run --gpus all / --device /dev/kfd --device /dev/dri ──▶ session (agent)
                                                                         │
           docker run $DOCKER_CODE_GPU_ARGS mcr.microsoft.com/playwright ▼
                                                                    test container
```

The shared Ollama has its own GPU setting, `DOCKER_CODE_MODELS_GPU` — see
[Local models](LOCAL-MODELS.md#gpu).

- [What is detected](#what-is-detected)
- [Setting it](#setting-it)
- [Containers the agent starts](#containers-the-agent-starts)
- [Browsers and Playwright](#browsers-and-playwright)
- [Shared memory](#shared-memory)
- [With docker compose](#with-docker-compose)
- [Permissions](#permissions)
- [Checking it](#checking-it)

## What is detected

| host | session gets | inside the session |
|---|---|---|
| NVIDIA, with the Container Toolkit's `nvidia` runtime registered in Docker | `--gpus all`, capabilities `all` | `nvidia-smi`, CUDA, EGL and Vulkan libraries matching the host driver |
| AMD, `/dev/kfd` present (amdgpu with KFD) | `--device /dev/kfd --device /dev/dri` | the ROCm compute node and every render node |
| anything else with `/dev/dri` — Intel, AMD without KFD | `--device /dev/dri` | the render nodes |
| none of these | nothing | CPU |

Detection rather than a fixed request, because asking Docker for a GPU the host cannot provide is a
hard start error:

```text
docker: Error response from daemon: failed to discover GPU vendor from CDI: no known GPU vendor found
```

The device files are looked for on the machine that runs the launcher, which is the daemon's machine
only when the daemon is local. With **Docker Desktop** (its daemon runs in a VM without them) or a
**`DOCKER_HOST`** pointing at another machine, `auto` passes no device files; NVIDIA is still
recognized there, because that question goes to the daemon.

**Capabilities `all`** on NVIDIA, because the toolkit's default is `compute,utility`: CUDA works with
it, but the EGL and Vulkan libraries a browser or a game renders through stay outside, and Chromium
falls back to software without a word.

## Setting it

| `DOCKER_CODE_GPU` | Effect |
|---|---|
| *unset* / `auto` | as detected above — Default |
| `0` / `off` | no GPU, even when one is there |
| `1` / `nvidia` | `--gpus all`, detected or not — for a host wired up through CDI only, which has no `nvidia` runtime to detect |
| `amd` / `rocm` | `--device /dev/kfd --device /dev/dri` |
| `dri` / `intel` | `--device /dev/dri` |
| `device=0`, `2`, … | passed to `--gpus` unchanged: one card, or a number of them |

Like every session setting, it has a per-agent form:

```bash
export DOCKER_CODE_CODEX_GPU=0          # Codex without, everyone else as detected
DOCKER_CODE_GPU=device=1 claude-docker  # only the second NVIDIA card
DOCKER_CODE_DRY_RUN=1 claude-docker     # shows the --gpus / --device the session would get
```

## Containers the agent starts

Inside the session, `$DOCKER_CODE_GPU_ARGS` is what `docker run` needs to hand the GPU on. The agents'
instruction files tell them to use it; by hand it is the same:

```bash
echo "$DOCKER_CODE_GPU: $DOCKER_CODE_GPU_ARGS"
# amd: --device /dev/kfd --device /dev/dri/renderD128

docker run --rm $DOCKER_CODE_GPU_ARGS rocm/pytorch python -c 'import torch; print(torch.cuda.is_available())'
```

Unquoted, because it is several arguments. What it contains:

| `DOCKER_CODE_GPU` | `DOCKER_CODE_GPU_ARGS` |
|---|---|
| `nvidia` | `--gpus all --env NVIDIA_DRIVER_CAPABILITIES=all` |
| `amd` | `--device /dev/kfd --device /dev/dri/renderD<n>` |
| `dri` | `--device /dev/dri/renderD<n>` |

plus `--group-add <gid>` for each group that owns a device node, so a container started with
`--user "$(id -u):$(id -g)"` can still open it ([Permissions](#permissions)).

**One render node, the biggest card.** A host with an integrated and a discrete GPU has two render
nodes, and Mesa opens the first it enumerates. On a Ryzen desktop with a Radeon card that is the
iGPU: a browser game renders on 2 GB of shared memory while a 16 GB card idles. So the node of the
card with the most VRAM is passed (amdgpu reports it per device), then the one the firmware booted
on. For every card instead: `--device /dev/dri` in place of the render node.

**What the session brings for this:**

- **NVIDIA**: the NVIDIA Container Toolkit is in the image, so the inner daemon understands `--gpus`.
  At every start the entrypoint describes the injected host driver as a CDI spec
  (`/var/run/cdi/nvidia.yaml`) — every start, because the spec names files of one driver version and
  the host may have updated. The driver itself cannot come from the image: it has to match the host's
  kernel module, so it is always the host's, injected by the host's toolkit.
- **AMD / Intel**: nothing to install in the session. The userspace — Mesa for OpenGL and Vulkan, ROCm
  for compute — belongs to the image that runs: the Playwright images ship Mesa, `rocm/*` images
  ship ROCm.

The inner daemon is `privileged` by default (`DOCKER_CODE_DIND`). Under `rootless`, NVIDIA containers
need the toolkit's cgroup handling switched off, which the entrypoint does; AMD and Intel nodes work
as long as the agent user may open them.

## Browsers and Playwright

Run Playwright from its image rather than installing browsers — the image carries the browsers and
the system libraries they need, Mesa included:

```bash
docker run --rm $DOCKER_CODE_GPU_ARGS -v "$PWD":/src -w /src --user "$(id -u):$(id -g)" \
  mcr.microsoft.com/playwright:v1.64.0-noble npx playwright test
```

Take the image tag matching the project's `@playwright/test` version.

**A GPU alone does not make headless Chromium use it.** Headless Chromium renders WebGL with
SwiftShader, a CPU implementation, unless it is told to go through the system's EGL:

```text
--use-angle=gl-egl --ignore-gpu-blocklist
```

In the project's Playwright config, for the tests that need it:

```ts
// playwright.config.ts
export default defineConfig({
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    {
      name: 'chromium-gpu',
      use: {
        ...devices['Desktop Chrome'],
        launchOptions: { args: ['--use-angle=gl-egl', '--ignore-gpu-blocklist'] },
      },
    },
  ],
});
```

```bash
docker run --rm $DOCKER_CODE_GPU_ARGS -v "$PWD":/src -w /src --user "$(id -u):$(id -g)" \
  mcr.microsoft.com/playwright:v1.64.0-noble npx playwright test --project=chromium-gpu
```

What that changes, measured with `mcr.microsoft.com/playwright:v1.64.0-noble` on a Ryzen 9 9950X3D
with a Radeon RX 9070 XT — the WebGL renderer the page sees:

| run with | `UNMASKED_RENDERER_WEBGL` |
|---|---|
| no flags, GPU passed or not | `ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device …), SwiftShader driver)` — **CPU** |
| flags, `--device /dev/dri` (every node) | `ANGLE (AMD, … radeonsi raphael_mendocino …)` — the **iGPU** |
| flags, `$DOCKER_CODE_GPU_ARGS` (one node) | `ANGLE (AMD, AMD Radeon RX 9070 XT (radeonsi gfx1201 …))` — the **card** |

Both `chromium-headless-shell` (Playwright's default for headless) and the full `chromium` behave the
same. Firefox and WebKit choose their GL path themselves; they get the device, and whether they use
it depends on their own build.

A test can check for itself and fail rather than silently measure the CPU:

```ts
const renderer = await page.evaluate(() => {
  const gl = document.createElement('canvas').getContext('webgl2');
  const info = gl?.getExtension('WEBGL_debug_renderer_info');
  return info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : 'no webgl';
});
expect(renderer).not.toContain('SwiftShader');
```

## Shared memory

Chromium passes rendered frames and IPC buffers through `/dev/shm`, and Docker's default of 64 MB is
what it runs out of first — as `Page crashed` in Playwright, or as tests that are merely slow,
depending on the page. Playwright's own Docker advice is `--ipc=host` or a larger `--shm-size`.

docker-code sets the size, at both levels:

| `DOCKER_CODE_SHM_SIZE` | Effect |
|---|---|
| *unset* | `2g` — Default |
| `512m`, `4g`, … | that size |
| `0` | Docker's default, 64 MB |

The session gets `--shm-size`, and its inner daemon runs with `--default-shm-size` of the same value,
so every container the agent starts has it without `--ipc=host` — which would hand a container the
session's shared memory as well. It is a ceiling, not an allocation: tmpfs uses what is written into
it.

## With docker compose

`docker-code compose` and `/remote` write all of this into the file the way compose spells it:

```yaml
    shm_size: "2g"
    # NVIDIA
    environment:
      - "NVIDIA_DRIVER_CAPABILITIES=all"
    deploy:
      resources:
        reservations:
          devices:
            - driver: "nvidia"
              count: all
              capabilities: ["gpu"]
```

```yaml
    # AMD / Intel
    devices:
      - "/dev/kfd"
      - "/dev/dri"
```

`device=0,2` becomes `device_ids`, a number becomes `count`. Other `--gpus` options — capabilities,
drivers — have no translation and are refused by name rather than half applied.

Detection happens when the file is written, on the machine that writes it. A file moved to a host with
a different GPU, or written before the card was installed, is written again: `docker-code compose`
on the host, or `/remote` in a new session. The nested side — `DOCKER_CODE_GPU_ARGS`, the CDI spec —
is worked out by the container at every start and needs nothing in the file.

## Permissions

A device node keeps its host owner, and that owner is a group — `video`, `render` — whose number on
the host means nothing to the image. The agent does not run as root, so without that group ROCm and
Mesa get `Permission denied` and fall back to the CPU without saying much.

The entrypoint therefore adds the agent user to whichever group owns each passed node, creating the
group under the host's number when the image has none, and puts the same numbers into
`DOCKER_CODE_GPU_ARGS` as `--group-add`. The container log says so once:

```text
docker-code[claude]: GPU (amd): agent joined the device groups 987 983
```

Two cases it leaves alone: a node owned by group `0` (joining root's group is a different grant from
a GPU), and the overflow id a **rootless** host daemon shows for groups it cannot map. On rootless
Docker, a node only its group may open stays closed — `ls -l /dev/kfd /dev/dri` on the host shows
the mode; systemd's default rules often make the render nodes `0666`, and where they do not, a udev
rule on the host is the fix.

## Checking it

```bash
DOCKER_CODE_DRY_RUN=1 claude-docker | tr ' ' '\n' | grep -A1 -E 'gpus|device|shm'   # on the host

# in the session
echo "$DOCKER_CODE_GPU: $DOCKER_CODE_GPU_ARGS"
nvidia-smi                                   # NVIDIA
ls -l /dev/kfd /dev/dri; id                  # AMD/Intel: nodes present, groups joined
df -h /dev/shm                               # 2.0G, not 64M
docker run --rm $DOCKER_CODE_GPU_ARGS alpine df -h /dev/shm   # the same one level further in
```

| symptom | cause |
|---|---|
| no `--gpus`/`--device` in the dry run | nothing detected — NVIDIA without the Container Toolkit, Docker Desktop, a remote `DOCKER_HOST`; set `DOCKER_CODE_GPU` explicitly |
| `DOCKER_CODE_GPU_ARGS` empty in the session | the session was started without a GPU, or by a docker-code older than its image |
| WebGL renderer says `SwiftShader` | the Chromium flags are missing, or the container was started without `$DOCKER_CODE_GPU_ARGS` |
| renderer names the iGPU | the container got `--device /dev/dri` instead of `$DOCKER_CODE_GPU_ARGS` |
| `could not select device driver "" with capabilities: [[gpu]]` | `DOCKER_CODE_GPU=1` on a host without the NVIDIA runtime — or, inside the session, an image built before the toolkit was added |
| `error gathering device information ... /dev/kfd` | `DOCKER_CODE_GPU=amd` on a host without amdgpu/KFD |
| `Page crashed` / `Target crashed` in Playwright | `/dev/shm` too small — `DOCKER_CODE_SHM_SIZE=0` set, or a container started with its own `--shm-size` |
| nodes present, `Permission denied` | rootless host Docker, see [Permissions](#permissions) |
