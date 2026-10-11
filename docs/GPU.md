# The host's GPU in a session

Every session — `claude-docker`, `claude-docker-remote`, and the `compose.yml` from
`docker-code compose` or `/remote` — gets the host's GPU when there is one. Nothing to set: the
launcher looks before each start and passes on what it finds.

This is the GPU for the **agent's container**: for the code it writes and runs, the tests it starts,
a PyTorch or llama.cpp build it tries out. The shared Ollama has its own setting,
`DOCKER_CODE_MODELS_GPU` — see [Local models](LOCAL-MODELS.md#gpu).

## What is detected

| host | passed as | inside the session |
|---|---|---|
| NVIDIA, with the Container Toolkit's `nvidia` runtime registered in Docker | `--gpus all` | `nvidia-smi`, the CUDA driver libraries matching the host's kernel module |
| AMD, `/dev/kfd` present (amdgpu with KFD) | `--device /dev/kfd --device /dev/dri` | the ROCm compute and render nodes |
| anything else with `/dev/dri` — Intel, AMD without KFD | `--device /dev/dri` | the render nodes (VA-API, OpenCL, Vulkan, oneAPI) |
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

## Permissions inside

A device node keeps its host owner, and that owner is a group — `video`, `render` — whose number on
the host means nothing to the image. The agent does not run as root, so without that group ROCm and
Mesa get `Permission denied` and fall back to the CPU without saying much.

The entrypoint therefore adds the agent user to whichever group owns each passed node, creating the
group under the host's number when the image has none. The container log says so once:

```text
docker-code[claude]: GPU (amd): agent joined the device groups 992 44
```

Two cases it leaves alone: a node owned by group `0` (joining root's group is a different grant from
a GPU), and the overflow id a **rootless** host daemon shows for groups it cannot map. On rootless
Docker, a node only its group may open stays closed — `ls -l /dev/kfd /dev/dri` on the host shows
the mode; systemd's default rules often make the render nodes `0666`, and where they do not, a udev
rule on the host is the fix.

## Userspace

What the session gets is the device. What it needs on top depends on the vendor:

- **NVIDIA**: the runtime injects the driver libraries and `nvidia-smi`. CUDA toolkits and frameworks
  (`pip install torch`) come from the project, as anywhere else.
- **AMD / Intel**: only the device nodes. ROCm, Mesa or oneAPI come from the project — or, usually
  simpler, from a nested container: the inner Docker sees the same nodes, so
  `docker run --device /dev/kfd --device /dev/dri rocm/pytorch` works from inside the session.

The inner Docker has no NVIDIA runtime of its own, so `docker run --gpus` **inside** the session is
not available; CUDA work runs in the session itself.

## With docker compose

`docker-code compose` and `/remote` write the GPU into the file the way compose spells it:

```yaml
    # NVIDIA
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
on the host, or `/remote` in a new session.

## Checking it

```bash
docker-code attach claude-docker-remote_myproject   # or any session's shell: DOCKER_CODE_SHELL=1
nvidia-smi                                          # NVIDIA
ls -l /dev/kfd /dev/dri; id                         # AMD/Intel: nodes present, groups joined
```

| symptom | cause |
|---|---|
| no `--gpus`/`--device` in `DOCKER_CODE_DRY_RUN=1` output | nothing detected — NVIDIA without the Container Toolkit, Docker Desktop, a remote `DOCKER_HOST`; set `DOCKER_CODE_GPU` explicitly |
| `could not select device driver "" with capabilities: [[gpu]]` | `DOCKER_CODE_GPU=1` on a host without the NVIDIA runtime |
| `error gathering device information ... /dev/kfd` | `DOCKER_CODE_GPU=amd` on a host without amdgpu/KFD |
| nodes present, `Permission denied` | rootless host Docker, see [Permissions inside](#permissions-inside) |
