# Images und Registry

## Die Namen

Ein Repository pro Image, nicht ein Repository mit agent-präfixierten Tags — eine Tag-Liste, in der
acht Tools ineinander verschachtelt sind, liest niemand.

```
ruepp/docker-code-base        die gemeinsame Schicht
ruepp/docker-code-claude      Basis + Claude Code
ruepp/docker-code-codex       Basis + Codex CLI
ruepp/docker-code-gemini      …
ruepp/docker-code-qwen  -opencode  -cursor  -copilot
```

| Zweig | Repository | Tags |
|---|---|---|
| `master` / `main` | `ruepp/docker-code-<id>` | `<JJJJMMTT>` und `latest` |
| jeder andere | `ruepp/docker-code-<id>-test` | `<branch>-<JJJJMMTT>` |

Ein anderer Namespace, an einer Stelle:

```bash
export DOCKER_CODE_NAMESPACE=meinefirma      # meinefirma/docker-code-claude:latest
export DOCKER_CODE_TAG=20260815              # eine bestimmte Version festnageln
export DOCKER_CODE_CLAUDE_IMAGE=ganz/anderes:1   # nur für einen Agent
```

## Keine Architektur-Tags

Beide Architekturen werden nativ auf je einer Maschine gebaut und **per Digest** gepusht, ohne Tag.
`scripts/docker_manifest.sh` fügt sie danach zu einer Manifest-Liste zusammen — und ist damit der
einzige Schritt in der ganzen Pipeline, der überhaupt je einen Tag schreibt.

Der Nutzen: kein `20260815-amd64` und `20260815-arm64`, die für immer in der Registry stehen bleiben,
und ein Build, der vorher stirbt, lässt die Tag-Liste unberührt. Es gibt nie einen Tag, der nur eine
Hälfte liefert.

Der Preis: der Digest muss von der Build-Maschine zur Manifest-Maschine — dafür ist der `stash` im
`Jenkinsfile` da.

## Reihenfolge

```
Prepare  →  Base (amd64 ‖ arm64)  →  Base manifest  →  Agents (7 × 2)  →  Agent manifests
```

Das Basis-Manifest muss fertig sein, bevor ein Agent baut: die Agent-Dockerfiles lösen ihre Basis
über einen Tag auf, und geschrieben wird der eben nur dort. Auf einem Branch zeigen sie auf die Basis
**dieses Branches** — eine Änderung an der Basis wird also von allen acht Agents getestet, bevor
irgendetwas auf `master` landet.

Die Test-Suite läuft genau einmal, in der `test`-Stage von `base/Dockerfile`. `verified` verweigert
das Image, wenn sie rot war, und jedes Agent-Image kopiert diesen Stempel — ein roter Test blockiert
also alle acht.

---

# Der Pull-Through-Cache

Ein Registry-Container als Proxy vor Docker Hub. Sessions können sich keinen Image-Store teilen —
zwei Daemons können keinen Data-Root teilen, containerd hält ein exklusives Lock —, aber sie können
sich teilen, was sie ziehen. Der zweite, dritte und vierte Pull desselben Basis-Images wird damit zu
einer Kopie über die lokale Bridge.

Er ist außerdem die Antwort auf Docker Hubs Rate-Limit: das zählt anonyme Pulls pro IP, und ein
Konto auf dem Mirror hebt es für jede Session dahinter an.

**Standardmäßig aus.** Es ist ein zusätzlicher Container auf deiner Maschine, und das sollte eine
Entscheidung sein und keine Überraschung.

```bash
export DOCKER_CODE_REGISTRY_MIRROR=1
```

| Variable | Standard | Bedeutung |
|---|---|---|
| `DOCKER_CODE_REGISTRY_MIRROR` | `0` | `1`, `0`, oder die URL eines Mirrors, den du selbst betreibst |
| `DOCKER_CODE_REGISTRY_UPSTREAM` | `https://registry-1.docker.io` | wovor der Cache sitzt |
| `DOCKER_CODE_REGISTRY_HOME` | `~/docker-code/registry/data` | wo die Blobs liegen |
| `DOCKER_CODE_REGISTRY_SUBNET` | `172.30.30.0/24` | leer überlässt die Wahl Docker |
| `DOCKER_CODE_REGISTRY_USERNAME` / `_PASSWORD` | — | Hub-Konto für das Rate-Limit |

```bash
docker-code registry start|stop|status
```

## Wie er sich verhält

- Ein Container auf einem eigenen Netz, **kein** veröffentlichter Port: es lauscht nichts Neues auf
  dem Host. In `DOCKER_CODE_NET=restricted` funktioniert er trotzdem, weil die Firewall im Container
  die Netze durchlässt, an denen er hängt.
- Der Zustand steht auf Container-Labels (Upstream, Store) und wird bei jedem Start verglichen. Passt
  etwas nicht, wird der Container neu gebaut — der Cache-Inhalt bleibt, weil ein Blob über seinen
  Digest adressiert ist und für jeden gültig bleibt, der das Verzeichnis wieder aufgreift.
- Der Letzte macht das Licht aus: Sessions werden über ihr Label gezählt, **über alle acht Agents
  hinweg**. Eine laufende Claude-Session hält den Mirror also für die Codex-Session am Leben, die
  gerade startet.
- Jeder Fehler ist eine Warnung und eine Session ohne Mirror. Ein Cache ist weniger wert als die
  Session, die er sonst verhindern würde.

## Andere Registries

Der Mirror gilt nur für Docker Hub — so funktioniert `--registry-mirror` in Docker. Für eine interne
Registry über einfaches HTTP:

```bash
export DOCKER_CODE_INSECURE_REGISTRIES="registry.intern:5000"
```

Das reicht den Host an den inneren Daemon durch; ohne das scheitert der Pull mit „server gave HTTP
response to HTTPS client", weil per Default nur `127.0.0.0/8` ausgenommen ist.

In `DOCKER_CODE_NET=restricted` braucht sie zusätzlich einen Platz in der Allowlist:

```bash
export DOCKER_CODE_ALLOW_DOMAINS="registry.intern"
```
