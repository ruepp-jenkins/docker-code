# Local models

One model store serves all agents. Nine separate copies of a 9 GB model would consume 81 GB; here the model is stored once under `~/docker-code/models/`, and every container uses the same daemon.

All examples on this page use **`qwen3:14b`** (~9 GB, suitable for a 16 GB GPU) and are intended to work as written: copy, paste, run.

---

## The access data

This is the part you need when configuring by hand:

| | URL | API-Key |
|---|---|---|
| **Ollama** — OpenAI-Format | `http://localhost:11434/v1` | `docker-code-local` |
| **Ollama** — Anthropic-Format | `http://localhost:11434` | `docker-code-local` |
| **LiteLLM-Gateway** — Gemini-Format | `http://localhost:4000` | `docker-code-local` |
| **LiteLLM-Gateway** — OpenAI-Format | `http://localhost:4000/v1` | `docker-code-local` |

**The key is `docker-code-local` everywhere.**

It is not a secret: it authenticates a container to a gateway on a private Docker network without a published port. LiteLLM requires it, returning `401` when it is missing and `400` when it is wrong.

Ollama does not validate the key, but most tools require a non-empty value. Using `docker-code-local` consistently avoids needless differences.

Change it through `LOCAL_API_KEY` in `lib/models.sh`, then run `docker-code models restart`.

---

## Quick start

```bash
docker-code models up
docker-code models pull qwen3:14b
docker-code models list
```

The first pull loads ~9 GB. Then, in the project directory:

```bash
export DOCKER_CODE_LOCAL=1
export DOCKER_CODE_LOCAL_MODEL=qwen3:14b

qwen-docker          # Or codex-docker, gemini-docker, claude-docker,
                     # mistral-docker, opencode-docker
```

This means that **nothing has to be configured by hand** - the wrapper sets the URL, key and model name. Check what exactly arrives without starting anything:

```bash
DOCKER_CODE_DRY_RUN=1 DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3:14b qwen-docker
```

---

## Which model for an agent

Two different tasks, and the difference determines whether a session works:

- **Write code when asked** — any capable coding model can do this; `qwen3:14b` is good at it.
- **Work as an agent** — read files, execute commands, and evaluate results. This requires a model
  with **tool-call support**: the agent sends tools in the `tools` field and expects `tool_calls` in
  the response. Every tool in this project uses this mechanism.

A model without this training writes the function call as text in the response, the agent cannot execute it and displays raw JSON. **`qwen2.5-coder` belongs in this group** — it is a completion model, not an agent model, regardless of size.

| Model | Download | as an agent |
|---|---|---|
| `qwen3-coder:30b` | ~17GB | yes — the model that Qwen Code is built for. MoE with ~3 B active parameters, so fast as soon as it fits in the VRAM |
| `qwen3:14b` | ~8.6GB | yes — same size class as `qwen3:14b` |
| `qwen3:8b` | ~4.9GB | yes — if VRAM is low |
| `qwen2.5-coder:14b` | ~8.4GB | **no** — good for completion, useless as agent |

Its capability list says whether a model basically offers it:

```bash
docker exec docker-code-ollama ollama show qwen3:8b | grep -A4 Capabilities
#   completion / tools / insert / thinking
```

