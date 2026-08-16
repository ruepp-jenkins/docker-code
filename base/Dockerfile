# syntax=docker/dockerfile:1
#
# The shared base for every agent image: an Ubuntu with the toolchain an agent needs, an inner
# Docker daemon, the container user, and the entrypoint chain. Agent images are this plus one tool.
#
# Build context is the repository root (see scripts/build.sh), not base/.
#
# Stages:
#   base          the runtime layer every agent inherits
#   test          shellcheck + bats, pinned to the build platform so it never runs under emulation
#   test-results  scratch stage holding only the JUnit report, for `--target test-results`
#   verified      fails the build when a test failed
#   final         base, plus proof that `verified` succeeded

ARG UBUNTU_TAG=24.04

# ==================================================================================================
# base
# ==================================================================================================
FROM ubuntu:${UBUNTU_TAG} AS base

# The Docker CE repository is per Ubuntu release, so this moves together with UBUNTU_TAG.
ARG DOCKER_SUITE=noble
# 22 is the floor: @anthropic-ai/claude-code and @qwen-code/qwen-code both declare node >= 22.
ARG NODE_MAJOR=22

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# --------------------------------------------------------------------------------------------------
# Base packages
#
# socat is not incidental: it is what bridges `localhost` inside the container to the shared Ollama
# and LiteLLM containers, because several of these tools hard-code localhost for local models.
# --------------------------------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg \
        git git-lfs openssh-client \
        jq ripgrep less vim nano unzip zip xz-utils tar \
        procps psmisc file tree tmux \
        build-essential pkg-config \
        python3 python3-pip python3-venv pipx \
        iptables ipset iproute2 dnsutils \
        bubblewrap socat \
        gosu uidmap fuse-overlayfs slirp4netns dbus-user-session \
        locales tzdata

# --------------------------------------------------------------------------------------------------
# Third-party repositories
#
# Every key is pinned to a fingerprint verified against the vendor's published value. A repository
# added with an unverified key is a supply-chain hole in an image whose whole job is to run an agent
# with elevated autonomy. Agent images that add their own repository do the same (see
# agents/claude/Dockerfile), and tests/image.bats asserts that every added source has a signed-by.
# --------------------------------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    install -d -m 0755 /etc/apt/keyrings; \
    arch="$(dpkg --print-architecture)"; \
    \
    fetch_key() { \
        url="$1"; dest="$2"; expected="$3"; \
        curl -fsSL "${url}" -o "${dest}"; \
        actual="$(gpg --show-keys --with-colons "${dest}" | awk -F: '/^fpr:/{print $10; exit}')"; \
        if [ "${actual}" != "${expected}" ]; then \
            echo "key fingerprint mismatch for ${url}: got ${actual}, want ${expected}" >&2; \
            exit 1; \
        fi; \
    }; \
    \
    fetch_key https://download.docker.com/linux/ubuntu/gpg \
        /etc/apt/keyrings/docker.asc 9DC858229FC7DD38854AE2D88D81803C0EBFCD88; \
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${DOCKER_SUITE} stable" \
        > /etc/apt/sources.list.d/docker.list; \
    \
    fetch_key https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        /etc/apt/keyrings/nodesource.asc 6F71F525282841EEDAF851B42F59B5F99B1BE0B4; \
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/nodesource.asc] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list; \
    \
    fetch_key https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        /etc/apt/keyrings/githubcli.gpg 2C6106201985B60E6C7AC87323F3D4EA75716059; \
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/githubcli.list; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras \
        nodejs gh

