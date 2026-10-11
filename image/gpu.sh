# shellcheck shell=bash
# What `docker run` inside the session needs to hand the GPU on — sourced by entrypoint.sh, and by
# tests/image.bats with a fake /sys and /dev.
#
# GPU_SYS_ROOT and GPU_DEV_ROOT are only ever changed by the tests.
GPU_SYS_ROOT="${GPU_SYS_ROOT:-/sys}"
GPU_DEV_ROOT="${GPU_DEV_ROOT:-/dev}"

# gpu_preferred_render_node — the render node a nested container should get, by name (renderD128).
#
# A host with an integrated and a discrete GPU has two render nodes, and Mesa opens the first it
# enumerates: on a Ryzen desktop with a Radeon card that is the iGPU, and a browser game in a
# Playwright container renders on 2 GB of shared memory next to a 16 GB card doing nothing. So the
# node with the most VRAM wins — amdgpu reports it per device; a device that reports none (Intel)
# counts as zero — then the one the firmware booted on, then the first.
gpu_preferred_render_node() {
    local node name vram boot best="" best_vram=-1 best_boot=0
    for node in "${GPU_DEV_ROOT}"/dri/renderD*; do
        [ -e "${node}" ] || continue
        name="${node##*/}"
        vram="$(cat "${GPU_SYS_ROOT}/class/drm/${name}/device/mem_info_vram_total" 2>/dev/null || echo 0)"
        boot="$(cat "${GPU_SYS_ROOT}/class/drm/${name}/device/boot_vga" 2>/dev/null || echo 0)"
        case "${vram}" in ""|*[!0-9]*) vram=0 ;; esac
        if [ "${vram}" -gt "${best_vram}" ] ||
            { [ "${vram}" -eq "${best_vram}" ] && [ "${boot}" = "1" ] && [ "${best_boot}" != "1" ]; }; then
            best="${name}" best_vram="${vram}" best_boot="${boot}"
        fi
    done
    [ -n "${best}" ] && printf '%s\n' "${best}"
}

# gpu_nested_args <kind> [gid...] — the docker run arguments, on one line.
#
# NVIDIA by request, through the toolkit in this image; capabilities `all`, because the default
# leaves out graphics and a browser then falls back to software without saying so. AMD and Intel by
# device node: one render node rather than /dev/dri, for the reason above, and every render node
# when there is no telling them apart. The gids are the groups that own the nodes, for a container
# started with --user.
gpu_nested_args() {
    local kind="$1" args="" node gid
    shift
    case "${kind}" in
        nvidia)
            args="--gpus all --env NVIDIA_DRIVER_CAPABILITIES=all"
            ;;
        amd|dri)
            [ "${kind}" != "amd" ] || args="--device /dev/kfd"
            node="$(gpu_preferred_render_node || true)"
            if [ -n "${node}" ]; then
                args="${args:+${args} }--device /dev/dri/${node}"
            else
                args="${args:+${args} }--device /dev/dri"
            fi
            ;;
        *)
            return 0
            ;;
    esac
    for gid in "$@"; do
        args="${args} --group-add ${gid}"
    done
    printf '%s\n' "${args}"
}
