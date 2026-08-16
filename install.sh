#!/usr/bin/env bash
# Installs docker-code and one wrapper per agent.
#
#   curl -fsSL https://raw.githubusercontent.com/ruepp-jenkins/docker-code/master/install.sh | bash
#   ./install.sh --local                 from a checkout you already have
#   ./install.sh --uninstall
#
# What it does, and nothing else:
#   - copies the tree (bin, lib, agents, image) into ~/.local/share/docker-code
#   - links ~/.local/bin/docker-code and ~/.local/bin/<agent>-docker at it
#
# What it deliberately never does: use sudo, write to a shell startup file, define an alias, or touch
# anything under ~/docker-code. Your state and your shell configuration are yours.
set -euo pipefail

REPO="${DOCKER_CODE_REPO:-ruepp-jenkins/docker-code}"
REF="${DOCKER_CODE_REF:-master}"

# ~/.local/bin is on PATH by default on most distributions and needs no privileges. /usr/local/bin is
# only used when there is no home to install into at all.
if [ -n "${HOME:-}" ]; then
    INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/bin}"
    PREFIX="${DOCKER_CODE_PREFIX:-${HOME}/.local/share/docker-code}"
else
    INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
    PREFIX="${DOCKER_CODE_PREFIX:-/usr/local/share/docker-code}"
fi

SELF="$0"
case "${SELF}" in
    bash|sh|-bash|/dev/fd/*)
        SELF="curl -fsSL https://raw.githubusercontent.com/${REPO}/${REF}/install.sh | bash -s --"
        ;;
esac

MODE=install
SOURCE=""

usage() {
    cat <<EOF
Usage: ${SELF} [options]

  --local [DIR]   install from a checkout (default: the directory this script is in)
  --dir DIR       where to link the commands   (default: ${INSTALL_DIR})
  --prefix DIR    where to copy the tree       (default: ${PREFIX})
  --ref REF       branch or tag to download    (default: ${REF})
  --uninstall     remove everything this installed
  -h, --help      this text

Environment: INSTALL_DIR, DOCKER_CODE_PREFIX, DOCKER_CODE_REF, DOCKER_CODE_REPO
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --local)
            MODE=local
            case "${2:-}" in
                ""|-*) ;;
                *) SOURCE="$2"; shift ;;
            esac
            ;;
        --dir) INSTALL_DIR="${2:?--dir needs a directory}"; shift ;;
        --prefix) PREFIX="${2:?--prefix needs a directory}"; shift ;;
        --ref) REF="${2:?--ref needs a branch or tag}"; shift ;;
        --uninstall) MODE=uninstall ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install.sh: unknown option '$1'" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

die() { echo "install.sh: ERROR: $*" >&2; exit 1; }

# The names to link are read from the tree being installed, not from a list in here. That is what
# makes an eighth agent appear after `git pull` without an installer change.
wrapper_names() {
    local root="$1" file wrapper aliases a
    for file in "${root}"/agents/*/agent.env; do
        [ -f "${file}" ] || continue
        wrapper="$(sed -n 's/^AGENT_WRAPPER=//p' "${file}" | head -n 1 | tr -d '"'"'")"
        aliases="$(sed -n 's/^AGENT_ALIASES=//p' "${file}" | head -n 1 | tr -d '"'"'")"
        [ -n "${wrapper}" ] || die "${file} has no AGENT_WRAPPER"
        printf '%s\n' "${wrapper}"
        # shellcheck disable=SC2086  # a space-separated list is the documented format
        for a in ${aliases}; do printf '%s\n' "${a}"; done
    done
}

# ---------------------------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------------------------
if [ "${MODE}" = "uninstall" ]; then
    removed=0

    if [ -d "${PREFIX}" ]; then
        while IFS= read -r name; do
            link="${INSTALL_DIR}/${name}"
            if [ -L "${link}" ] || [ -f "${link}" ]; then
                rm -f "${link}"
                echo "removed ${link}"
                removed=$((removed + 1))
            fi
        done <<EOF
$(wrapper_names "${PREFIX}"; echo docker-code)
EOF
        rm -rf "${PREFIX}"
        echo "removed ${PREFIX}"
        removed=$((removed + 1))
    fi

    if [ "${removed}" = "0" ]; then
        echo "nothing to remove (looked in ${INSTALL_DIR} and ${PREFIX})"
    fi

    echo
    echo "Your state in ~/docker-code was left alone — logins, sessions and local models are still"
    echo "there. Remove it yourself if you meant to: rm -rf ~/docker-code"
    exit 0
fi

# ---------------------------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------------------------
STAGE=""
cleanup() { [ -z "${STAGE}" ] || rm -rf "${STAGE}"; }
trap cleanup EXIT

