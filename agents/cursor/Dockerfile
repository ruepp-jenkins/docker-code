# syntax=docker/dockerfile:1
#
# Cursor CLI on the shared base. Build context is the repository root.

ARG BASE_IMAGE=ruepp/docker-code-base:latest
FROM ${BASE_IMAGE}

# The installer drops the agent into $HOME/.local/share/cursor-agent and links it from
# $HOME/.local/bin. In this image HOME is the bind-mounted persistent directory, so installing there
# would put the binary somewhere the first real container start replaces — the tool would simply be
# gone. Installing under a HOME of its own and linking into /usr/local/bin keeps it in the image,
# which is also what makes a new image the only update path.
RUN set -eux; \
    install -d -m 0755 /opt/cursor; \
    env HOME=/opt/cursor bash -c 'curl -fsS https://cursor.com/install | bash'; \
    ln -sf /opt/cursor/.local/bin/cursor-agent /usr/local/bin/cursor-agent; \
    chmod -R a+rX /opt/cursor

COPY agents/cursor/agent.env /etc/docker-code/agent.env

# No agents/cursor/defaults/ here on purpose: cursor-agent has no file-based global instructions.
# AGENTS.md is read per-project, and "User Rules" live in the user's Cursor account rather than on
# disk, so there is nowhere under the bind-mounted home to seed the "you have an inner Docker daemon"
# note every other agent gets. If cursor-agent grows a home-directory instructions file, seed it here.

RUN set -eux; \
    env HOME=/root cursor-agent --version; \
    rm -rf /root/.cursor /root/.config/cursor