However, that is only half the information: `tools` is also there for models that do not adhere to the format in practice - the capability describes the prompt template, not the training. The reliable test is the call with real `tools`, see [The agent shows JSON](#if-something-doesnt-respond).

### Context window

The second silent reason for an agent doing nonsense: An agent sends a long system prompt plus the schemas of all the tools — quickly over 10,000 tokens, more than the 4k default window can even hold. What doesn't fit is eliminated, and the model works with what's left. The typical symptoms:

- invented tool names that are not in any schema
- "none of the provided tools can be used", although tools were sent along
- **Wildcard paths like `/path/to/project/`** instead of the real working directory — the model
  hasn't seen the surrounding block (anymore) and is guessing. The path in the session again
  doesn't help: it continues to fill the window instead of enlarging it.

The agent cannot stop this - there is no `num_ctx` via the OpenAI API, the window is determined by the server.

```bash
docker exec docker-code-ollama ollama ps      # CONTEXT column while a model is loaded
```

Ollama chooses the value according to available VRAM (4k/32k/256k). If it says `4096`, that's not enough for an agent:

```bash
export DOCKER_CODE_OLLAMA_ENV="OLLAMA_CONTEXT_LENGTH=32768"
docker-code models restart
```

More context costs VRAM — if `ollama ps` shows a CPU/GPU split afterwards, it was too much.

### How big and how much it costs

Two boundaries and the lower one wins.

**The model.** It doesn't accept more than its native window: `qwen3:8b` and `qwen3:14b` can do 40,960, `qwen3-coder:30b` can do 262,144. For the dense Qwen3 models, 32768 is almost the maximum - there it's not worth asking for more.

**The VRAM.** The KV cache grows linearly with the window and quickly becomes larger than the model itself:

```
KV-Cache = 2 × layers × KV heads × head_dim × 2 bytes × context
```

| Model | per 1000 tokens | 32k | 64k |
|---|---|---|---|
| `qwen3:14b` (40 layers, 8 KV heads) | ~160MB | ~5.0GB | above the model limit |
| `qwen3-coder:30b` (48 layers, 4 KV heads) | ~96MB | ~3.0GB | ~6.0GB |

What is actually proven is what Ollama says when loading:

```bash
docker logs docker-code-ollama 2>&1 | grep -E "KV buffer size|n_ctx_train"
#   llama_kv_cache: ROCm0 KV buffer size = 3072.00 MiB
#   print_info: n_ctx_train = 262144
```

Instead of increasing the window, the cheaper lever is usually worthwhile - a quantized KV cache halves (`q8_0`) or quarters (`q4_0`) the consumption:

```bash
export DOCKER_CODE_OLLAMA_ENV="OLLAMA_CONTEXT_LENGTH=65536 OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 OLLAMA_NUM_PARALLEL=1"
```

`OLLAMA_NUM_PARALLEL=1` so that Ollama does not multiply the window to multiple slots. And the quantization requires flash attention, which not every card on AMD can do: If the `KV buffer size` doesn't halve in the log, it hasn't worked.

Bigger is not automatically better - the hit rate of long contexts drops in the middle, and each round has to process the window first. An agent that opens targeted files performs better with 32-64k than one that fills 200k.

---

## Permanent: the `.bashrc` block

To copy to the end of `~/.bashrc` (under macOS `~/.zshrc`), then open a new shell:

```bash
# ---- docker-code -------------------------------------------------------------
export PATH="$HOME/.local/bin:$PATH"

# Local models for supported tools—configured per agent, not globally.
export DOCKER_CODE_QWEN_LOCAL=1
export DOCKER_CODE_QWEN_LOCAL_MODEL=qwen3:14b

export DOCKER_CODE_OPENCODE_LOCAL=1
export DOCKER_CODE_OPENCODE_LOCAL_MODEL=qwen3:14b

export DOCKER_CODE_CODEX_LOCAL=1
export DOCKER_CODE_CODEX_LOCAL_MODEL=qwen3:14b

# Claude and Gemini are intentionally omitted: they continue using their subscription or cloud key.
# To switch one invocation, use:
#     DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3:14b claude-docker
# ------------------------------------------------------------------------------
```

**Per agent instead of flat rate** is the point here. `DOCKER_CODE_LOCAL=1` set globally would also switch Claude Code to the local model - i.e. the exact agent for which you are probably paying a subscription. `DOCKER_CODE_<AGENT>_<KNOB>` beats `DOCKER_CODE_<KNOB>` beats the default, and that applies to **every** switch from the table in the README, not just these two.

If you want it everywhere:

```bash
export DOCKER_CODE_LOCAL=1
export DOCKER_CODE_LOCAL_MODEL=qwen3:14b
export DOCKER_CODE_CLAUDE_LOCAL=0      # One exception
```

### What *doesn't* belong here

```bash
# DO NOT put these in .bashrc:
export OPENAI_BASE_URL=http://localhost:11434/v1
export OPENAI_API_KEY=docker-code-local
```

These are variables that the wrapper **passes** through to `codex-docker` and `qwen-docker` — also to sessions that run *without* `DOCKER_CODE_LOCAL=1`. However, there is no redirection to `localhost:11434`, and the session runs into a connection error instead of to your cloud provider. Set the `DOCKER_CODE_*_LOCAL` switches above instead; The wrapper then sets the tool's own variables itself, and only if the bridge is in place.

They only make sense on the host if you run a tool *outside* of docker-code - but then with `127.0.0.1` and published ports, see [From Host](#from-the-host).

### Check whether it works

```bash
docker-code models status                  # Are services running, and what is the key?
DOCKER_CODE_DRY_RUN=1 qwen-docker          # Show OPENAI_BASE_URL/-MODEL without starting
DOCKER_CODE_DRY_RUN=1 claude-docker        # Show no docker-code-net and no ANTHROPIC_BASE_URL
```

---

## GPU

Without a GPU, a 14B model calculates on the CPU - it works, but is about an order of magnitude slower. Ollama doesn't decide this himself: the container gets the card passed through, or he doesn't get it.

Two manufacturers, two completely different ways into the container: NVIDIA via a container runtime that injects the card (`--gpus`), AMD via two device files that you submit yourself (`--device`) — plus a different image. That's why `DOCKER_CODE_MODELS_GPU` is not a switch, but a choice:

| `DOCKER_CODE_MODELS_GPU` | Effect |
|---|---|
| *unset* / `auto` | GPU only if Docker reports `nvidia` runtime — Default |
| `1` | Force `--gpus all` even if detection finds nothing |
| `device=0` | Bind to a specific NVIDIA card (passed unchanged to `--gpus`) |
| `rocm` | **AMD**: `--device /dev/kfd --device /dev/dri` **and** the image `ollama/ollama:rocm` |
| `0` | Force CPU |

All of this takes effect when **creating** the container, which is why `restart` recreates rather
than calling `docker restart`. So after each change:

```bash
DOCKER_CODE_MODELS_GPU=rocm docker-code models restart
```

The variable permanently belongs in the `.bashrc` — it is a setting of the model services, not the session, and therefore has **no** `DOCKER_CODE_<AGENT>_` form.

### NVIDIA on Linux

1. An NVIDIA driver on the **host** (not in the container). `nvidia-smi` must be running on the host.
2. The **NVIDIA Container Toolkit**, so that Docker can pass the card on at all:

```bash
# Debian/Ubuntu—configure the repository; consult NVIDIA documentation for the current command
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

3. Enough VRAM. Rule of thumb for `qwen2.5-coder` in standard quantization: `7b` ~5 GB, `14b` ~9 GB,
   `32b` ~20GB. If the model doesn't fit all the way in, Ollama will partially load it - then it's ready
   `ollama ps` something like `45%/55% CPU/GPU`, and the speed is in between.

Detected instead of accepted because requesting a GPU that doesn't exist is a **hard boot error**:

```
docker: Error response from daemon: failed to discover GPU vendor from CDI:
        no known GPU vendor found
```

The discovery sees the runtime registering the Container Toolkit. A host that is only wired via CDI has no such runtime - `auto` will not find anything there and you need `DOCKER_CODE_MODELS_GPU=1`.

---

### AMD on Linux (ROCm)

All the way in three lines — that's all it takes if the card is supported by ROCm:

```bash
docker-code models down
DOCKER_CODE_MODELS_GPU=rocm docker-code models up
docker-code models status          # Must report "computing on rocm"
```

`rocm` sets **both** at once, and both are necessary:

```
--device /dev/kfd --device /dev/dri      pass the GPU into the container
ollama/ollama:rocm                       image containing the ROCm libraries
```

That's the reason why `DOCKER_CODE_OLLAMA_IMAGE=ollama/ollama:rocm` alone doesn't help: without the two device files, the container doesn't see a map and continues to calculate on the CPU - without errors, just slowly. Vice versa: Devices without ROCm image are also CPU.

The ROCm image is a few GB larger than the default image; the first `models up` takes accordingly. If you want to nail down a specific version, overwrite it - `DOCKER_CODE_OLLAMA_IMAGE` beats the automatic, but the devices still remain set.

#### What the host needs

1. **The amdgpu kernel driver with KFD.** Both device files must exist:

```bash ls -l /dev/kfd /dev/dri/renderD* ```

If `/dev/kfd` is missing, ROCm is unresponsive — this is the normal case in WSL2 and in VMs without GPU passthrough. `lsmod | grep amdgpu` says whether the driver is loaded at all.

2. **No ROCm userspace.** The libraries are in the image; Nothing from AMD has to be on the host
   be installed. (`rocm-smi` is still handy, but it's just a monitoring tool.)

3. **A card that knows ROCm** — roughly: Vega (gfx900) and everything after that. Older maps (Polaris,
   RX 5xx) don't run, only the CPU remains there. What Ollama accepts is in his
   [GPU Documentation](https://github.com/ollama/ollama/blob/main/docs/gpu.md); Cards that are just off the mark
   saves `HSA_OVERRIDE_GFX_VERSION` (below).

4. **Enough VRAM**, same rule of thumb as NVIDIA: `7b` ~5GB, `14b` ~9GB, `32b` ~20GB. One
   iGPU calculates with what the BIOS allocates to it as UMA memory - there is the small version
   usually the only one that fits completely.

#### The variables

Four buttons, all for the Ollama container, all effective on the `models up`:

| variable | Example | Effect |
|---|---|---|
| `DOCKER_CODE_MODELS_GPU` | `rocm` | Devices + ROCm image, see above |
| `DOCKER_CODE_OLLAMA_IMAGE` | `ollama/ollama:<version>-rocm` | a specific image instead of `:rocm` |
| `DOCKER_CODE_OLLAMA_ENV` | `"HSA_OVERRIDE_GFX_VERSION=11.0.0"` | Environment **in** Ollama daemon, separated by spaces |
| `DOCKER_CODE_OLLAMA_ARGS` | `"--security-opt seccomp=unconfined"` | any other `docker run` arguments |

A complete block for the `.bashrc`, here for an RX 6700 XT:

```bash
export DOCKER_CODE_MODELS_GPU=rocm
export DOCKER_CODE_OLLAMA_ENV="HSA_OVERRIDE_GFX_VERSION=10.3.0"
```

Then `docker-code models restart` once, and each session takes the card.

#### `HSA_OVERRIDE_GFX_VERSION` — the button where it usually hangs

ROCm only serves a list of ISA versions. If your own card is not on it, Ollama skips it without comment and calculates on the CPU. The override tells ROCm a different version - it works reliably on cards of the same generation.

First check what the card really is:

```bash
# From the running container log—shows the gfx version and supported list
docker logs docker-code-ollama 2>&1 | grep -iE 'amdgpu|gfx|rocm'

# Or directly from the driver, without a container:
grep -r gfx_target_version /sys/class/kfd/kfd/topology/nodes/*/properties
#   100300 -> gfx1030 -> "10.3.0"        110000 -> gfx1100 -> "11.0.0"
#   100301 -> gfx1031 -> "10.3.0"        110300 -> gfx1103 -> "11.0.0"
```

The number is `major*10000 + minor*100 + step`; So `100301` is called gfx1031. The override is written in the same decomposition (`10.3.0`), but with the ISA of the **supported** neighbor card, not its own — gfx1031 masquerades as gfx1030. Common cases:

| map | ISA | `HSA_OVERRIDE_GFX_VERSION` |
|---|---|---|
| RX 7900 XTX/XT/GRE | gfx1100 | not necessary |
| RX 7800 XT / 7700 XT | gfx1101 | usually not necessary, otherwise `11.0.0` |
| RX 7600 (XT) | gfx1102 | `11.0.0` |
| RX 6800 / 6900 / 6950 XT | gfx1030 | not necessary |
| RX 6700 (XT) / 6750 XT | gfx1031 | `10.3.0` |
| RX 6600 (XT) / 6650 XT | gfx1032 | `10.3.0` |
| RX 6500 XT / 6400 | gfx1034 | `10.3.0` |
| Radeon 780M / 760M (iGPU) | gfx1103 | `11.0.0` |
| RX 5700 (XT) | gfx1010 | `10.3.0`, doesn't always work |
| Vega 56/64, Radeon VII, MI cards | gfx900/906 | not necessary |

#### Multiple cards, iGPU in the way, rootless Docker

```bash
# Use only the second GPU (the NVIDIA "device=0" syntax does not apply here):
export DOCKER_CODE_OLLAMA_ENV="HIP_VISIBLE_DEVICES=1"

# Typical Ryzen desktop: the weak iGPU appears as device 0; select the dGPU and its ISA:
export DOCKER_CODE_OLLAMA_ENV="HIP_VISIBLE_DEVICES=1 HSA_OVERRIDE_GFX_VERSION=11.0.0"

# Rootless Docker: container root is not host root, so add the device-file groups:
export DOCKER_CODE_OLLAMA_ARGS="--group-add $(getent group render | cut -d: -f3) --group-add $(getent group video | cut -d: -f3)"

# Older kernel/Docker combinations where ROCm fails because of the seccomp profile:
export DOCKER_CODE_OLLAMA_ARGS="--security-opt seccomp=unconfined"
```

#### Check, step by step

```bash
# 1. Can the host see the GPU?
ls -l /dev/kfd /dev/dri

# 2. Can Docker pass through the device files?
docker run --rm --device /dev/kfd --device /dev/dri alpine ls -l /dev/kfd

# 3. Can the Ollama container see it?
docker exec docker-code-ollama ls -l /dev/kfd

# 4. Which backend did Ollama select at startup?
docker logs docker-code-ollama 2>&1 | grep "inference compute"
#   library=rocm -> GPU        library=cpu -> CPU
```

Utilization live without `rocm-smi` having to be installed:

```bash
watch -n 1 'cat /sys/class/drm/card*/device/gpu_busy_percent'
```

#### If it doesn't work

| observation | Cause |
|---|---|
| `docker run` breaks with `error gathering device information ... /dev/kfd` | the device file does not exist — amdgpu not loaded, kernel without KFD, WSL2 or VM without passthrough |
| Log: `amdgpu is not supported` with a list `supported types` | the card's ISA is not on it → `HSA_OVERRIDE_GFX_VERSION` from the table |
| `models status` shows `/dev/kfd`, but `computing on cpu` | Standard image instead of `:rocm`. The `IMAGE` column of `models status` says what's actually running |
| `Permission denied` to `/dev/kfd` | rootless Docker → `--group-add` as above |
| the iGPU responds instead of the dGPU | `HIP_VISIBLE_DEVICES=<index>` |
| hangs or crashes under load | usually too old kernel or amdgpu firmware; to narrow it down, try a small model (`0.5b`) |

### macOS and Windows

**macOS**: Docker Desktop **does not** pass the Apple GPU into containers. A containerized Ollama always calculates on the CPU. If you want Metal acceleration, run Ollama natively on the Mac and show docker code on it - see [From the host](#from-the-host), only the other way around: `DOCKER_CODE_OLLAMA_CONTAINER` remains unused and the tools get the host address.

**WSL2**: NVIDIA works there, AMD generally doesn't - there is no `/dev/kfd`, and the Windows route via `/dev/dxg` is not served by this image. What remains: Run Ollama natively under Windows and point the tools there.

### Testing whether the GPU is actually being used

The fastest way:

```bash
docker-code models status
```

```
gpu:      requested at start (--gpus)
ollama:   computing on cuda (NVIDIA-GeForce-RTX-4080)
```

```
gpu:      requested at start (--device /dev/kfd, the AMD/ROCm path)
ollama:   computing on rocm (AMD-Radeon-RX-7900-XTX)
```

If it says `not requested` or `computing on cpu` instead, it runs on the CPU. The two lines are intentionally separated: a container *can* have been started with the card and Ollama is still running on the CPU — driver too old, wrong image, unsupported ISA. Then it says `requested at start` and `computing on cpu`, and that is exactly the diagnosis.

If you want to know it in more detail, from the outside in - here for NVIDIA, the AMD variant is [one section above] (#check-step-by-step):

```bash
# 1. Can the host see the GPU?
nvidia-smi

# 2. Can Docker pass it through?
docker run --rm --gpus all ubuntu:24.04 nvidia-smi

# 3. Can the Ollama container see it?
docker exec docker-code-ollama nvidia-smi

# 4. Which backend did Ollama select at startup?
docker logs docker-code-ollama 2>&1 | grep "inference compute"
#   library=cuda  -> GPU        library=cpu -> CPU
```

**The real proof** is what a loaded model actually calculates. To do this it has to be loaded - so first make a request, then check:

```bash
docker-code models run qwen3:14b "hi"      # Load the model
docker exec docker-code-ollama ollama ps
```

```
NAME                 ID              SIZE     PROCESSOR    CONTEXT    UNTIL
qwen3:14b    xxxxxxxxxxxx    10 GB    100% GPU     4096       4 minutes from now
```

The `PROCESSOR` column is the answer: `100% GPU`, `100% CPU`, or a split like `45%/55% CPU/GPU` if the model doesn't quite fit in VRAM. Without a loaded model, the list is empty — Ollama unloads after a few minutes of idleness.

When watching in real time:

```bash
watch -n 1 nvidia-smi                                        # NVIDIA
watch -n 1 'cat /sys/class/drm/card*/device/gpu_busy_percent' # AMD, without rocm-smi
```

### When the GPU is not in use

| observation | Cause |
|---|---|
| `models status` says `not requested` | The detection did not find any `nvidia` runtime → `DOCKER_CODE_MODELS_GPU=1` (NVIDIA) or `=rocm` (AMD), then `models restart` |
| Step 2 above fails | Container Toolkit is missing or Docker did not restart after `nvidia-ctk` |
| Step 3 fails, step 2 works | the container was already running before the change — `docker-code models restart` |
| `requested at start`, but `computing on cpu` | NVIDIA: Driver too old for CUDA version in image. AMD: see the [AMD table](#if-it-doesnt-work) — usually Image or ISA. `docker logs docker-code-ollama` gives the reason |
| `PROCESSOR` shows a split | Model does not fit into VRAM → smaller version (`7b`) or stronger quantization |

---

## Configure by hand

If you prefer to write the values ​​into the tool's configuration yourself - in the TUI, in a config file - you need the table above. In order for the addresses in the container to be reachable at all, the session must still run with `DOCKER_CODE_LOCAL=1`: this is what attaches the container to the model network and sets the ports to `localhost`. You can then leave out the model name:

```bash
DOCKER_CODE_LOCAL=1 qwen-docker
```

When asked for an API key in a tool: **`docker-code-local`**.

### Qwen Code

```bash
DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3:14b qwen-docker
```

By hand this corresponds to:

```
OPENAI_BASE_URL=http://localhost:11434/v1
OPENAI_API_KEY=docker-code-local
OPENAI_MODEL=qwen3:14b
```

### OpenAI Codex CLI

```bash
DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3:14b codex-docker
```

The provider is already stored in `~/docker-code/codex/.codex/config.toml` and is selected via `--config model_provider=dockercode --model qwen3:14b`. By hand:

```toml
[model_providers.dockercode]
name = "docker-code local models"
base_url = "http://localhost:11434/v1"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
```

```
OPENAI_API_KEY=docker-code-local
```

`wire_api = "responses"`, not `"chat"` — Codex has removed the chat completions format and won't even load a config that still names it.

### Claude Code

```bash
DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3:14b claude-docker
```

Ollama has been speaking the Anthropic format since January 2026, so it goes straight there — without a gateway, and without `/v1` at the end:

```
ANTHROPIC_BASE_URL=http://localhost:11434
ANTHROPIC_AUTH_TOKEN=docker-code-local
ANTHROPIC_MODEL=qwen3:14b
ANTHROPIC_SMALL_FAST_MODEL=qwen3:14b
```

`ANTHROPIC_SMALL_FAST_MODEL` is not a typo: Claude Code uses a second model for background tasks and would otherwise try to achieve this in the cloud.

### Gemini CLI

```bash
DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3:14b gemini-docker
```

It is the only tool that runs over the LiteLLM gateway because it only speaks Google's own format:

```
GOOGLE_GEMINI_BASE_URL=http://localhost:4000
GEMINI_API_KEY=docker-code-local
```

The **root** of the gateway, not `/gemini`. The `@google/genai` SDK itself appends `/v1beta/models/<model>:generateContent`, and this is exactly the path LiteLLM serves from its model list. `/gemini` is a pass-through to Google AI Studio — the request would go to the Internet instead of to Ollama.

Headless (`-p`) Gemini CLI takes the auth method only from the settings, not from the environment. Therefore, the wrapper additionally points `GEMINI_CLI_SYSTEM_SETTINGS_PATH` to a file in the image that selects `gemini-api-key`. If you configure by hand, set in `~/.gemini/settings.json` instead:

```json
{ "security": { "auth": { "selectedType": "gemini-api-key" } } }
```

### Mistral Vibe

```bash
DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3:14b mistral-docker
```

Vibe knows any OpenAI-compatible providers - one for llama.cpp is installed ex works. The wrapper creates a provider `dockercode` for the duration of the session; permanently it belongs in `~/docker-code/mistral/.vibe/config.toml`:

```toml
active_model = "qwen3:14b"

[[providers]]
name = "dockercode"
api_base = "http://localhost:11434/v1"
api_key_env_var = "MISTRAL_API_KEY"
api_style = "openai"

[[models]]
name = "qwen3:14b"
provider = "dockercode"
```

`active_model` is **before** the tables — otherwise TOML pulls the key into the last table. Provider and model lists are merged by name, not replaced: Mistral's own provider remains, you switch between local and cloud with `active_model`.

Each field of the configuration can also be set as an environment variable — prefix `VIBE_`, for lists as JSON. This is exactly what the wrapper does:

```
VIBE_PROVIDERS=[{"name":"dockercode","api_base":"http://localhost:11434/v1","api_key_env_var":"MISTRAL_API_KEY","api_style":"openai"}]
VIBE_MODELS=[{"name":"qwen3:14b","provider":"dockercode"}]
VIBE_ACTIVE_MODEL=qwen3:14b
MISTRAL_API_KEY=docker-code-local
```

### OpenCode

```bash
DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3:14b opencode-docker
```

OpenCode only offers models that a provider block explicitly declares. For the duration of the session, the wrapper does this via `OPENCODE_CONFIG_CONTENT`. It belongs permanently in `~/docker-code/opencode/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "dockercode": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "docker-code local models",
      "options": {
        "baseURL": "http://localhost:11434/v1",
        "apiKey": "docker-code-local"
      },
      "models": {
        "qwen3:14b": { "name": "Qwen2.5 Coder 14B" }
      }
    }
  }
}
```

The model can then be selected as `dockercode/qwen3:14b`.

### Cursor CLI, GitHub Copilot CLI, and Kiro CLI

All three run their models on the provider's side; there is no endpoint to redirect. Kiro's settings do expose endpoint overrides, but they expect AWS service protocols rather than an OpenAI-compatible URL, so Ollama has nothing to answer with. `DOCKER_CODE_LOCAL=1` says this and starts the session anyway instead of doing nothing in silence.

---

## From the host

By default, the services do not publish a port — the agents reach them via the Docker network. If you want to address them from the machine itself (a tool outside of docker code, a script, a `curl`):

```bash
docker-code models down
DOCKER_CODE_MODELS_PUBLISH=1 docker-code models up
```

Then they are on `127.0.0.1:11434` and `127.0.0.1:4000` - only loopback, not in the network. The URLs from the table above apply unchanged, with `127.0.0.1` instead of `localhost`:

```bash
curl http://127.0.0.1:11434/v1/models

