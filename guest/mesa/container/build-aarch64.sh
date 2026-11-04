#!/bin/bash
# Runs in AARCH64_IMAGE (holo-deckard base-devel = Steam Frame userspace, arm64).
# Mounts: /src (mesa source, ro), /patches (ro), /scripts (ro), /out (guest tree), /work (test bins, logs).
set -euo pipefail
source /scripts/common.sh

# Build deps from the image's own pacman.conf (public, token-free pipeline/174308 + hotfix repo).
# Only packages the image lacks are installed: `pacman -S --needed` would also upgrade listed
# packages that are out of date in the repo, and the libraries Mesa links against must stay
# identical to the image (= the Frame userspace), whenever the build runs.
deps=(meson ninja python-mako python-yaml python-packaging
      libdrm wayland wayland-protocols libx11 libxcb libxshmfence libxrandr libxext libxfixes libxxf86vm
      libglvnd xcb-proto xorgproto vulkan-headers systemd-libs zstd expat zlib)
linked=(glibc gcc-libs libdrm wayland libxcb libxshmfence libxext libxfixes libxxf86vm libglvnd systemd-libs zstd expat zlib)
before=$(pacman -Q)
mapfile -t missing < <(pacman -T "${deps[@]}" || true)
if ((${#missing[@]})); then
    echo "installing missing build deps: ${missing[*]}"
    pacman -Sy --noconfirm --needed "${missing[@]}"
fi
changed=$(comm -23 <(sort <<<"$before") <(pacman -Q | sort))
if [[ -n $changed ]]; then
    for pkg in "${linked[@]}"; do
        if grep -q "^$pkg " <<<"$changed"; then
            echo "error: installing build deps changed image libraries Mesa links against:" >&2
            printf '%s\n' "$changed" >&2
            exit 1
        fi
    done
    echo "warning: installing build deps changed these image packages (not linked into Mesa):" >&2
    printf '%s\n' "$changed" >&2
fi

build_venus /tmp/build-aarch64 lib /tmp/dest-aarch64

install -D -m 0755 /tmp/dest-aarch64/usr/lib/libvulkan_virtio.so /out/usr/lib/libvulkan_virtio.so
install -D -m 0644 /tmp/dest-aarch64/usr/share/vulkan/icd.d/virtio_icd.aarch64.json \
    /out/usr/share/vulkan/icd.d/virtio_icd.aarch64.json

# GL: patched zink over the image's own (stock deckard-mesa) GL files of the same names
build_gl /tmp/build-gl-aarch64 lib /tmp/dest-gl-aarch64
install_gl /tmp/dest-gl-aarch64 lib /out

mkdir -p /work/bin
gcc -O2 -Wall -o /work/bin/vkprobe-aarch64 /scripts/vkprobe.c -ldl
pacman -Q glibc gcc-libs libdrm wayland libxcb libxshmfence libxext libxfixes libxxf86vm libglvnd \
    systemd-libs zstd expat zlib meson python-mako vulkan-headers > /work/packages-aarch64.txt
gcc --version | head -1 > /work/toolchain-aarch64.txt
