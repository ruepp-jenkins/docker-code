# Lokale Modelle

Ein Modellspeicher für alle Agents. Sieben Tools, die jeweils ihre eigene Kopie eines 9-GB-Modells
halten, wären 63 GB derselben Bytes — hier liegt es einmal unter `~/docker-code/models/`, und jeder
Container spricht denselben Daemon an.

Alle Beispiele auf dieser Seite verwenden **`qwen2.5-coder:14b`** (~9 GB, passt auf eine 16-GB-Karte)
und sind so gemeint, wie sie dastehen: kopieren, einfügen, läuft.

---

## Die Zugangsdaten

Das ist der Teil, den man beim Konfigurieren von Hand braucht:

| | URL | API-Key |
|---|---|---|
| **Ollama** — OpenAI-Format | `http://localhost:11434/v1` | `docker-code-local` |
| **Ollama** — Anthropic-Format | `http://localhost:11434` | `docker-code-local` |
| **LiteLLM-Gateway** — Gemini-Format | `http://localhost:4000` | `docker-code-local` |
| **LiteLLM-Gateway** — OpenAI-Format | `http://localhost:4000/v1` | `docker-code-local` |

**Der Key ist überall `docker-code-local`.**

Er ist kein Geheimnis: er authentifiziert einen Container gegenüber einem Gateway in einem privaten
Docker-Netz ohne veröffentlichten Port. Er existiert, weil LiteLLM sich weigert, ohne Key zu
antworten — ohne ihn kommt `401`, mit einem falschen `400`.

Ollama selbst prüft gar nichts; dort funktioniert jeder beliebige Wert. Die meisten Tools bestehen
aber auf einem nicht-leeren Feld, und es ist eine Sorge weniger, wenn überall dasselbe steht. Nimm
also auch dort `docker-code-local`.

Ändern lässt er sich über `LOCAL_API_KEY` in `lib/models.sh`; danach `docker-code models down && docker-code models up`.

---

## Schnellstart

```bash
docker-code models up
docker-code models pull qwen2.5-coder:14b
docker-code models list
```

Der erste Pull lädt ~9 GB. Danach, im Projektverzeichnis:

```bash
export DOCKER_CODE_LOCAL=1
export DOCKER_CODE_LOCAL_MODEL=qwen2.5-coder:14b

qwen-docker          # oder codex-docker, gemini-docker, claude-docker, opencode-docker
```

Damit ist **nichts von Hand zu konfigurieren** — URL, Key und Modellname setzt der Wrapper. Nachsehen,
was genau ankommt, ohne etwas zu starten:

```bash
DOCKER_CODE_DRY_RUN=1 DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen2.5-coder:14b qwen-docker
```

---

## Welches Modell für einen Agent

Zwei verschiedene Aufgaben, und der Unterschied entscheidet, ob eine Session funktioniert:

- **Code schreiben, wenn man fragt** — dafür reicht jedes Coder-Modell, `qwen2.5-coder:14b` ist gut
  darin.
- **Als Agent arbeiten** — Dateien lesen, Kommandos ausführen, Ergebnisse verwerten. Dafür muss das
  Modell **Tool-Calls** beherrschen: Der Agent schickt seine Werkzeuge im Feld `tools` mit und
  erwartet die Antwort in `tool_calls`. Alle sieben Tools hier arbeiten so.

Ein Modell ohne dieses Training schreibt den Funktionsaufruf als Text in die Antwort, der Agent kann
ihn nicht ausführen und zeigt rohes JSON an. **`qwen2.5-coder` gehört in diese Gruppe** — es ist ein
Completion-Modell, kein Agent-Modell, unabhängig von der Größe.

| Modell | Download | als Agent |
|---|---|---|
| `qwen3-coder:30b` | ~17 GB | ja — das Modell, für das Qwen Code gebaut ist. MoE mit ~3 B aktiven Parametern, also schnell, sobald es ins VRAM passt |
| `qwen3:14b` | ~8,6 GB | ja — dieselbe Größenklasse wie `qwen2.5-coder:14b` |
| `qwen3:8b` | ~4,9 GB | ja — wenn das VRAM knapp ist |
| `qwen2.5-coder:14b` | ~8,4 GB | **nein** — gut für Completion, unbrauchbar als Agent |

Ob ein Modell es grundsätzlich anbietet, sagt seine Capability-Liste:

```bash
docker exec docker-code-ollama ollama show qwen3:8b | grep -A4 Capabilities
#   completion / tools / insert / thinking
```

