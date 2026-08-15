# Ein Tool hinzufügen

Ein Ordner unter `agents/`. Mehr nicht — Wrapper, Installer, CI-Matrix und Tests lesen die Liste aus
`agents/*/agent.env`, es gibt keine zweite Stelle, an der Agents aufgezählt werden.

```
agents/meintool/
├── agent.env      Pflicht — die Metadaten
├── Dockerfile     Pflicht — ~20 Zeilen
└── defaults/      optional — Configs, die beim ersten Start gesetzt werden
```

Danach:

```bash
ln -s docker-code bin/meintool-docker
bats tests/registry.bats        # validiert den neuen Agent automatisch mit
./scripts/build.sh meintool
DOCKER_CODE_DRY_RUN=1 ./bin/meintool-docker
```

---

## `agent.env`

Ein flaches `KEY=value`-Format. Es wird **gelesen, nicht gesourct** — eine unbekannte Schlüssel ist
ein Fehler mit Zeilenangabe, kein stilles Ignorieren. Werte dürfen `"…"`, `'…'` oder nackt sein, und
eine Zeile darf mit `\` in der nächsten fortgesetzt werden.

### Pflicht

| Schlüssel | Bedeutung |
|---|---|
| `AGENT_ID` | muss dem Ordnernamen entsprechen |
| `AGENT_BIN` | das Kommando im Container |
| `AGENT_WRAPPER` | der Name auf dem Host — **muss** auf `-docker` enden und darf nicht `AGENT_BIN` sein |

### Optional

| Schlüssel | Standard | Bedeutung |
|---|---|---|
| `AGENT_TITLE` | `AGENT_ID` | Klartextname für Meldungen |
| `AGENT_HOSTNAME` | `AGENT_ID` | Hostname des Containers |
| `AGENT_ALIASES` | — | weitere Wrapper-Namen, leerzeichengetrennt |
| `AGENT_YOLO_ARGS` | — | Flags, die `DOCKER_CODE_YOLO=1` voranstellt |
| `AGENT_YOLO_SKIP` | — | Subkommandos, die kein YOLO-Flag bekommen (`mcp`, `login`, …) |
| `AGENT_PERMISSION_FLAGS` | `AGENT_YOLO_ARGS` | Flags, deren Anwesenheit die YOLO-Injektion unterdrückt |
| `AGENT_ROOT_ENV` | — | Variablen, die als root gesetzt werden (z. B. `IS_SANDBOX=1`) |
| `AGENT_ENV_VARS` | — | Variablen, die vom Host durchgereicht werden |
| `AGENT_DOMAINS` | — | Hosts für `DOCKER_CODE_NET=restricted`; der erste ist die Kontrollprobe |
| `AGENT_LOCAL_MODE` | `none` | siehe unten |
| `AGENT_LOCAL_ENV` | — | `;`-getrennte `NAME=wert`-Liste; `%u` = Gateway-URL, `%m` = Modellname |
| `AGENT_LOCAL_ARGS` | — | argv-Zusatz für lokale Modelle; `%m` = Modellname |
| `AGENT_NOTE` | — | ein Satz, der einer Einschränkung erklärt — Pflicht bei `AGENT_LOCAL_MODE=none` |

### `AGENT_LOCAL_MODE`

Welches Wire-Format das Tool spricht, und damit, wohin es zeigt:

| Modus | Ziel | Für Tools, die … |
|---|---|---|
| `none` | — | keine lokalen Modelle können (dann `AGENT_NOTE` setzen) |
| `openai-compat` | Ollama, `:11434` | eine OpenAI-kompatible Base-URL akzeptieren |
| `ollama-anthropic` | Ollama, `:11434` | das Anthropic-Messages-Format sprechen |
| `litellm-gemini` | Gateway, `:4000` | nur Googles eigenes Format sprechen |
| `litellm-openai` / `litellm-anthropic` | Gateway, `:4000` | eine Übersetzung brauchen, die Ollama nicht liefert |

Beide URLs sind `localhost` — der Container bekommt Port-Weiterleitungen dorthin, weil mehrere dieser
Tools `localhost` fest verdrahten. Details: [LOCAL-MODELS.md](LOCAL-MODELS.md).

---

## `Dockerfile`

Build-Kontext ist immer das Repo-Root, nicht der Agent-Ordner.

```dockerfile
# syntax=docker/dockerfile:1
ARG BASE_IMAGE=ruepp/docker-code-base:latest
FROM ${BASE_IMAGE}

