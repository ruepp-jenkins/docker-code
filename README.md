# docker-code

Sieben TUI-Coding-Agents, jeder in seinem eigenen Container, jeder mit seinem eigenen persistenten
Verzeichnis — und ein gemeinsamer Speicher für lokale Modelle, den sie sich alle teilen.

| Aufruf | Tool | Lokale Modelle |
|---|---|---|
| `claude-docker` | [Claude Code](https://docs.claude.com/en/docs/claude-code) | ja, über Ollama |
| `codex-docker` | [OpenAI Codex CLI](https://github.com/openai/codex) | ja, über Ollama |
| `gemini-docker` | [Gemini CLI](https://github.com/google-gemini/gemini-cli) | ja, über das LiteLLM-Gateway |
| `qwen-docker` | [Qwen Code](https://github.com/QwenLM/qwen-code) | ja, über Ollama |
| `opencode-docker` | [OpenCode](https://opencode.ai) | ja, über Ollama |
| `cursor-agent-docker` | [Cursor CLI](https://cursor.com/docs/cli/overview) | nein (Cloud-only) |
| `copilot-docker` | [GitHub Copilot CLI](https://github.com/github/copilot-cli) | nein (Cloud-only) |

Der Suffix `-docker` ist Absicht: `claude` bleibt `claude`, `gemini` bleibt `gemini`. Nichts, was du
heute installiert hast, wird verdeckt.

---

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/ruepp-jenkins/docker-code/master/install.sh | bash
docker-code build          # einmalig: Basis-Image + alle Agents bauen
```

Der Installer legt den Baum unter `~/.local/share/docker-code` ab und verlinkt `docker-code` plus
einen Wrapper pro Agent nach `~/.local/bin`. Er benutzt **kein** sudo, schreibt in **keine**
Shell-Startdatei und legt **keinen** Alias an.

```bash
cd ~/mein-projekt
claude-docker              # los
```

---

## Wo alles liegt

Ein einziges Verzeichnis, `~/docker-code`:

```
~/docker-code/
├── claude/      ← das komplette HOME des claude-Containers
├── codex/       ← das komplette HOME des codex-Containers
├── gemini/  qwen/  opencode/  cursor/  copilot/
├── shared/      optional, in jedem Agent unter ~/shared
├── models/      die Gewichte, die sich alle teilen
│   ├── ollama/  gguf/  hf/  litellm/
└── registry/    Pull-Through-Cache für Docker Hub
```

`~/docker-code/gemini/` **ist** `/home/agent` im Gemini-Container. Alles, was das Tool anlegt —
Login, Sessions, Settings, MCP-Server, Shell-History — landet dort und überlebt jeden Neustart. Auf
dem Host ist es ein ganz normaler Ordner: `ls`, `du`, `tar`, `rm`.

```bash
tar czf backup.tar.gz -C ~ docker-code     # Backup
rm -rf ~/docker-code/gemini                # nur Gemini zurücksetzen
```

Ein anderer Ort: `export DOCKER_CODE_HOME=/pfad/dazu` (muss absolut sein).

---

## Was ein Container sieht

| erreichbar | nicht erreichbar |
|---|---|
| `~/docker-code/<agent>/` (rw) — sein HOME | dein echtes Home-Verzeichnis |
| das Verzeichnis, aus dem du ihn gestartet hast (rw) | jeder andere Pfad auf dem Host |
| `~/docker-code/models/` (ro, nur mit `DOCKER_CODE_LOCAL=1`) | `/var/run/docker.sock` — **nie** gemountet |
| explizite Extras via `DOCKER_CODE_MOUNT` | `~/.gitconfig`, `$SSH_AUTH_SOCK` (opt-in, standardmäßig aus) |

Der Start aus dem Home-Verzeichnis oder aus `/` wird **abgelehnt**, nicht nur bemängelt.
`tests/isolation.bats` hält diese Liste als Negativ-Assertion fest, damit sie nicht unbemerkt wächst.

**Ehrlich dazu:** Der innere Docker-Daemon läuft standardmäßig `privileged`, weil das der einzige
Modus ist, der auf allen getesteten Hosts funktioniert — unter Linux wie unter macOS. Ein
privilegierter Container ist damit **keine Sicherheitsgrenze zum Host**. Was oben steht, ist eine
Dateisystem-Abschirmung: dein Home und deine Credentials sind außen vor. Es ist kein Ausbruchsschutz.
Wer den will: `DOCKER_CODE_DIND=0` (kein innerer Daemon, kein `--privileged`) und
`DOCKER_CODE_NET=restricted`.

---

## Knöpfe

Alles per Umgebungsvariable, damit es sich mit dem Wrapper komponiert. Präfix `DOCKER_CODE_`, für
einen einzelnen Agent `DOCKER_CODE_<AGENT>_` (z. B. `DOCKER_CODE_CODEX_IMAGE`).

| Variable | Standard | Wirkung |
|---|---|---|
| `YOLO=1` | `0` | ohne Berechtigungsabfragen — das jeweils richtige Flag pro Tool |
| `NET=restricted` | `full` | Egress nur zu den Domains des Tools (iptables + ipset) |
| `NET=none` | | gar kein Netz |
| `DIND=0` \| `rootless` \| `privileged` | `privileged` | innerer Docker-Daemon |
| `LOCAL=1` | `0` | die gemeinsamen lokalen Modelle benutzen |
| `LOCAL_MODEL=<name>` | | welches (`docker-code models list`) |
| `SHELL=1` | `0` | statt des Agents eine Bash im Container |
| `SHARED=1` | `0` | `~/docker-code/shared` unter `~/shared` einhängen |
| `MOUNT="/a:/a:ro /b:/b"` | | zusätzliche Bind-Mounts |
| `ENV="GH_TOKEN,FOO"` | | zusätzliche Variablen durchreichen |
| `GITCONFIG=1` / `SSH=1` | `0` | `~/.gitconfig` (ro) bzw. den SSH-Agent durchreichen |
| `REGISTRY_MIRROR=1` | `0` | Pull-Through-Cache vor Docker Hub ([REGISTRY.md](REGISTRY.md)) |
| `DRY_RUN=1` | `0` | das `docker run` ausgeben statt es auszuführen |

```bash
DOCKER_CODE_YOLO=1 DOCKER_CODE_NET=restricted claude-docker
DOCKER_CODE_SHELL=1 opencode-docker           # nachsehen, was im Container los ist
DOCKER_CODE_DRY_RUN=1 qwen-docker             # nur zeigen, was passieren würde
```

### Dauerhaft, in der `.bashrc`

`DOCKER_CODE_<AGENT>_<KNOPF>` schlägt `DOCKER_CODE_<KNOPF>` schlägt den Standard — und zwar für jeden
Knopf aus der Tabelle. Damit lässt sich pro Agent entscheiden, was sonst nur pauschal ginge:

```bash
export PATH="$HOME/.local/bin:$PATH"

export DOCKER_CODE_QWEN_LOCAL=1               # Qwen rechnet lokal …
export DOCKER_CODE_QWEN_LOCAL_MODEL=qwen2.5-coder:14b
export DOCKER_CODE_CLAUDE_YOLO=1              # … Claude ohne Rückfragen, aber in der Cloud
export DOCKER_CODE_NET=restricted             # für alle: Egress nur zu den Domains des Tools
export DOCKER_CODE_CODEX_NET=full             # außer für Codex
```

Der vollständige Block für lokale Modelle — samt der Variablen, die hier gerade **nicht** hingehören,
weil sie auch Sessions ohne lokale Modelle treffen würden — steht in
[LOCAL-MODELS.md](LOCAL-MODELS.md#dauerhaft-der-bashrc-block).

Prüfen, ohne etwas zu starten:

```bash
DOCKER_CODE_DRY_RUN=1 qwen-docker
```

---

## Umgebungsvariablen, die durchgereicht werden

Eine explizite Liste, keine Pauschalkopie: ein Gemini-Container hat nichts mit dem
`ANTHROPIC_API_KEY` zu tun, der in deiner Shell exportiert ist.

- **Pro Agent**: `AGENT_ENV_VARS` in `agents/<id>/agent.env` — z. B. `ANTHROPIC_API_KEY` für Claude,
  `OPENAI_*` für Codex und Qwen, `GH_TOKEN` für Copilot.
- **Für alle**: `TERM`, `COLORTERM`, `TZ`, `LANG`, die Proxy-Variablen, `NODE_EXTRA_CA_CERTS`,
  `DO_NOT_TRACK`.
- **Zusätzlich**: `DOCKER_CODE_ENV="MEIN_TOKEN,NOCH_EINS"`.

Nur gesetzte Variablen werden übergeben — eine ungesetzte bleibt drinnen ungesetzt, statt als leerer
String einen Container-Default zu überschreiben.

---

## Lokale Modelle in drei Zeilen

```bash
docker-code models up
docker-code models pull qwen2.5-coder:14b
DOCKER_CODE_LOCAL=1 DOCKER_CODE_LOCAL_MODEL=qwen2.5-coder:14b qwen-docker
```

Damit ist nichts von Hand einzustellen. Wer trotzdem selbst konfiguriert und nach einem **API-Key**
gefragt wird: **`docker-code-local`**, für alle Endpunkte. `docker-code models status` zeigt ihn
zusammen mit den URLs an. Alles Weitere in [LOCAL-MODELS.md](LOCAL-MODELS.md).

Lokale Modelle können: Claude Code, Codex, Qwen, OpenCode und Gemini CLI. Cursor und Copilot rechnen
serverseitig beim Anbieter und sagen das, wenn man es versucht.

---

## Weiteres

- **[AGENTS.md](AGENTS.md)** — ein achtes Tool hinzufügen. Kurzfassung: ein Ordner unter `agents/`.
- **[LOCAL-MODELS.md](LOCAL-MODELS.md)** — der gemeinsame Modellspeicher, Ollama und das Gateway.
- **[REGISTRY.md](REGISTRY.md)** — Images, Tags und der Pull-Through-Cache.

```bash
docker-code list       # welche Agents es gibt
docker-code doctor     # was installiert, gültig und gebaut ist
docker-code help       # alle Kommandos
```

---

## Updates

Zwei getrennte Dinge, und deshalb zwei Befehle: die **Images** (ein Tool hat eine neue Version) und
**docker-code selbst** (ein Agent kommt dazu, ein Wrapper ändert sich).

```bash
docker-code update            # die Images ziehen — alle
docker-code update claude     # oder nur einen
docker-code build claude      # oder selbst bauen statt ziehen

docker-code self-update       # docker-code, die Agent-Definitionen und die Wrapper
```

`self-update` weiß, woher deine Installation stammt: `install.sh` hinterlegt das beim Installieren in
`.install-source`. Eine Installation aus dem Netz holt sich denselben Branch wieder, eine mit
`--local` gebaute aktualisiert aus genau dem Checkout — kein stilles Umschalten auf GitHub. Einen
anderen Stand ziehen:

```bash
docker-code self-update --ref v2
```

Neue Agents bringen einen neuen Wrapper mit; `self-update` legt den Symlink an und nennt die Zahl der
verlinkten Befehle. Danach fehlt nur noch das Image: `docker-code update <agent>` oder
`docker-code build <agent>`.

Arbeitest du direkt im Checkout — die Wrapper zeigen dann dorthin —, ist `git pull` das Update, und
`self-update` sagt dir das, statt so zu tun als hätte es etwas getan.

Die Tools selbst sind systemweit im Image installiert, mit abgeschaltetem Auto-Updater. Ein neues
Image ist damit der einzige Weg, auf dem eine neue Tool-Version bei dir ankommt — und es fasst dein
`~/docker-code` nicht an: kein neuer Login, keine verlorenen Sessions. Die CI baut neu, wenn eines
der Tools eine neue Version veröffentlicht oder das Ubuntu-Basis-Image sich bewegt.

Deinstallieren, ohne den Zustand zu verlieren:

```bash
install.sh --uninstall        # entfernt Befehle und Installation, ~/docker-code bleibt
```

---

## Entwicklung

```bash
bats tests/            # die ganze Suite, ohne Docker-Daemon
./scripts/test.sh      # dieselbe Suite wie in der CI, mit JUnit-Report
./scripts/build.sh     # Basis + alle Agents lokal
```

Die Suite läuft in der `test`-Stage von `base/Dockerfile`, und `verified` verweigert das Image, wenn
sie rot ist. Jedes Agent-Image kopiert diesen Stempel — ein roter Test blockiert also alle sieben,
nicht nur den, dessen Dockerfile gerade angefasst wurde.

Möglich ist das durch die Dry-Run-Naht: alles, was `bin/docker-code` vor dem Start tut, ist reine
Kommandokonstruktion, also eine Funktion von der Umgebung auf ein argv — prüfbar ohne Daemon.
