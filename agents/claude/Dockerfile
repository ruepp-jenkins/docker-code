# syntax=docker/dockerfile:1
#
# Claude Code on the shared base. Build context is the repository root.

ARG BASE_IMAGE=ruepp/docker-code-base:latest
FROM ${BASE_IMAGE}

# `latest` ships every Claude Code release as it lands, `stable` trails it by about a week.
ARG CLAUDE_CHANNEL=latest
# Empty means "whatever the channel currently offers". Set to e.g. 2.1.233-1 for a reproducible pin.
ARG CLAUDE_VERSION=

# The apt repository rather than npm: it is the vendor's own channel, and the key is pinned to the
# fingerprint Anthropic publishes — same rule as every repository in the base image.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o /etc/apt/keyrings/claude-code.asc; \
    actual="$(gpg --show-keys --with-colons /etc/apt/keyrings/claude-code.asc | awk -F: '/^fpr:/{print $10; exit}')"; \
    expected=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE; \
    if [ "${actual}" != "${expected}" ]; then \
        echo "key fingerprint mismatch: got ${actual}, want ${expected}" >&2; exit 1; \
    fi; \
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/${CLAUDE_CHANNEL} ${CLAUDE_CHANNEL} main" \
        > /etc/apt/sources.list.d/claude-code.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "claude-code${CLAUDE_VERSION:+=${CLAUDE_VERSION}}"

COPY agents/claude/agent.env /etc/docker-code/agent.env
COPY agents/claude/defaults/ /opt/docker-code/defaults/

# Claude Code is installed system-wide, outside the persistent home, precisely so that a new image is
# the update path. An in-place auto-update would write into the bind mount and then outlive every
# later image release, which is the failure mode this avoids.
#
# HOME is overridden for the smoke test: the image's HOME is the mount point, and a root-owned file
# created there during the build is exactly what breaks the first real container start.
RUN set -eux; \
    env HOME=/root CLAUDE_CONFIG_DIR=/root/.claude claude --version; \
    rm -rf /root/.claude /root/.claude.json