ARG MEINTOOL_VERSION=latest
RUN set -eux; \
    npm install -g "meintool@${MEINTOOL_VERSION}"; \
    npm cache clean --force

COPY agents/meintool/agent.env /etc/docker-code/agent.env
COPY agents/meintool/defaults/ /opt/docker-code/defaults/

RUN set -eux; \
    env HOME=/root meintool --version; \
    rm -rf /root/.meintool
```

Drei Dinge, die `tests/registry.bats` und `tests/image.bats` erzwingen, jedes aus einem konkreten
Grund:

1. **`COPY agents/<id>/agent.env /etc/docker-code/agent.env`** — `launch.sh` und `init-firewall.sh`
   lesen diese Datei zur Laufzeit. Ohne sie startet der Container und scheitert erst im letzten
   Moment.
2. **`<bin> --version` als Smoke-Test** — läuft pro Zielarchitektur, damit ein arm64-Image, das seine
   eigenen Binaries nicht ausführen kann, gar nicht erst gepusht wird.
3. **`env HOME=/root …` plus Aufräumen** — das HOME des Images ist der Mountpoint des Bind-Mounts.
   Eine root-eigene Datei, die dort beim Bauen entsteht, ist genau das, was den ersten echten Start
   kaputt macht.

Und eines, das nicht erzwungen werden kann, aber genauso wichtig ist: **installiere nichts nach
`/home/agent`**. Der Bind-Mount ersetzt das Verzeichnis beim ersten Start, das Tool wäre danach weg.
Cursors Installer macht genau das per Default — deshalb bekommt er in `agents/cursor/Dockerfile` ein
eigenes `HOME=/opt/cursor` und einen Symlink nach `/usr/local/bin`.

Wer ein eigenes apt-Repository hinzufügt, pinnt den Schlüssel auf seinen Fingerprint — siehe
`agents/claude/Dockerfile`. Ein Repository mit ungeprüftem Schlüssel ist ein Supply-Chain-Loch in
einem Image, dessen ganze Aufgabe es ist, einen Agent mit weitreichenden Rechten laufen zu lassen.

---

## `defaults/`

Spiegelt das Home-Verzeichnis. `defaults/.codex/config.toml` landet als `~/.codex/config.toml`.

Kopiert wird **pro Datei und nie über etwas Bestehendes**: wer schon ein `~/.config/opencode/` hat,
bekommt trotzdem eine neue Default-Datei daneben, aber seine eigenen bleiben unangetastet. Dadurch
erreicht auch ein Default, der erst in einem späteren Image dazukommt, bestehende Installationen.

Das Seeding passiert bei jedem Start, weil Docker einen Bind-Mount — anders als ein leeres Named
Volume — nicht aus dem Image vorbefüllt.

---

## Wenn CI mitspielen soll

Installiert das Tool von npm, gehört ein `URLTriggerEntry` in den `Jenkinsfile` — sonst erreicht ein
Release nie jemanden, weil die Auto-Updater der Tools abgeschaltet sind. `tests/pipeline.bats` prüft
das und nennt das fehlende Paket beim Namen.

Alles andere in der Pipeline — die Build-Matrix, die Manifest-Schritte — liest die Agent-Liste zur
Laufzeit aus `agents/` und braucht keine Änderung.