curl http://127.0.0.1:11434/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'authorization: Bearer docker-code-local' \
  -d '{"model":"qwen3:14b","messages":[{"role":"user","content":"say OK"}]}'

curl http://127.0.0.1:4000/v1/models \
  -H 'authorization: Bearer docker-code-local'
```

LiteLLM takes about 15 seconds to respond after starting; Before that there is no `401`, but no connection at all.

To make the publication permanent, the variable belongs in the shell start file:

```bash
export DOCKER_CODE_MODELS_PUBLISH=1
```

---

## What's going on

Two containers on their own network `docker-code-net`:

| Containers | Image | Task |
|---|---|---|
| `docker-code-ollama` | `ollama/ollama` | holds the weights, serves OpenAI, Anthropic and Responses format |
| `docker-code-litellm` | `ghcr.io/berriai/litellm:main-stable` | translated into formats that Ollama does not speak himself |

An NVIDIA card is used if Docker reported one (`--gpus all`), otherwise it runs on the CPU. This is recognized, not assumed: requesting a GPU that doesn't exist is a hard `docker run` error. An AMD card is **not** automatically accepted because it means a second, significantly larger image — `DOCKER_CODE_MODELS_GPU=rocm` says yes to that, and then the table above says `ollama/ollama:rocm`. CPU operation can be forced with `DOCKER_CODE_MODELS_GPU=0`.

The gateway configuration is in `~/docker-code/models/litellm/config.yaml`, is written at the first start and then **never touched again**. It contains a wildcard entry:

```yaml
model_list:
  - model_name: "*"
    litellm_params:
      model: "ollama_chat/*"
      api_base: "http://docker-code-ollama:11434"