Das ist allerdings nur die halbe Auskunft: `tools` steht auch bei Modellen dort, die das Format in
der Praxis nicht einhalten — die Capability beschreibt das Prompt-Template, nicht das Training. Der
belastbare Test ist der Aufruf mit echten `tools`, siehe
[Der Agent zeigt JSON](#wenn-etwas-nicht-antwortet).

### Kontextfenster

Der zweite stille Grund für einen Agent, der Unsinn tut: Ein Agent schickt einen langen
System-Prompt plus die Schemas aller Werkzeuge — schnell über 10.000 Token. Passt das nicht ins
Kontextfenster, schneidet Ollama vorne ab, und das Modell erfindet Werkzeugnamen, die es nie gesehen
hat.

```bash
docker exec docker-code-ollama ollama ps      # Spalte CONTEXT, während ein Modell geladen ist
```

Ollama wählt den Wert nach verfügbarem VRAM (4k/32k/256k). Steht dort `4096`, ist das für einen
Agent zu wenig:

```bash
export DOCKER_CODE_OLLAMA_ENV="OLLAMA_CONTEXT_LENGTH=32768"
docker-code models down && docker-code models up
```

Mehr Kontext kostet VRAM — wenn danach `ollama ps` eine CPU/GPU-Aufteilung zeigt, war es zu viel.

---

## Dauerhaft: der `.bashrc`-Block

Zum Kopieren ans Ende von `~/.bashrc` (unter macOS `~/.zshrc`), danach eine neue Shell öffnen:

```bash
# ---- docker-code -------------------------------------------------------------
export PATH="$HOME/.local/bin:$PATH"

# Lokale Modelle für die Tools, die sie können — pro Agent, nicht pauschal.
export DOCKER_CODE_QWEN_LOCAL=1
export DOCKER_CODE_QWEN_LOCAL_MODEL=qwen2.5-coder:14b

export DOCKER_CODE_OPENCODE_LOCAL=1
export DOCKER_CODE_OPENCODE_LOCAL_MODEL=qwen2.5-coder:14b

export DOCKER_CODE_CODEX_LOCAL=1
export DOCKER_CODE_CODEX_LOCAL_MODEL=qwen2.5-coder:14b

# Claude und Gemini absichtlich nicht: die laufen weiter über ihr Abo bzw. ihren
# Cloud-Key. Zum Umschalten für einen einzelnen Aufruf genügt:
#     DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen2.5-coder:14b claude-docker
# ------------------------------------------------------------------------------
```

**Pro Agent statt pauschal** ist hier der Punkt. `DOCKER_CODE_LOCAL=1` global gesetzt würde auch
Claude Code auf das lokale Modell umbiegen — also genau den Agent, für den du vermutlich ein Abo
bezahlst. `DOCKER_CODE_<AGENT>_<KNOPF>` schlägt `DOCKER_CODE_<KNOPF>` schlägt den Standard, und das
gilt für **jeden** Schalter aus der Tabelle im README, nicht nur für diese beiden.

Wer es doch überall will:

```bash
export DOCKER_CODE_LOCAL=1
export DOCKER_CODE_LOCAL_MODEL=qwen2.5-coder:14b
export DOCKER_CODE_CLAUDE_LOCAL=0      # eine Ausnahme davon
```

### Was hier *nicht* hingehört

```bash
# NICHT in die .bashrc:
export OPENAI_BASE_URL=http://localhost:11434/v1
export OPENAI_API_KEY=docker-code-local
```

Das sind Variablen, die der Wrapper an `codex-docker` und `qwen-docker` **durchreicht** — auch an
Sessions, die *ohne* `DOCKER_CODE_LOCAL=1` laufen. Dort gibt es aber keine Weiterleitung auf
`localhost:11434`, und die Session läuft in einen Verbindungsfehler statt zu ihrem Cloud-Provider.
Setz stattdessen die `DOCKER_CODE_*_LOCAL`-Schalter oben; die tool-eigenen Variablen setzt der
Wrapper dann selbst, und nur dann, wenn die Brücke auch steht.

Auf dem Host sinnvoll sind sie nur, wenn du ein Tool *außerhalb* von docker-code betreibst — dann
aber mit `127.0.0.1` und veröffentlichten Ports, siehe [Vom Host aus](#vom-host-aus).

### Prüfen, ob es greift

```bash
docker-code models status                  # laufen die Dienste? wie lautet der Key?
DOCKER_CODE_DRY_RUN=1 qwen-docker          # zeigt OPENAI_BASE_URL/-MODEL, ohne zu starten
DOCKER_CODE_DRY_RUN=1 claude-docker        # zeigt: kein docker-code-net, kein ANTHROPIC_BASE_URL
```

---

## GPU

Ohne GPU rechnet ein 14-B-Modell auf der CPU — das funktioniert, ist aber etwa eine Größenordnung
langsamer. Ollama entscheidet das nicht selbst: der Container bekommt die Karte durchgereicht, oder
er bekommt sie nicht.

Zwei Hersteller, zwei völlig verschiedene Wege in den Container: NVIDIA über eine Container-Runtime,
die die Karte injiziert (`--gpus`), AMD über zwei Gerätedateien, die man selbst hineinreicht
(`--device`) — plus ein anderes Image. Deshalb ist `DOCKER_CODE_MODELS_GPU` kein Schalter, sondern
eine Wahl:

| `DOCKER_CODE_MODELS_GPU` | Wirkung |
|---|---|
| *ungesetzt* / `auto` | GPU nur, wenn Docker die `nvidia`-Runtime meldet — Standard |
| `1` | `--gpus all` erzwingen, auch wenn die Erkennung nichts findet |
| `device=0` | an eine bestimmte NVIDIA-Karte binden (wird unverändert an `--gpus` gereicht) |
| `rocm` | **AMD**: `--device /dev/kfd --device /dev/dri` **und** das Image `ollama/ollama:rocm` |
| `0` | CPU erzwingen |

Alles davon wirkt beim **Erzeugen** des Containers. Nach jeder Änderung also:

```bash
docker-code models down
DOCKER_CODE_MODELS_GPU=rocm docker-code models up
```

Dauerhaft gehört die Variable in die `.bashrc` — sie ist eine Einstellung der Modelldienste, nicht
der Session, und hat deshalb **keine** `DOCKER_CODE_<AGENT>_`-Form.

### NVIDIA unter Linux

1. Ein NVIDIA-Treiber auf dem **Host** (nicht im Container). `nvidia-smi` muss auf dem Host laufen.
2. Das **NVIDIA Container Toolkit**, damit Docker die Karte überhaupt weiterreichen kann:

```bash
# Debian/Ubuntu — Paketquelle einrichten, siehe NVIDIA-Doku für die aktuelle Zeile
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

3. Genug VRAM. Faustregel für `qwen2.5-coder` in der Standard-Quantisierung: `7b` ~5 GB, `14b` ~9 GB,
   `32b` ~20 GB. Passt das Modell nicht ganz hinein, lädt Ollama es teilweise — dann steht in
   `ollama ps` etwas wie `45%/55% CPU/GPU`, und die Geschwindigkeit liegt dazwischen.

Erkannt statt angenommen, weil eine GPU anzufordern, die es nicht gibt, ein **harter Startfehler**
ist:

```
docker: Error response from daemon: failed to discover GPU vendor from CDI:
        no known GPU vendor found
```

Die Erkennung sieht die Runtime, die das Container Toolkit registriert. Ein Host, der nur über CDI
verdrahtet ist, hat keine solche Runtime — dort findet `auto` nichts und du brauchst
`DOCKER_CODE_MODELS_GPU=1`.

---

### AMD unter Linux (ROCm)

Der ganze Weg in drei Zeilen — mehr ist es nicht, wenn die Karte von ROCm unterstützt wird:

```bash
docker-code models down
DOCKER_CODE_MODELS_GPU=rocm docker-code models up
docker-code models status          # muss "computing on rocm" sagen
```

`rocm` setzt **beides** auf einmal, und beides ist nötig:

```
--device /dev/kfd --device /dev/dri      die Karte in den Container
ollama/ollama:rocm                       das Image, das die ROCm-Bibliotheken enthält
```

Das ist der Grund, warum `DOCKER_CODE_OLLAMA_IMAGE=ollama/ollama:rocm` allein nichts bringt: ohne die
beiden Gerätedateien sieht der Container keine Karte und rechnet weiter auf der CPU — ohne Fehler,
nur langsam. Umgekehrt genauso: Devices ohne ROCm-Image ist ebenfalls CPU.

Das ROCm-Image ist ein paar GB größer als das Standard-Image; der erste `models up` dauert
entsprechend. Wer eine bestimmte Version festnageln will, überschreibt es —
`DOCKER_CODE_OLLAMA_IMAGE` schlägt die Automatik, die Devices bleiben trotzdem gesetzt.

#### Was der Host braucht

1. **Den amdgpu-Kerneltreiber mit KFD.** Beide Gerätedateien müssen existieren:

   ```bash
   ls -l /dev/kfd /dev/dri/renderD*
   ```

   Fehlt `/dev/kfd`, ist ROCm nicht ansprechbar — das ist der Normalfall in WSL2 und in VMs ohne
   GPU-Passthrough. `lsmod | grep amdgpu` sagt, ob der Treiber überhaupt geladen ist.

2. **Kein ROCm-Userspace.** Die Bibliotheken stecken im Image; auf dem Host muss nichts von AMD
   installiert sein. (`rocm-smi` ist trotzdem praktisch, ist aber nur ein Monitoring-Werkzeug.)

3. **Eine Karte, die ROCm kennt** — grob: Vega (gfx900) und alles danach. Ältere Karten (Polaris,
   RX 5xx) laufen nicht, dort bleibt nur die CPU. Was Ollama akzeptiert, steht in seiner
   [GPU-Doku](https://github.com/ollama/ollama/blob/main/docs/gpu.md); Karten, die knapp danebenliegen,
   rettet `HSA_OVERRIDE_GFX_VERSION` (unten).

4. **Genug VRAM**, dieselbe Faustregel wie bei NVIDIA: `7b` ~5 GB, `14b` ~9 GB, `32b` ~20 GB. Eine
   iGPU rechnet mit dem, was ihr das BIOS als UMA-Speicher zuteilt — dort ist die kleine Variante
   meist die einzige, die vollständig hineinpasst.

#### Die Variablen

Vier Knöpfe, alle für den Ollama-Container, alle wirksam beim `models up`:

| Variable | Beispiel | Wirkung |
|---|---|---|
| `DOCKER_CODE_MODELS_GPU` | `rocm` | Devices + ROCm-Image, siehe oben |
| `DOCKER_CODE_OLLAMA_IMAGE` | `ollama/ollama:<version>-rocm` | ein bestimmtes Image statt `:rocm` |
| `DOCKER_CODE_OLLAMA_ENV` | `"HSA_OVERRIDE_GFX_VERSION=11.0.0"` | Umgebung **im** Ollama-Daemon, mit Leerzeichen getrennt |
| `DOCKER_CODE_OLLAMA_ARGS` | `"--security-opt seccomp=unconfined"` | beliebige weitere `docker run`-Argumente |

Ein vollständiger Block für die `.bashrc`, hier für eine RX 6700 XT:

```bash
export DOCKER_CODE_MODELS_GPU=rocm
export DOCKER_CODE_OLLAMA_ENV="HSA_OVERRIDE_GFX_VERSION=10.3.0"
```

Danach einmal `docker-code models down && docker-code models up`, und jede Session nimmt die Karte.

#### `HSA_OVERRIDE_GFX_VERSION` — der Knopf, an dem es meistens hängt

ROCm bedient nur eine Liste von ISA-Versionen. Steht die eigene Karte nicht darauf, überspringt
Ollama sie kommentarlos und rechnet auf der CPU. Der Override erzählt ROCm eine andere Version — bei
Karten derselben Generation funktioniert das zuverlässig.

Erst nachsehen, was die Karte wirklich ist:

```bash
# aus dem Log des laufenden Containers — nennt gfx-Version und die unterstützte Liste
docker logs docker-code-ollama 2>&1 | grep -iE 'amdgpu|gfx|rocm'

# oder direkt aus dem Treiber, ohne Container:
grep -r gfx_target_version /sys/class/kfd/kfd/topology/nodes/*/properties
#   100300 -> gfx1030 -> "10.3.0"        110000 -> gfx1100 -> "11.0.0"
#   100301 -> gfx1031 -> "10.3.0"        110300 -> gfx1103 -> "11.0.0"
```

Die Zahl ist `major*10000 + minor*100 + step`; `100301` heißt also gfx1031. Der Override wird in
derselben Zerlegung geschrieben (`10.3.0`), aber mit der ISA der **unterstützten** Nachbarkarte, nicht
mit der eigenen — gfx1031 gibt sich als gfx1030 aus. Übliche Fälle:

| Karte | ISA | `HSA_OVERRIDE_GFX_VERSION` |
|---|---|---|
| RX 7900 XTX / XT / GRE | gfx1100 | nicht nötig |
| RX 7800 XT / 7700 XT | gfx1101 | meist nicht nötig, sonst `11.0.0` |
| RX 7600 (XT) | gfx1102 | `11.0.0` |
| RX 6800 / 6900 / 6950 XT | gfx1030 | nicht nötig |
| RX 6700 (XT) / 6750 XT | gfx1031 | `10.3.0` |
| RX 6600 (XT) / 6650 XT | gfx1032 | `10.3.0` |
| RX 6500 XT / 6400 | gfx1034 | `10.3.0` |
| Radeon 780M / 760M (iGPU) | gfx1103 | `11.0.0` |
| RX 5700 (XT) | gfx1010 | `10.3.0`, funktioniert nicht immer |
| Vega 56/64, Radeon VII, MI-Karten | gfx900/906 | nicht nötig |

#### Mehrere Karten, iGPU im Weg, rootless Docker

```bash
# nur die zweite Karte benutzen (der NVIDIA-Weg "device=0" gilt hier nicht):
export DOCKER_CODE_OLLAMA_ENV="HIP_VISIBLE_DEVICES=1"

# typischer Ryzen-Desktop: die iGPU meldet sich als Karte 0 und ist zu schwach —
# dGPU festnageln und gleich die passende ISA mitgeben:
export DOCKER_CODE_OLLAMA_ENV="HIP_VISIBLE_DEVICES=1 HSA_OVERRIDE_GFX_VERSION=11.0.0"

# rootless Docker: root im Container ist kein root auf dem Host, also müssen die
# Gruppen der Gerätedateien mit hinein:
export DOCKER_CODE_OLLAMA_ARGS="--group-add $(getent group render | cut -d: -f3) --group-add $(getent group video | cut -d: -f3)"

# ältere Kernel/Docker-Kombinationen, bei denen ROCm am seccomp-Profil scheitert:
export DOCKER_CODE_OLLAMA_ARGS="--security-opt seccomp=unconfined"
```

#### Prüfen, Schritt für Schritt

```bash
# 1. Sieht der Host die Karte?
ls -l /dev/kfd /dev/dri

# 2. Kann Docker die Gerätedateien durchreichen?
docker run --rm --device /dev/kfd --device /dev/dri alpine ls -l /dev/kfd

# 3. Sieht der Ollama-Container sie?
docker exec docker-code-ollama ls -l /dev/kfd

# 4. Worauf hat Ollama sich beim Start festgelegt?
docker logs docker-code-ollama 2>&1 | grep "inference compute"
#   library=rocm -> GPU        library=cpu -> CPU
```

Auslastung live, ohne dass `rocm-smi` installiert sein muss:

```bash
watch -n 1 'cat /sys/class/drm/card*/device/gpu_busy_percent'
```

#### Wenn es nicht greift

| Beobachtung | Ursache |
|---|---|
| `docker run` bricht mit `error gathering device information ... /dev/kfd` ab | die Gerätedatei gibt es nicht — amdgpu nicht geladen, Kernel ohne KFD, WSL2 oder VM ohne Passthrough |
| Log: `amdgpu is not supported` mit einer Liste `supported types` | die ISA der Karte steht nicht drauf → `HSA_OVERRIDE_GFX_VERSION` aus der Tabelle |
| `models status` zeigt `/dev/kfd`, aber `computing on cpu` | Standard-Image statt `:rocm`. Die `IMAGE`-Spalte von `models status` sagt, was tatsächlich läuft |
| `Permission denied` auf `/dev/kfd` | rootless Docker → `--group-add` wie oben |
| die iGPU antwortet statt der dGPU | `HIP_VISIBLE_DEVICES=<index>` |
| hängt oder stürzt unter Last ab | meist zu alter Kernel bzw. amdgpu-Firmware; zum Eingrenzen ein kleines Modell (`0.5b`) versuchen |

### macOS und Windows

**macOS**: Docker Desktop reicht die Apple-GPU **nicht** in Container durch. Ein containerisiertes
Ollama rechnet dort immer auf der CPU. Wer Metal-Beschleunigung will, betreibt Ollama nativ auf dem
Mac und zeigt docker-code darauf — siehe [Vom Host aus](#vom-host-aus), nur andersherum:
`DOCKER_CODE_OLLAMA_CONTAINER` bleibt ungenutzt und die Tools bekommen die Host-Adresse.

**WSL2**: NVIDIA funktioniert dort, AMD in aller Regel nicht — es gibt kein `/dev/kfd`, und der
Windows-Weg über `/dev/dxg` wird von diesem Image nicht bedient. Bleibt: Ollama nativ unter Windows
betreiben und die Tools dorthin zeigen.

### Testen, ob die GPU wirklich benutzt wird

Der schnellste Weg:

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

Steht dort stattdessen `not requested` oder `computing on cpu`, läuft es auf der CPU. Die beiden
Zeilen sind absichtlich getrennt: ein Container *kann* mit der Karte gestartet worden sein und Ollama
trotzdem auf der CPU rechnen — zu alter Treiber, falsches Image, nicht unterstützte ISA. Dann steht
da `requested at start` und `computing on cpu`, und das ist genau die Diagnose.

Wenn du es genauer wissen willst, von außen nach innen — hier für NVIDIA, die AMD-Variante steht
[eine Sektion weiter oben](#prüfen-schritt-für-schritt):

```bash
# 1. Sieht der Host die Karte?
nvidia-smi

# 2. Kann Docker sie durchreichen?
docker run --rm --gpus all ubuntu:24.04 nvidia-smi

# 3. Sieht der Ollama-Container sie?
docker exec docker-code-ollama nvidia-smi

# 4. Worauf hat Ollama sich beim Start festgelegt?
docker logs docker-code-ollama 2>&1 | grep "inference compute"
#   library=cuda  -> GPU        library=cpu -> CPU
```

**Der eigentliche Beweis** ist aber, worauf ein geladenes Modell tatsächlich rechnet. Dafür muss es
geladen sein — also erst eine Anfrage stellen, dann nachsehen:

```bash
docker-code models run qwen2.5-coder:14b "hi"      # lädt das Modell
docker exec docker-code-ollama ollama ps
```

```
NAME                 ID              SIZE     PROCESSOR    CONTEXT    UNTIL
qwen2.5-coder:14b    xxxxxxxxxxxx    10 GB    100% GPU     4096       4 minutes from now
```

Die Spalte `PROCESSOR` ist die Antwort: `100% GPU`, `100% CPU`, oder eine Aufteilung wie
`45%/55% CPU/GPU`, wenn das Modell nicht ganz ins VRAM passt. Ohne geladenes Modell ist die Liste
leer — Ollama entlädt nach einigen Minuten Leerlauf.

Beim Zusehen in Echtzeit:

```bash
watch -n 1 nvidia-smi                                        # NVIDIA
watch -n 1 'cat /sys/class/drm/card*/device/gpu_busy_percent' # AMD, ohne rocm-smi
```

### Wenn die GPU nicht benutzt wird

| Beobachtung | Ursache |
|---|---|
| `models status` sagt `not requested` | die Erkennung fand keine `nvidia`-Runtime → `DOCKER_CODE_MODELS_GPU=1` (NVIDIA) bzw. `=rocm` (AMD), dann `models down && models up` |
| Schritt 2 oben scheitert | Container Toolkit fehlt oder Docker wurde nach `nvidia-ctk` nicht neu gestartet |
| Schritt 3 scheitert, Schritt 2 klappt | der Container lief schon vor der Änderung — `docker-code models down && docker-code models up` |
| `requested at start`, aber `computing on cpu` | NVIDIA: Treiber zu alt für die CUDA-Version im Image. AMD: siehe die [AMD-Tabelle](#wenn-es-nicht-greift) — meist Image oder ISA. `docker logs docker-code-ollama` nennt den Grund |
| `PROCESSOR` zeigt eine Aufteilung | Modell passt nicht ins VRAM → kleinere Variante (`7b`) oder stärkere Quantisierung |

---

## Von Hand konfigurieren

Wer die Werte lieber selbst in die Konfiguration des Tools schreibt — im TUI, in einer Config-Datei —
braucht die Tabelle oben. Damit die Adressen im Container überhaupt erreichbar sind, muss die Session
trotzdem mit `DOCKER_CODE_LOCAL=1` laufen: das ist es, was den Container ans Modellnetz hängt und die
Ports auf `localhost` legt. Den Modellnamen kannst du dann weglassen:

```bash
DOCKER_CODE_LOCAL=1 qwen-docker
```

Wenn du in einem Tool nach einem API-Key gefragt wirst: **`docker-code-local`**.

### Qwen Code

```bash
DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen2.5-coder:14b qwen-docker
```

Von Hand entspricht das:

```
OPENAI_BASE_URL=http://localhost:11434/v1
OPENAI_API_KEY=docker-code-local
OPENAI_MODEL=qwen2.5-coder:14b
```

### OpenAI Codex CLI

```bash
DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen2.5-coder:14b codex-docker
```

Der Provider ist bereits in `~/docker-code/codex/.codex/config.toml` hinterlegt und wird per
`--config model_provider=dockercode --model qwen2.5-coder:14b` ausgewählt. Von Hand:

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

`wire_api = "responses"`, nicht `"chat"` — Codex hat das Chat-Completions-Format entfernt und lädt
eine Config, die es noch nennt, gar nicht erst.

### Claude Code

```bash
DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen2.5-coder:14b claude-docker
```

Ollama spricht seit Januar 2026 selbst das Anthropic-Format, es geht also direkt dorthin — ohne
Gateway, und ohne `/v1` am Ende:

```
ANTHROPIC_BASE_URL=http://localhost:11434
ANTHROPIC_AUTH_TOKEN=docker-code-local
ANTHROPIC_MODEL=qwen2.5-coder:14b
ANTHROPIC_SMALL_FAST_MODEL=qwen2.5-coder:14b
```

`ANTHROPIC_SMALL_FAST_MODEL` ist kein Tippfehler: Claude Code benutzt dafür ein zweites Modell für
Hintergrundaufgaben und würde sonst versuchen, dieses in der Cloud zu erreichen.

### Gemini CLI

```bash
DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen2.5-coder:14b gemini-docker
```

Als einziges der Tools läuft es über das LiteLLM-Gateway, weil es nur Googles eigenes Format spricht:

```
GOOGLE_GEMINI_BASE_URL=http://localhost:4000
GEMINI_API_KEY=docker-code-local
```

Die **Wurzel** des Gateways, nicht `/gemini`. Das `@google/genai`-SDK hängt selbst
`/v1beta/models/<modell>:generateContent` an, und genau diesen Pfad bedient LiteLLM aus seiner
Modellliste. `/gemini` ist ein Pass-Through zu Google AI Studio — die Anfrage ginge ins Internet
statt zu Ollama.

Headless (`-p`) nimmt Gemini CLI die Auth-Methode nur aus den Settings, nicht aus der Umgebung.
Deshalb zeigt der Wrapper zusätzlich `GEMINI_CLI_SYSTEM_SETTINGS_PATH` auf eine Datei im Image, die
`gemini-api-key` auswählt. Wer von Hand konfiguriert, setzt stattdessen in `~/.gemini/settings.json`:

```json
{ "security": { "auth": { "selectedType": "gemini-api-key" } } }
```

### OpenCode

```bash
DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen2.5-coder:14b opencode-docker
```

OpenCode bietet nur Modelle an, die ein Provider-Block ausdrücklich deklariert. Für die Dauer der
Session erledigt das der Wrapper über `OPENCODE_CONFIG_CONTENT`. Dauerhaft gehört es in
`~/docker-code/opencode/.config/opencode/opencode.json`:

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
        "qwen2.5-coder:14b": { "name": "Qwen2.5 Coder 14B" }
      }
    }
  }
}
```

Danach ist das Modell als `dockercode/qwen2.5-coder:14b` auswählbar.

### Cursor CLI und GitHub Copilot CLI

Beide rechnen serverseitig beim Anbieter; es gibt keinen Endpunkt, den man umbiegen könnte.
`DOCKER_CODE_LOCAL=1` sagt das und startet die Session trotzdem, statt schweigend nichts zu tun.

---

## Vom Host aus

Standardmäßig veröffentlichen die Dienste keinen Port — die Agents erreichen sie über das Docker-Netz.
Wer sie von der Maschine selbst ansprechen will (ein Tool außerhalb von docker-code, ein Skript, ein
`curl`):

```bash
docker-code models down
DOCKER_CODE_MODELS_PUBLISH=1 docker-code models up
```

Dann liegen sie auf `127.0.0.1:11434` und `127.0.0.1:4000` — nur Loopback, nicht im Netz. Die URLs
aus der Tabelle oben gelten unverändert, mit `127.0.0.1` statt `localhost`:

```bash
curl http://127.0.0.1:11434/v1/models

curl http://127.0.0.1:11434/v1/chat/completions \
  -H 'content-type: application/json' \
  -H 'authorization: Bearer docker-code-local' \
  -d '{"model":"qwen2.5-coder:14b","messages":[{"role":"user","content":"say OK"}]}'

curl http://127.0.0.1:4000/v1/models \
  -H 'authorization: Bearer docker-code-local'
```

LiteLLM braucht nach dem Start etwa 15 Sekunden, bis es antwortet; davor kommt kein `401`, sondern
gar keine Verbindung.

Damit die Veröffentlichung dauerhaft gilt, gehört die Variable in die Shell-Startdatei:

```bash
export DOCKER_CODE_MODELS_PUBLISH=1
```

---

## Was läuft

Zwei Container auf einem eigenen Netz `docker-code-net`:

| Container | Image | Aufgabe |
|---|---|---|
| `docker-code-ollama` | `ollama/ollama` | hält die Gewichte, serviert OpenAI-, Anthropic- und Responses-Format |
| `docker-code-litellm` | `ghcr.io/berriai/litellm:main-stable` | übersetzt in Formate, die Ollama nicht selbst spricht |

Eine NVIDIA-Karte wird benutzt, wenn Docker eine gemeldet hat (`--gpus all`), sonst läuft es auf der
CPU. Das wird erkannt, nicht angenommen: eine GPU anzufordern, die es nicht gibt, ist ein harter
`docker run`-Fehler. Eine AMD-Karte wird **nicht** automatisch genommen, weil sie ein zweites, deutlich
größeres Image bedeutet — `DOCKER_CODE_MODELS_GPU=rocm` sagt ja dazu, und dann steht in der Tabelle
oben `ollama/ollama:rocm`. Erzwingen lässt sich CPU-Betrieb mit `DOCKER_CODE_MODELS_GPU=0`.

Die Gateway-Konfiguration liegt in `~/docker-code/models/litellm/config.yaml`, wird beim ersten Start
geschrieben und danach **nie wieder angefasst**. Sie enthält einen Wildcard-Eintrag:

```yaml
model_list:
  - model_name: "*"
    litellm_params:
      model: "ollama_chat/*"
      api_base: "http://docker-code-ollama:11434"
```

Dadurch ist jedes Modell, das du mit `docker-code models pull` holst, sofort auch über das Gateway
erreichbar — ohne weitere Zeile in dieser Datei und ohne Neustart.

## Die localhost-Brücke

Der Container bekommt beim Start zwei Weiterleitungen auf `127.0.0.1`:

```
localhost:11434  ->  docker-code-ollama:11434
localhost:4000   ->  docker-code-litellm:4000
```

Das ist kein Umweg, sondern der Punkt. Mehrere dieser Tools verdrahten `localhost` fest — Codex'
eingebauter `--oss`-Pfad ignoriert `base_url` komplett
([openai/codex#8240](https://github.com/openai/codex/issues/8240)), und mehr als eine
Provider-Integration nimmt irgendwo unterhalb ihrer Konfigurationsoberfläche `127.0.0.1` an. Mit der
Weiterleitung haben sie schlicht recht, und ein Tool, das später dazukommt, erbt dieselbe
funktionierende Annahme.

Deshalb stehen in der Tabelle oben `localhost`-Adressen und keine Containernamen: Letztere würden
auch funktionieren, aber nur solange das Tool sie nicht wieder durch `localhost` ersetzt.

## Modelldateien direkt

Manches liest Modelle als Datei statt über HTTP. Dafür gibt es zwei Ordner, die mit
`DOCKER_CODE_LOCAL=1` **read-only** unter `/models` eingehängt werden:

```
~/docker-code/models/gguf/   ->  /models/gguf   (GGUF für llama.cpp & Co.)
~/docker-code/models/hf/     ->  /models/hf     (HuggingFace-Cache)
```

Read-only mit Absicht: das ist das einzige Verzeichnis, das alle Agents sehen. Eine Session, die es
überschreiben könnte, könnte jedem anderen Agent ein anderes Modell unterschieben, als er angefordert
hat.

---

## Wenn etwas nicht antwortet

**„API key required" / 401 / 403** — der Key ist `docker-code-local`. Bei Ollama ist er beliebig, darf
aber nicht leer sein; bei LiteLLM muss er genau stimmen.

**400 vom Gateway** — falscher Key. LiteLLM antwortet auf einen fehlenden Key mit `401`, auf einen
falschen mit `400`.

**Verbindung abgelehnt** — läuft die Session mit `DOCKER_CODE_LOCAL=1`? Ohne das hängt der Container
nicht am Modellnetz und es gibt keine Weiterleitung auf `localhost`. Prüfen:

```bash
DOCKER_CODE_LOCAL=1 DOCKER_CODE_SHELL=1 qwen-docker -c 'curl -s http://localhost:11434/v1/models'
```

**„model not found"** — der Name muss exakt dem entsprechen, was `docker-code models list` zeigt,
inklusive Tag. `qwen2.5-coder` ohne `:14b` ist ein anderer Name als `qwen2.5-coder:14b`.

**Der Agent zeigt JSON, statt etwas zu tun** — so etwas:

```
◆︎ { "name": "write_file", "arguments": { "file_path": "…", "content": "…" } }
```

Das ist ein **Modellproblem, kein Verbindungsproblem**. Ein Agent bekommt seine Werkzeuge über
`tools` und erwartet die Antwort im Feld `tool_calls`; ein Modell, das dafür nicht trainiert ist,
schreibt dieselbe Struktur stattdessen als Text in `content`. Der Agent hat nichts zu parsen und
zeigt den Text roh an. Erfundene Werkzeugnamen im JSON sind dasselbe Bild — dann hat das Modell die
Werkzeugliste nicht mehr im Kontext.

Welche Modelle das können, steht unter [Welches Modell für einen Agent](#welches-modell-für-einen-agent).
Nachprüfen lässt es sich in einem Aufruf, ohne Agent:

```bash
docker run --rm --network docker-code-net curlimages/curl -s \
  http://docker-code-ollama:11434/v1/chat/completions \
  -H 'content-type: application/json' -H 'authorization: Bearer docker-code-local' \
  -d '{"model":"<modell>","stream":false,
       "messages":[{"role":"user","content":"Write hi into a.txt"}],
       "tools":[{"type":"function","function":{"name":"write_file",
         "parameters":{"type":"object","properties":{"file_path":{"type":"string"},
                                                     "content":{"type":"string"}}}}}]}'
```

Kommt `"tool_calls": [...]` zurück, taugt das Modell als Agent. Steht die Funktion stattdessen als
Text in `"content"`, taugt es nicht — daran ändert keine Einstellung in docker-code oder im Agent
etwas.

**Gemini antwortet nicht** — dort steht das Gateway dazwischen:

```bash
docker-code models logs docker-code-litellm
```

Der Weg ohne Agent, zum Eingrenzen:

```bash
docker run --rm --network docker-code-net curlimages/curl -s \
  "http://docker-code-litellm:4000/v1beta/models/qwen2.5-coder:14b:generateContent" \
  -H "x-goog-api-key: docker-code-local" -H "content-type: application/json" \
  -d '{"contents":[{"parts":[{"text":"say OK"}]}]}'
```

**Alles ist langsam** — vermutlich rechnet es auf der CPU. `docker-code models status` sagt es in
zwei Zeilen; der ganze Ablauf zum Nachprüfen steht unter [GPU](#gpu).

---

## Kommandos

```bash
docker-code models up            # starten (idempotent)
docker-code models down          # stoppen und das Netz entfernen
docker-code models status        # Zustand, Speicherort, Belegung
docker-code models pull <modell>
docker-code models list
docker-code models rm <modell>
docker-code models run <modell>  # direkt mit dem Modell reden, ohne Agent
docker-code models logs [container]
```

Wenn etwas nicht startet, ist das eine Warnung und keine gescheiterte Session: der Agent läuft dann
mit seinem Cloud-Provider weiter. Ein Modell-Gateway ist weniger wert als die Session, die es sonst
verhindern würde.

## Platz

```bash
du -sh ~/docker-code/models/*
docker-code models rm qwen2.5-coder:14b
rm -rf ~/docker-code/models          # alles weg; beim nächsten `models up` wieder leer
```

Größenordnung für `qwen2.5-coder`: `0.5b` ~400 MB, `7b` ~4,7 GB, `14b` ~9 GB, `32b` ~20 GB.
