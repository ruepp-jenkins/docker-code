#!/usr/bin/env bats
# Invariants of the Dockerfiles that no runtime test would catch.
#
# These are cheap and static, and each one stands for a failure that would otherwise only show up in
# a user's container: an unsigned apt repository, a tool installed into the directory the bind mount
# replaces, a base image whose user does not match what the entrypoint expects.

load helper

BASE_DOCKERFILE="${BATS_TEST_DIRNAME}/../base/Dockerfile"

@test "every apt repository the base adds is signed by a pinned key" {
    # A repository added with an unverified key is a supply-chain hole in an image whose whole job is
    # to run an agent with elevated autonomy.
    sources="$(grep -c 'sources.list.d/' "${BASE_DOCKERFILE}")"
    signed="$(grep -c 'signed-by=/etc/apt/keyrings/' "${BASE_DOCKERFILE}")"
    [ "${sources}" -eq "${signed}" ]

    # And every key is compared against a fingerprint, not merely downloaded.
    keys="$(grep -c 'fetch_key ' "${BASE_DOCKERFILE}")"
    [ "${keys}" -gt 0 ]
    fingerprints="$(grep -Eco '[0-9A-F]{40}' "${BASE_DOCKERFILE}")"
    [ "${fingerprints}" -ge "${keys}" ]
}

@test "an agent that adds its own apt repository pins its key too" {
    for id in $(all_agent_ids); do
        file="${REPO_ROOT}/agents/${id}/Dockerfile"
        grep -q 'sources.list.d/' "${file}" || continue
        grep -q 'signed-by=/etc/apt/keyrings/' "${file}" || {
            echo "agents/${id}/Dockerfile adds an unsigned apt repository"; return 1
        }
        grep -Eq 'fingerprint mismatch' "${file}" || {
            echo "agents/${id}/Dockerfile does not verify the key fingerprint"; return 1
        }
    done
}

@test "the container user is agent on uid 1000" {
    # 1000 is the uid an ordinary host user has, and matching it is what keeps the workspace's file
    # ownership sane without any remapping at startup. The stock ubuntu account has to go first.
    grep -q 'userdel -r ubuntu' "${BASE_DOCKERFILE}"
    grep -q 'useradd -m -u 1000 -g 1000 -s /bin/bash agent' "${BASE_DOCKERFILE}"
}

@test "the base image ships the whole entrypoint chain" {
    for script in entrypoint.sh user-init.sh launch.sh init-firewall.sh local-models.sh; do
        grep -q "image/${script}" "${BASE_DOCKERFILE}" || {
            echo "base/Dockerfile does not install ${script}"; return 1
        }
        [ -f "${REPO_ROOT}/image/${script}" ] || {
            echo "image/${script} does not exist"; return 1
        }
    done
    grep -q 'ENTRYPOINT \["/usr/local/bin/entrypoint.sh"\]' "${BASE_DOCKERFILE}"
}

@test "the base image ships the command the /remote skill runs" {
    grep -q 'COPY image/compose.sh /usr/local/bin/docker-code-compose' "${BASE_DOCKERFILE}"
    grep -q 'chmod 0755 .*/usr/local/bin/docker-code-compose' <(tr -d '\\\n' <"${BASE_DOCKERFILE}")
}

@test "the base ships socat, which the local-model bridge needs" {
    grep -q 'socat' "${BASE_DOCKERFILE}"
    grep -q 'socat' "${REPO_ROOT}/image/local-models.sh"
}

@test "node is at least 22, which two of the tools require" {
    major="$(sed -n 's/^ARG NODE_MAJOR=//p' "${BASE_DOCKERFILE}" | head -n 1)"
    [ -n "${major}" ]
    [ "${major}" -ge 22 ]
}

@test "the base smoke-tests itself per architecture" {
    # These run per target architecture, so an arm64 image that cannot execute its own binaries never
    # gets pushed.
    grep -q 'dockerd --version' "${BASE_DOCKERFILE}"
    grep -q 'node --version' "${BASE_DOCKERFILE}"
    grep -q 'gosu agent true' "${BASE_DOCKERFILE}"
}

@test "the test gate is wired: verified refuses an image when the suite failed" {
    grep -q 'FROM scratch AS test-results' "${BASE_DOCKERFILE}"
    grep -q 'FROM test AS verified' "${BASE_DOCKERFILE}"
    grep -q 'refusing to build the image' "${BASE_DOCKERFILE}"
    grep -q 'COPY --from=verified /verified.stamp' "${BASE_DOCKERFILE}"
}