```

This means that every model that you get with `docker-code models pull` is immediately accessible via the gateway - without another line in this file and without a restart.

## The localhost bridge

When the container starts, it gets two redirects to `127.0.0.1`:

```
localhost:11434  ->  docker-code-ollama:11434
localhost:4000   ->  docker-code-litellm:4000
```

This is not a detour, but the point. Several of these tools hardwire `localhost` — Codex's built-in `--oss` path ignores `base_url` completely ([openai/codex#8240](https://github.com/openai/codex/issues/8240)), and more than one provider integration assumes `127.0.0.1` somewhere beneath their configuration interface. They are simply right about redirection, and a tool that comes along later inherits the same working assumption.

That's why the table above contains `localhost` addresses and not container names: the latter would also work, but only as long as the tool doesn't replace them with `localhost` again.

## Direct access to model files

Some read models as a file instead of via HTTP. There are two folders for this, which are mounted with `DOCKER_CODE_LOCAL=1` **read-only** under `/models`:

```
~/docker-code/models/gguf/   ->  /models/gguf   (GGUF for llama.cpp and similar tools)
~/docker-code/models/hf/     ->  /models/hf     (HuggingFace-Cache)
```

Read-only by design: this is the only directory that all agents see. A session that could override it could foist a different model on any other agent than the one they requested.

---

## If something doesn't respond

**“API key required” / 401 / 403** — the key is `docker-code-local`. With Ollama it is arbitrary, but cannot be empty; with LiteLLM it has to be exactly right.

**400 from gateway** — wrong key. LiteLLM responds to a missing key with `401`, to an incorrect one with `400`.

**Connection refused** — is the session running with `DOCKER_CODE_LOCAL=1`? Without this, the container does not hang on the model network and there is no redirection to `localhost`. Check:

```bash
DOCKER_CODE_LOCAL=1 DOCKER_CODE_SHELL=1 qwen-docker -c 'curl -s http://localhost:11434/v1/models'
```

**“model not found”** — the name must correspond exactly to what `docker-code models list` shows, including the tag. `qwen2.5-coder` without `:14b` is a different name than `qwen3:14b`.

**The agent shows JSON instead of doing something** — something like this:

```
◆︎ { "name": "write_file", "arguments": { "file_path": "…", "content": "…" } }
```

This is a **model problem, not a connection problem**. An agent gets its tools via `tools` and expects the answer in the `tool_calls` field; a model that is not trained for this will instead write the same structure as text to `content`. The agent has nothing to parse and displays the text raw. Invented tool names in JSON are the same picture — then the model no longer has the tool list in context.

Which models can do this can be found under [Which model for an agent](#which-model-for-an-agent). You can check it in one call, without an agent:

```bash
docker run --rm --network docker-code-net curlimages/curl -s \
  http://docker-code-ollama:11434/v1/chat/completions \
  -H 'content-type: application/json' -H 'authorization: Bearer docker-code-local' \
  -d '{"model":"<model>","stream":false,
       "messages":[{"role":"user","content":"Write hi into a.txt"}],
       "tools":[{"type":"function","function":{"name":"write_file",
         "parameters":{"type":"object","properties":{"file_path":{"type":"string"},
                                                     "content":{"type":"string"}}}}}]}'
