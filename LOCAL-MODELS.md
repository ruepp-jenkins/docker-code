# Lokale Modelle

Ein Modellspeicher für alle Agents. Sieben Tools, die jeweils ihre eigene Kopie eines 20-GB-Modells
halten, wären 140 GB derselben Bytes — hier liegt es einmal unter `~/docker-code/models/`, und jeder
Container spricht denselben Daemon an.

```bash
docker-code models up                       # Ollama + Gateway starten
docker-code models pull qwen3-coder:7b       # ein Modell holen
docker-code models list                      # was da ist

cd ~/mein-projekt
DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3-coder:7b qwen-docker
```

Dauerhaft, für alle Agents:

```bash
export DOCKER_CODE_LOCAL=1
export DOCKER_CODE_LOCAL_MODEL=qwen3-coder:7b
```

---

## Was läuft

Zwei Container auf einem eigenen Netz `docker-code-net`:

| Container | Image | Aufgabe |
|---|---|---|
| `docker-code-ollama` | `ollama/ollama` | hält die Gewichte, serviert OpenAI- **und** Anthropic-Format |
| `docker-code-litellm` | `ghcr.io/berriai/litellm:main-stable` | übersetzt in Formate, die Ollama nicht selbst spricht |

Keiner von beiden veröffentlicht einen Port auf dem Host. Die Agents erreichen sie über das
Docker-Netz. Wer sie doch auf dem Host haben will:

```bash
DOCKER_CODE_MODELS_PUBLISH=1 docker-code models up    # bindet an 127.0.0.1
```

Eine GPU wird benutzt, wenn Docker eine gemeldet hat (`--gpus all`), sonst läuft es auf der CPU. Das
wird erkannt, nicht angenommen: eine GPU anzufordern, die es nicht gibt, ist ein harter
`docker run`-Fehler.

---

## Warum ein Gateway daneben steht

Ollama spricht seit Januar 2026 selbst das Anthropic-Messages-Format und schon länger das
OpenAI-Format. Damit sind vier der sieben Tools direkt versorgt. Gemini CLI spricht aber
ausschließlich Googles eigenes Format — dafür ist LiteLLM da.

Die Konfiguration liegt in `~/docker-code/models/litellm/config.yaml`, wird beim ersten Start
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

Gemini CLI wird auf die **Wurzel** des Gateways gezeigt, nicht auf dessen `/gemini`-Pfad. Das
`@google/genai`-SDK hängt selbst `/v1beta/models/<modell>:generateContent` an, und genau diesen Pfad
bedient LiteLLM aus seiner eigenen Modellliste. `/gemini` ist etwas anderes: ein Pass-Through zu
Google AI Studio — die Anfrage ginge also ins Internet statt zu Ollama.

Nachprüfen lässt sich das ohne Agent:

```bash
docker run --rm --network docker-code-net curlimages/curl -s \
  "http://docker-code-litellm:4000/v1beta/models/qwen2.5-coder:0.5b:generateContent" \
  -H "x-goog-api-key: docker-code-local" -H "content-type: application/json" \
  -d '{"contents":[{"parts":[{"text":"say OK"}]}]}'
```

Wenn Gemini CLI mit einem lokalen Modell nicht antwortet, ist dieses Gateway die Stelle zum
Nachsehen:

```bash
docker-code models logs docker-code-litellm
```

---

## Die localhost-Brücke

Der Container bekommt beim Start zwei Weiterleitungen auf `127.0.0.1`:

```
localhost:11434  ->  docker-code-ollama:11434
localhost:4000   ->  docker-code-litellm:4000
```

Das ist kein Umweg, sondern der Punkt. Mehrere dieser Tools verdrahten `localhost` fest — Codex'
eingebauter `--oss`-Pfad ignoriert `base_url` komplett ([openai/codex#8240](https://github.com/openai/codex/issues/8240)),
und mehr als eine Provider-Integration nimmt irgendwo unterhalb ihrer Konfigurationsoberfläche
`127.0.0.1` an. Mit der Weiterleitung haben sie schlicht recht, und ein Tool, das später dazukommt,
erbt dieselbe funktionierende Annahme.

Läuft `socat` nicht oder ist ein Port belegt, steht der Grund in
`~/docker-code/<agent>/.docker-code/local-models.log`.

---

## Was welches Tool bekommt

| Agent | zeigt auf | gesetzt wird |
|---|---|---|
| `qwen` | Ollama `/v1` | `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `OPENAI_MODEL` |
| `codex` | Ollama `/v1` | `OPENAI_BASE_URL`, `OPENAI_API_KEY` + `--config model_provider=dockercode --model …` |
| `opencode` | Ollama `/v1` | Provider-Block in `opencode.json` + `--model dockercode/…` |
| `claude` | Ollama, Anthropic-Route | `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL` |
| `gemini` | Gateway (Wurzel) | `GOOGLE_GEMINI_BASE_URL`, `GEMINI_API_KEY` |
| `cursor`, `copilot` | — | nichts; die Modelle laufen serverseitig beim Anbieter |

Nachsehen, ohne etwas zu starten:

```bash
DOCKER_CODE_DRY_RUN=1 DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen3-coder:7b claude-docker
```

Bei `cursor` und `copilot` sagt der Wrapper, dass `DOCKER_CODE_LOCAL` hier nichts bewirkt, und
startet trotzdem — statt schweigend nichts zu tun.

---

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

---

## Platz

```bash
du -sh ~/docker-code/models/*
docker-code models rm qwen3-coder:7b
rm -rf ~/docker-code/models          # alles weg; beim nächsten `models up` wieder leer
```
