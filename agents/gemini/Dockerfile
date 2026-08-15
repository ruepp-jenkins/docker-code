# syntax=docker/dockerfile:1
#
# Gemini CLI on the shared base. Build context is the repository root.

ARG BASE_IMAGE=ruepp/docker-code-base:latest
FROM ${BASE_IMAGE}

ARG GEMINI_VERSION=latest

RUN set -eux; \
    npm install -g "@google/gemini-cli@${GEMINI_VERSION}"; \
    npm cache clean --force

COPY agents/gemini/agent.env /etc/docker-code/agent.env

# Not under /opt/docker-code/defaults: that directory is seeded into the user's home, and this file
# must never become part of their own configuration. It is read only when a session asks for a local
# model, through GEMINI_CLI_SYSTEM_SETTINGS_PATH — see agents/gemini/agent.env.
COPY agents/gemini/local-settings.json /opt/docker-code/gemini-local-settings.json

RUN set -eux; \
    env HOME=/root gemini --version; \
    rm -rf /root/.gemini