```

If `"tool_calls": [...]` comes back, the model is suitable as an agent. If the function is instead written as text in `"content"`, it is no good - no setting in the docker code or in the agent changes this.

**Gemini doesn't answer** — the gateway is there in between:

```bash
docker-code models logs docker-code-litellm
```

The way without an agent to narrow down:

```bash
docker run --rm --network docker-code-net curlimages/curl -s \
  "http://docker-code-litellm:4000/v1beta/models/qwen3:14b:generateContent" \
  -H "x-goog-api-key: docker-code-local" -H "content-type: application/json" \
  -d '{"contents":[{"parts":[{"text":"say OK"}]}]}'
```

**Everything is slow** — it's probably processing on the CPU. `docker-code models status` says it in two lines; The whole process for checking is under [GPU](#gpu).

---

## Commands

```bash
docker-code models up            # starten (idempotent)
docker-code models down          # Stop and remove the network
docker-code models restart       # Recreate both; add ollama or litellm for one of them
docker-code models status        # Zustand, Speicherort, Belegung
docker-code models pull <model>
docker-code models list
docker-code models rm <model>
docker-code models run <model>  # Talk directly to the model, without an agent
docker-code models logs [container]
```

`restart` **recreates** the containers rather than calling `docker restart`, because the reason to
restart one is almost always a setting that changed — `DOCKER_CODE_OLLAMA_ENV`, a GPU mode, a pinned
image tag, or the LiteLLM `config.yaml` you just edited. All of those apply when the container is
created, so `docker restart` would keep the old ones and look like it had done nothing. Nothing is
lost: the weights and the gateway config are both on bind mounts.

Name one service when only that half needs it — editing `config.yaml`, which is yours and is never
overwritten, is the usual case:

```bash
docker-code models restart litellm
```

Unlike `down`, the network is left in place, so attached sessions are not disturbed.

If something doesn't start, it's a warning and not a failed session: the agent then continues to run with its cloud provider. A model gateway is worth less than the session it would otherwise prevent.

## Under `DOCKER_CODE_NET=gateway`

Local models keep working, but the session no longer joins the model network — that network has a
route off the host, which would be a way around the egress gateway. The gateway joins it instead, and
the loopback bridge inside the container tunnels to Ollama and LiteLLM through the proxy. Nothing about
the configuration in this file changes.

Ollama's own pull from ollama.com is a separate matter, governed by one variable:

| variable | Default | Effect |
|---|---|---|
| `DOCKER_CODE_MODELS_EGRESS` | `1` | under `NET=gateway` only: `1` routes Ollama's model pulls through the shared-services gateway, `0` goes direct, or give a proxy URL |

This is advisory rather than enforced, and [EGRESS.md](EGRESS.md#the-shared-services-are-a-different-question)
explains why. LiteLLM is deliberately never given a proxy: it reaches Ollama by container name, so a
proxy would route its one useful call through a gateway with no reason to allow it.

## Disk space

```bash
du -sh ~/docker-code/models/*
docker-code models rm qwen3:14b
rm -rf ~/docker-code/models          # Remove everything; next `models up` starts empty
```

Magnitude for `qwen2.5-coder`: `0.5b` ~400 MB, `7b` ~4.7 GB, `14b` ~9 GB, `32b` ~20 GB.
