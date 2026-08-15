# syntax=docker/dockerfile:1
#
# OpenCode on the shared base. Build context is the repository root.

ARG BASE_IMAGE=ruepp/docker-code-base:latest
FROM ${BASE_IMAGE}

ARG OPENCODE_VERSION=latest

RUN set -eux; \
    npm install -g "opencode-ai@${OPENCODE_VERSION}"; \
    npm cache clean --force

COPY agents/opencode/agent.env /etc/docker-code/agent.env
COPY agents/opencode/defaults/ /opt/docker-code/defaults/

# OpenCode scatters its state over ~/.config/opencode, ~/.local/share/opencode and ~/.cache/opencode.
# All three are inside the bind-mounted home, so none of them needs a variable pointing at it — which
# is the reason this project mounts the whole home rather than named config directories.
ENV OPENCODE_DISABLE_AUTOUPDATE=1

RUN set -eux; \
    env HOME=/root opencode --version; \
    rm -rf /root/.config/opencode /root/.local/share/opencode /root/.cache/opencode
