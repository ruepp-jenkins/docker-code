# syntax=docker/dockerfile:1
#
# Kiro CLI on the shared base. Build context is the repository root.

ARG BASE_IMAGE=ruepp/docker-code-base:latest
FROM ${BASE_IMAGE}

# The vendor's release channel, the same one cli.kiro.dev/install defaults to. There is no version
# to pin against: only the channel's `latest` directory is readable, and the checksums are published
# for whatever it currently holds.
ARG KIRO_CHANNEL=stable

# Not `curl https://cli.kiro.dev/install | bash`. That installer targets $HOME/.local/bin, which in
# this image is the bind-mount point the first real start replaces, and it stops to ask a question
# when it finds an installation already there. The archive it downloads carries its own install.sh,
# and that one installs into /usr/local/bin when Q_INSTALL_GLOBAL is set — the same system-wide
# location every other agent uses here. Q_SKIP_SETUP keeps it from writing shell integrations into
# root's home during the build.
#
# The checksum comes from the channel manifest, which is the file the vendor installer verifies
# against as well; skipping that step would leave an unverified download in an image that runs an
# agent with far-reaching permissions.
#
# This is a large install: kiro-cli is only the launcher and resolves kiro-cli-chat, the agent
# itself, on PATH — together with the shell-integration binary that is close to 900 MB unpacked.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) arch=x86_64 ;; \
        arm64) arch=aarch64 ;; \
        *) echo "no Kiro CLI build for $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    base="https://prod.download.cli.kiro.dev/${KIRO_CHANNEL}/latest"; \
    file="kirocli-${arch}-linux.zip"; \
    expected="$(curl -fsSL "${base}/manifest.json" \
        | jq -r --arg f "${file}" '.packages[] | select(.download | endswith($f)) | .sha256')"; \
    case "${expected}" in \
        [0-9a-f]*) ;; \
        *) echo "no checksum for ${file} in the ${KIRO_CHANNEL} manifest" >&2; exit 1 ;; \
    esac; \
    tmp="$(mktemp -d)"; \
    curl -fsSL -o "${tmp}/${file}" "${base}/${file}"; \
    echo "${expected}  ${tmp}/${file}" | sha256sum -c -; \
    unzip -q "${tmp}/${file}" -d "${tmp}"; \
    env Q_INSTALL_GLOBAL=1 Q_SKIP_SETUP=1 "${tmp}/kirocli/install.sh"; \
    rm -rf "${tmp}"

COPY agents/kiro/agent.env /etc/docker-code/agent.env

# The seeded settings file turns the auto-updater off, which is the rule for every tool in these
# images: it is installed system-wide as root while the session runs as `agent`, so an in-place
# update either fails or outlives the image it replaced.
COPY agents/kiro/defaults/ /opt/docker-code/defaults/

# `kiro-cli --version` and not `kiro-cli chat --version`: the chat subcommand authenticates before it
# parses anything, so in a build it would try to open a browser instead of printing a version.
#
# HOME is overridden for the smoke test because the image's HOME is the mount point, and a
# root-owned file created there during the build is what breaks the first real container start.
RUN set -eux; \
    env HOME=/root kiro-cli --version; \
    rm -rf /root/.kiro /root/.local/share/kiro-cli