# Every repository path the suite reads: the literal part of each reference below REPO_ROOT or
# below the test directory's parent, cut at the first variable so that a computed name drops out.
suite_repo_paths() {
    grep -rhoE '\$\{(REPO_ROOT|BATS_TEST_DIRNAME)\}"?/[^"'"'"'`) ;,]*' \
        "${REPO_ROOT}"/tests/*.bats "${REPO_ROOT}"/tests/helper.bash |
        sed -e 's|^\${REPO_ROOT}"\?/||' \
            -e 's|^\${BATS_TEST_DIRNAME}"\?/\.\.||' \
            -e 's|^/||' \
            -e 's|\$.*||' |
        grep -v '^$' | sort -u
}

@test "the test stage copies everything the suite reads" {
    # The container the suite runs in holds nothing but these COPY lines, so a test that reads a file
    # nobody copied passes in a checkout and fails only in CI. Deriving the list from the tests
    # themselves is what catches the next file added at the repository root: LICENSE was the last
    # one, and it broke the build rather than the checkout it was committed from.
    copies="$(sed -n '/^FROM .* AS test$/,/^FROM .* AS test-results$/p' "${BASE_DOCKERFILE}" |
        sed -n 's/^COPY //p')"
    [ -n "${copies}" ]

    # The suite reads its own directory through $BATS_TEST_DIRNAME, which names no path to check.
    copied="tests/"
    for src in ${copies}; do
        case "${src}" in
            --*|./) continue ;;
        esac
        copied="${copied} ${src}"
    done

    while IFS= read -r path; do
        found=""
        for src in ${copied}; do
            case "${path}" in
                "${src}"|"${src%/}"|"${src%/}"/*) found=1; break ;;
            esac
        done
        [ -n "${found}" ] || {
            echo "the suite reads ${path}, which base/Dockerfile's test stage does not copy"
            return 1
        }
    done <<EOF
$(suite_repo_paths)
EOF
}

@test "an agent's smoke test does not leave root-owned files on the mount point" {
    # The image's HOME is the bind-mount point. A root-owned file created there during the build is
    # exactly what breaks the first real container start.
    for id in $(all_agent_ids); do
        file="${REPO_ROOT}/agents/${id}/Dockerfile"
        grep -q 'env HOME=/root' "${file}" || {
            echo "agents/${id}/Dockerfile smoke-tests without overriding HOME"; return 1
        }
        grep -q 'rm -rf /root/' "${file}" || {
            echo "agents/${id}/Dockerfile does not clean up after its smoke test"; return 1
        }
    done
}

@test "no agent installs its tool into the persistent home" {
    # Anything under /home/agent is replaced by the bind mount on the first real start, so a tool
    # installed there simply disappears. Cursor's installer defaults to exactly that, which is why it
    # is given a HOME of its own.
    for id in $(all_agent_ids); do
        file="${REPO_ROOT}/agents/${id}/Dockerfile"
        grep -q '/home/agent' "${file}" && {
            echo "agents/${id}/Dockerfile writes into /home/agent, which the bind mount replaces"
            return 1
        }
    done
    grep -q 'HOME=/opt/cursor' "${REPO_ROOT}/agents/cursor/Dockerfile"
}

@test "the ubuntu tag is the only external base image, so one trigger covers it" {
    from_lines="$(grep -h '^FROM ' "${BASE_DOCKERFILE}" | grep -v '\${BASE_IMAGE}')"
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        case "${line}" in
            *ubuntu:*|*'AS '*scratch*|'FROM scratch'*|*' AS '*) ;;
            *) echo "unexpected external base image: ${line}"; return 1 ;;
        esac
    done <<EOF
${from_lines}
EOF
}

@test "the agent joins the GPU's device groups before root is dropped" {
    # The nodes keep the host's gid, which the image's /etc/group does not know; gosu only carries
    # memberships it finds there. Root's own group is never one of them.
    entry="${REPO_ROOT}/image/entrypoint.sh"
    grant_line="$(grep -n '^grant_gpu_groups$' "${entry}" | cut -d: -f1)"
    drop_line="$(grep -n '^exec gosu' "${entry}" | cut -d: -f1)"
    [ -n "${grant_line}" ] && [ -n "${drop_line}" ]
    [ "${grant_line}" -lt "${drop_line}" ]
    sed -n '/^grant_gpu_groups()/,/^}/p' "${entry}" | grep -q '" 0 65534 '
}

@test "a device group the image does not know does not end the entrypoint" {
    # getent exits 2 for an unknown gid, and under pipefail that used to end the entrypoint before
    # the groupadd that handles exactly this case: the container died with exit 2 and no output.
    entry="${REPO_ROOT}/image/entrypoint.sh"
    lookup="$(sed -n '/^grant_gpu_groups()/,/^}/p' "${entry}" | grep -F 'group="$(getent group')"
    [ -n "${lookup}" ]
    run bash -c "set -euo pipefail; gid=64999; ${lookup}; echo reached"
    [ "${status}" -eq 0 ]
    [ "${output}" = "reached" ]
}

# A fake /sys and /dev for image/gpu.sh: render_node <name> <vram bytes or ""> <boot_vga or "">
render_node() {
    touch "${GPU_DEV_ROOT}/dri/$1"
    mkdir -p "${GPU_SYS_ROOT}/class/drm/$1/device"
    [ -z "$2" ] || echo "$2" >"${GPU_SYS_ROOT}/class/drm/$1/device/mem_info_vram_total"
    [ -z "$3" ] || echo "$3" >"${GPU_SYS_ROOT}/class/drm/$1/device/boot_vga"
}

gpu_sh() {
    export GPU_SYS_ROOT="${BATS_TEST_TMPDIR}/sys" GPU_DEV_ROOT="${BATS_TEST_TMPDIR}/dev"
    mkdir -p "${GPU_SYS_ROOT}" "${GPU_DEV_ROOT}/dri"
    # shellcheck source=../image/gpu.sh
    . "${REPO_ROOT}/image/gpu.sh"
}

@test "a nested container gets the card with the most VRAM, not the iGPU Mesa would open first" {
    # Measured: with every render node, Chromium in a Playwright container rendered on a Ryzen iGPU
    # next to an idle RX 9070 XT; with the card's node alone, on the card.
    gpu_sh
    render_node renderD128 2147483648 0
    render_node renderD129 17095983104 1
    [ "$(gpu_preferred_render_node)" = "renderD129" ]
    [ "$(gpu_nested_args amd)" = "--device /dev/kfd --device /dev/dri/renderD129" ]
}

@test "without VRAM figures the booted card wins, then the first" {
    gpu_sh
    render_node renderD128 "" 0
    render_node renderD129 "" 1
    [ "$(gpu_preferred_render_node)" = "renderD129" ]

    rm -f "${GPU_SYS_ROOT}/class/drm/renderD129/device/boot_vga"
    [ "$(gpu_preferred_render_node)" = "renderD128" ]
}

@test "nested GPU arguments per vendor, with the device groups for a --user container" {
    gpu_sh
    render_node renderD128 "" ""
    [ "$(gpu_nested_args dri 987 983)" = "--device /dev/dri/renderD128 --group-add 987 --group-add 983" ]
    [ "$(gpu_nested_args nvidia)" = "--gpus all --env NVIDIA_DRIVER_CAPABILITIES=all" ]
    [ -z "$(gpu_nested_args "")" ]

    rm -f "${GPU_DEV_ROOT}/dri/renderD128"
    [ "$(gpu_nested_args dri)" = "--device /dev/dri" ]
}

@test "the image can hand an NVIDIA GPU on to the containers it starts" {
    grep -q 'nvidia-container-toolkit' "${BASE_DOCKERFILE}"
    grep -q 'nvidia.github.io/libnvidia-container/gpgkey' "${BASE_DOCKERFILE}"
    grep -q 'COPY image/gpu.sh /usr/local/bin/docker-code-gpu.sh' "${BASE_DOCKERFILE}"
    grep -q 'nvidia-ctk cdi generate' "${REPO_ROOT}/image/entrypoint.sh"
    grep -q -- '--default-shm-size' "${REPO_ROOT}/image/entrypoint.sh"
    grep -q -- '--default-shm-size' "${REPO_ROOT}/image/user-init.sh"
}

@test "every agent's instructions explain the GPU in nested containers" {
    for file in $(grep -rl 'You are running inside a docker-code container' "${REPO_ROOT}/agents"); do
        grep -q 'DOCKER_CODE_GPU_ARGS' "${file}" || { echo "${file} lacks the GPU section"; return 1; }
        grep -q -- '--use-angle=gl-egl' "${file}" || { echo "${file} lacks the Chromium flags"; return 1; }
    done
}
