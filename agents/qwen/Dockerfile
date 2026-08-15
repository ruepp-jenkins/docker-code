# syntax=docker/dockerfile:1
#
# Qwen Code on the shared base. Build context is the repository root.

ARG BASE_IMAGE=ruepp/docker-code-base:latest
FROM ${BASE_IMAGE}

ARG QWEN_VERSION=latest

RUN set -eux; \
    npm install -g "@qwen-code/qwen-code@${QWEN_VERSION}"; \
    npm cache clean --force

COPY agents/qwen/agent.env /etc/docker-code/agent.env

RUN set -eux; \
    env HOME=/root qwen --version; \
    rm -rf /root/.qwen
