# syntax=docker/dockerfile:1
#
# Mistral Vibe on the shared base. Build context is the repository root.

ARG BASE_IMAGE=ruepp/docker-code-base:latest
FROM ${BASE_IMAGE}

ARG MISTRAL_VIBE_VERSION=latest

# The only Python tool of the seven, so it gets pipx rather than npm — and pipx has to be pointed
# away from the home directory before it runs. Its default is ~/.local/share/pipx, which is inside
# the bind mount: the venv would vanish behind the user's own home on the first real start, and the
# symlink in ~/.local/bin would dangle. /opt/pipx plus /usr/local/bin survives the mount.
ENV PIPX_HOME=/opt/pipx \
    PIPX_BIN_DIR=/usr/local/bin

# Vibe checks for a new release and can update itself in place. Both are pointless here and worse
# than pointless: the tool is installed system-wide from the image, so anything it writes at runtime
# is lost on the next `docker-code update` — and a half-updated venv is not. A new image is the
# supported path, exactly as with the npm-installed agents.
ENV VIBE_ENABLE_UPDATE_CHECKS=false \
    VIBE_ENABLE_AUTO_UPDATE=false

RUN set -eux; \
    if [ "${MISTRAL_VIBE_VERSION}" = "latest" ]; then \
        spec="mistral-vibe"; \
    else \
        spec="mistral-vibe==${MISTRAL_VIBE_VERSION}"; \
    fi; \
    pipx install "${spec}"; \
    rm -rf /root/.cache/pip

COPY agents/mistral/agent.env /etc/docker-code/agent.env

RUN set -eux; \
    env HOME=/root vibe --version; \
    rm -rf /root/.vibe /root/.cache
