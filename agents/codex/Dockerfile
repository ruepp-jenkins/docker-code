# syntax=docker/dockerfile:1
#
# OpenAI Codex CLI on the shared base. Build context is the repository root.

ARG BASE_IMAGE=ruepp/docker-code-base:latest
FROM ${BASE_IMAGE}

ARG CODEX_VERSION=latest

RUN set -eux; \
    npm install -g "@openai/codex@${CODEX_VERSION}"; \
    npm cache clean --force

COPY agents/codex/agent.env /etc/docker-code/agent.env
COPY agents/codex/defaults/ /opt/docker-code/defaults/

RUN set -eux; \
    env HOME=/root CODEX_HOME=/root/.codex codex --version; \
    rm -rf /root/.codex
