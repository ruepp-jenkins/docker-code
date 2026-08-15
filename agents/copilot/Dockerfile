# syntax=docker/dockerfile:1
#
# GitHub Copilot CLI on the shared base. Build context is the repository root.

ARG BASE_IMAGE=ruepp/docker-code-base:latest
FROM ${BASE_IMAGE}

ARG COPILOT_VERSION=latest

RUN set -eux; \
    npm install -g "@github/copilot@${COPILOT_VERSION}"; \
    npm cache clean --force

COPY agents/copilot/agent.env /etc/docker-code/agent.env

# COPILOT_HOME replaces the whole ~/.copilot path. It is left at its default here on purpose: the
# default is inside the bind-mounted home, so it persists without being named.
RUN set -eux; \
    env HOME=/root COPILOT_HOME=/root/.copilot copilot --version; \
    rm -rf /root/.copilot
