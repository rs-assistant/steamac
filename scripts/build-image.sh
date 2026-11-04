#!/bin/bash
# Build the guest disk artifacts for steamac (run on the macOS host).
#
#   work/out/steamos.img          raw sparse GPT disk  -> guest /dev/vda
#   work/out/initramfs.cpio.gz    boot stage (busybox + guest/initramfs/init)
#   work/out/steamac-layer.img    read-only erofs /usr layer -> guest /dev/vdb
#                                 (includes guest/progress-agent, built in Rust)
#
# All loop/mkfs/btrfs work runs in a privileged linux/arm64 OrbStack container
# built from scripts/builder/Dockerfile (pinned). Idempotent: the verified
# rootfs reconstruction is cached in work/cache/, everything else is rebuilt.
#
# Usage: scripts/build-image.sh [step...]
#   steps: builder rootfs initramfs layer disk check   (default: all, in order)
# Env:   HOME_SIZE_GIB (default 64), STEAMOS_PASSWORD (default "steamos"),
#        FORCE_DISK=1 to rebuild steamos.img even if it exists (it holds user
#        state once booted, so it is never overwritten silently),
#        ALLOW_NO_VENUS=1 to build a test layer without work/out/mesa-venus.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$REPO/work
. "$REPO/scripts/config.env"

# Receipts are taken on the host: containers do not need Git/Python installed.
artifacts() { python3 "$REPO/scripts/guest-artifacts.py" "$@"; }

steps=("$@")
[[ ${#steps[@]} -gt 0 ]] || steps=(builder rootfs initramfs layer disk check)

mkdir -p "$WORK/out" "$WORK/cache"

run_in_builder() {
    # /src: repo (read-only), /work: work dir. --privileged for loop devices.
    docker run --rm --privileged --platform linux/arm64 \
        -e HOME_SIZE_GIB -e STEAMOS_PASSWORD -e FORCE_DISK -e ALLOW_NO_VENUS -e SOURCE_DATE_EPOCH \
        -v "$REPO:/src:ro" -v "$WORK:/work" \
        "$BUILDER_IMAGE" "$@"
}

for step in "${steps[@]}"; do
    echo "=== step: $step"
    case $step in
        builder)
            docker build --platform linux/arm64 -t "$BUILDER_IMAGE" \
                --build-arg BUILDER_BASE="$BUILDER_BASE" \
                --build-arg DEBIAN_SNAPSHOT="$DEBIAN_SNAPSHOT" \
                --build-arg DESYNC_VERSION="$DESYNC_VERSION" \
                --build-arg DESYNC_SHA256="$DESYNC_SHA256" \
                "$REPO/scripts/builder"
            ;;
        rootfs)    run_in_builder /src/scripts/steps/10-rootfs.sh ;;
        initramfs)
            inputs=$(artifacts begin initramfs)
            run_in_builder /src/scripts/steps/20-initramfs.sh
            artifacts finish initramfs "$inputs"
            ;;
        layer)
            if [[ ${ALLOW_NO_VENUS:-} == 1 ]]; then
                # Test-only layers must never acquire a release receipt.
                artifacts invalidate layer
            else
                inputs=$(artifacts begin layer)
            fi
            # 30-layer.sh copies guest/layer/usr as it is on disk, but the receipt hashes only
            # files Git does not ignore: an ignored file (.DS_Store, editor backups) would ship
            # without being bound to the inputs.
            ignored=$(git -C "$REPO" ls-files -o -i --exclude-standard -- guest/layer/usr)
            if [[ -n $ignored ]]; then
                echo "layer: git-ignored files under guest/layer/usr would end up in the layer; remove them:" >&2
                printf '  %s\n' $ignored >&2
                exit 1
            fi
            # guest/progress-agent (Rust, static musl) in the pinned rust container,
            # then the erofs layer (which installs the binary).
            docker run --rm --platform linux/arm64 \
                -e SOURCE_DATE_EPOCH \
                -v "$REPO:/src:ro" -v "$WORK:/work" \
                "$RUST_IMAGE" /src/scripts/steps/25-progress-agent.sh
            run_in_builder /src/scripts/steps/30-layer.sh
            if [[ ${ALLOW_NO_VENUS:-} != 1 ]]; then
                artifacts finish layer "$inputs"
            fi
            ;;
        disk)      run_in_builder /src/scripts/steps/40-disk.sh ;;
        check)     run_in_builder /src/scripts/steps/50-check.sh ;;
        *) echo "unknown step $step" >&2; exit 2 ;;
    esac
done