if [ "${MODE}" = "local" ]; then
    if [ -z "${SOURCE}" ]; then
        case "$0" in
            bash|sh|-bash|/dev/fd/*) die "--local needs a directory when piped into a shell" ;;
            *) SOURCE="$(cd "$(dirname "$0")" && pwd)" ;;
        esac
    fi
    [ -d "${SOURCE}" ] || die "no such directory: ${SOURCE}"
else
    command -v curl >/dev/null || die "curl is required to download"
    command -v tar >/dev/null || die "tar is required to unpack"

    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/docker-code.XXXXXX")"
    url="https://codeload.github.com/${REPO}/tar.gz/${REF}"

    echo "downloading ${REPO}@${REF}"
    curl -fsSL "${url}" | tar -xzf - -C "${STAGE}" ||
        die "could not download ${url}"

    SOURCE="$(find "${STAGE}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [ -n "${SOURCE}" ] || die "the downloaded archive was empty"
fi

# Validate before installing anything. A truncated download or the wrong repository should fail here,
# not leave a half-working command on PATH.
[ -f "${SOURCE}/bin/docker-code" ] || die "${SOURCE} does not look like a docker-code checkout (no bin/docker-code)"
[ -f "${SOURCE}/lib/agents.sh" ] || die "${SOURCE} is missing lib/agents.sh"
head -n 1 "${SOURCE}/bin/docker-code" | grep -q '^#!' || die "bin/docker-code is not a script"
grep -q 'DOCKER_CODE_HOME' "${SOURCE}/bin/docker-code" || die "bin/docker-code is not the file we expect"
[ -n "$(wrapper_names "${SOURCE}")" ] || die "${SOURCE}/agents holds no agent definitions"

# ---------------------------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------------------------
mkdir -p "${INSTALL_DIR}" || die "cannot create ${INSTALL_DIR}"
mkdir -p "$(dirname "${PREFIX}")" || die "cannot create $(dirname "${PREFIX}")"

# Replaced wholesale rather than merged: a stale agent.env from a previous version would otherwise
# keep registering a wrapper the current version no longer has.
rm -rf "${PREFIX}"
mkdir -p "${PREFIX}"

for dir in bin lib agents image base scripts; do
    [ -d "${SOURCE}/${dir}" ] || continue
    cp -R "${SOURCE}/${dir}" "${PREFIX}/"
done

# The installer travels with the installation, so `docker-code self-update` has something to run
# without going back to the network first — and so a --local install can be refreshed from its
# checkout while offline.
cp "${SOURCE}/install.sh" "${PREFIX}/install.sh"
chmod 0755 "${PREFIX}/install.sh"
for doc in README.md AGENTS.md; do
    if [ -f "${SOURCE}/${doc}" ]; then
        cp "${SOURCE}/${doc}" "${PREFIX}/"
    fi
done
if [ -d "${SOURCE}/docs" ]; then
    mkdir -p "${PREFIX}/docs"
    cp -R "${SOURCE}/docs/." "${PREFIX}/docs/"
fi
if [ -d "${SOURCE}/ai" ]; then
    mkdir -p "${PREFIX}/ai"
    cp -R "${SOURCE}/ai/." "${PREFIX}/ai/"
fi

chmod 0755 "${PREFIX}/bin/docker-code"
chmod 0755 "${PREFIX}"/image/*.sh 2>/dev/null || true
chmod 0755 "${PREFIX}"/scripts/*.sh 2>/dev/null || true

# Where this installation came from, so it can be refreshed the same way it was made. Without this,
# `self-update` would have to guess — and would silently pull from GitHub over an installation
# somebody made from a checkout they are working in.
{
    echo "# written by install.sh; read by 'docker-code self-update'"
    if [ "${MODE}" = "local" ]; then
        echo "mode=local"
        echo "source=${SOURCE}"
    else
        echo "mode=remote"
        echo "repo=${REPO}"
        echo "ref=${REF}"
    fi
    echo "install_dir=${INSTALL_DIR}"
    echo "prefix=${PREFIX}"
} >"${PREFIX}/.install-source"

# The wrappers in the checkout are symlinks to bin/docker-code; the installed ones point at the
# installed copy, so the commands keep working if the checkout moves or goes away.
linked=0
while IFS= read -r name; do
    [ -n "${name}" ] || continue
    ln -sfn "${PREFIX}/bin/docker-code" "${INSTALL_DIR}/${name}"
    linked=$((linked + 1))
done <<EOF
$(wrapper_names "${SOURCE}"; echo docker-code)
EOF

echo
echo "installed ${PREFIX}"
echo "linked    ${linked} commands into ${INSTALL_DIR}"
echo

"${INSTALL_DIR}/docker-code" list 2>/dev/null || true

# The example names a real wrapper, read from the tree that was just installed rather than written
# out here — so it stays right when the set of agents changes.
example="$(wrapper_names "${SOURCE}" | head -n 1)"

echo
case ":${PATH}:" in
    *":${INSTALL_DIR}:"*)
        echo "Next: build the images once, then start an agent from a project directory."
        echo "    docker-code build"
        echo "    cd ~/my-project && ${example}"
        ;;
    *)
        rc="${HOME}/.bashrc"
        case "${SHELL:-}" in
            */zsh) rc="${HOME}/.zshrc" ;;
        esac
        echo "${INSTALL_DIR} is not on your PATH. Add it:"
        echo "    echo 'export PATH=\"${INSTALL_DIR}:\$PATH\"' >> ${rc}"
        echo "then open a new shell and run: docker-code build"
        ;;
esac