# --------------------------------------------------------------------------------------------------
# The container user
#
# Named `agent` rather than after any one tool: seven images share this layer. Several of these CLIs
# refuse their bypass flag when they run as root, so non-root is a functional requirement, not a
# preference.
#
# Ubuntu 24.04 ships a stock `ubuntu` account on uid 1000, which has to go first — 1000 is the uid
# that matches an ordinary host user, and matching it is what keeps the workspace's file ownership
# sane without any remapping at startup.
# --------------------------------------------------------------------------------------------------
RUN set -eux; \
    userdel -r ubuntu 2>/dev/null || true; \
    groupadd -g 1000 agent; \
    useradd -m -u 1000 -g 1000 -s /bin/bash agent; \
    groupadd -f docker; \
    usermod -aG docker agent; \
    printf 'agent:100000:65536\n' > /etc/subuid; \
    printf 'agent:100000:65536\n' > /etc/subgid; \
    install -d -m 0755 /etc/docker-code /opt/docker-code/defaults; \
    install -d -o agent -g agent -m 0755 /home/agent /home/agent/.local/share/docker

COPY image/entrypoint.sh image/user-init.sh image/launch.sh \
     image/init-firewall.sh image/local-models.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/user-init.sh \
               /usr/local/bin/launch.sh /usr/local/bin/init-firewall.sh \
               /usr/local/bin/local-models.sh

# No per-tool config-dir variable is needed here, unlike the single-tool original: /home/agent as a
# whole is the persistent bind mount, so every path a tool invents under it persists by default —
# ~/.codex, ~/.gemini, ~/.config/opencode, ~/.local/share/opencode, whatever the eighth tool picks.
ENV HOME=/home/agent \
    XDG_RUNTIME_DIR=/run/user/1000 \
    DOCKER_HOST=unix:///run/user/1000/docker.sock \
    PATH=/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    npm_config_update_notifier=false \
    npm_config_fund=false \
    DISABLE_AUTOUPDATER=1

# A broken base should fail here, in the build, not in front of a user. These run per target
# architecture, so an arm64 image that cannot execute its own binaries never gets pushed.
RUN set -eux; \
    docker --version; \
    dockerd --version; \
    node --version; \
    npm --version; \
    rg --version >/dev/null; \
    git --version; \
    socat -V >/dev/null; \
    gosu agent true; \
    test -x /usr/bin/dockerd-rootless.sh

WORKDIR /home/agent
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# ==================================================================================================
# test
#
# Deliberately built from ubuntu rather than from `base`: the suite checks shell scripts, so it needs
# nothing from the runtime image, and pinning it to $BUILDPLATFORM means it runs once, natively,
# instead of once per target architecture under QEMU.
# ==================================================================================================
FROM --platform=$BUILDPLATFORM ubuntu:${UBUNTU_TAG} AS test

ENV DEBIAN_FRONTEND=noninteractive
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends bats shellcheck jq

WORKDIR /src
COPY tests/ tests/
COPY image/ image/
COPY bin/ bin/
COPY lib/ lib/
COPY agents/ agents/
COPY scripts/ scripts/
COPY ai/ ai/
COPY docs/ docs/
COPY base/Dockerfile base/Dockerfile
COPY Jenkinsfile install.sh README.md AGENTS.md CLAUDE.md GEMINI.md QWEN.md ./

# The report is written whether or not the suite passes, and the exit code is kept beside it. That
# split is what lets `--target test-results` publish a red report while `verified` below stops the
# build — a failing test should be visible in CI, not just absent.
RUN mkdir -p /out && \
    bats --formatter junit --recursive tests/ > /out/tests.junit.xml; \
    echo $? > /out/exitcode; \
    tail -n 5 /out/tests.junit.xml

# ==================================================================================================
# test-results — the only thing scripts/test.sh extracts
# ==================================================================================================
FROM scratch AS test-results
COPY --from=test /out/ /

# ==================================================================================================
# verified
# ==================================================================================================
FROM test AS verified
RUN set -eux; \
    if [ "$(cat /out/exitcode)" != "0" ]; then \
        echo "test suite failed; refusing to build the image" >&2; \
        exit 1; \
    fi; \
    touch /verified.stamp

# ==================================================================================================
# final — base, gated on the test suite
#
# Agent images inherit this stamp by building FROM the published base, so one red test blocks all
# seven rather than only the one whose Dockerfile happened to be rebuilt.
# ==================================================================================================
FROM base AS final
COPY --from=verified /verified.stamp /usr/share/docker-code/verified.stamp
