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

Eine GPU wird benutzt, wenn Docker eine gemeldet hat (`--gpus all`), sonst läuft es auf der CPU. Das
wird erkannt, nicht angenommen: eine GPU anzufordern, die es nicht gibt, ist ein harter
`docker run`-Fehler. Erzwingen lässt sich CPU-Betrieb mit `DOCKER_CODE_MODELS_GPU=0`.

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

**Alles ist langsam** — ohne GPU rechnet ein 14-B-Modell auf der CPU. `docker-code models status`
zeigt, ob der Container mit `--gpus all` gestartet wurde.

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
