#!/bin/sh
# Runs inside steamac-kernel-builder (native arm64). Invoked by build.sh.
# Mounts: /steamac = guest/kernel (ro), /cache = kernel tarball dir (ro),
#         /out = work/out (rw), /build = docker volume (case-sensitive work area).
set -eu
: "${KVER:?}" "${JOBS:?}"

src=/build/linux-$KVER
obj=/build/obj-$KVER
tarball=/cache/linux-$KVER.tar.xz
# Reproducible version string: fixed build number and date (the object dir lives in a
# persistent volume, so .version would otherwise count up on every relink).
epoch=${SOURCE_DATE_EPOCH:-1767225600}   # 2026-01-01, as the initramfs and layer
build_date=$(LC_ALL=C date -u -d "@$epoch")
make_args="-C $src O=$obj ARCH=arm64 KBUILD_BUILD_USER=steamac KBUILD_BUILD_HOST=steamac KBUILD_BUILD_VERSION=1"
export KBUILD_BUILD_TIMESTAMP="$build_date"

# Source tree: (re)extract + patch whenever the tarball or a patch changes.
stamp=$(cat "$tarball" /steamac/patches/*.patch | sha256sum | cut -d' ' -f1)
if [ "$(cat "$src/.steamac-stamp" 2>/dev/null || true)" != "$stamp" ]; then
	echo ">> extracting $tarball"
	rm -rf "$src" "$obj"
	tar -C /build -xf "$tarball"
	for p in /steamac/patches/*.patch; do
		echo ">> applying $(basename "$p")"
		patch -d "$src" -p1 -F0 --no-backup-if-mismatch < "$p"
	done
	echo "$stamp" > "$src/.steamac-stamp"
fi
mkdir -p "$obj"

# Config: libkrunfw base + Frame userspace options + steamac requirements.
echo ">> configuring"
cp /steamac/config/00-base-libkrunfw-aarch64.config "$obj/.config"
"$src/scripts/kconfig/merge_config.sh" -m -O "$obj" "$obj/.config" \
	/steamac/config/10-frame-userspace.config /steamac/config/20-steamac.config \
	> "$obj/merge_config.log"
make $make_args olddefconfig > /dev/null
# Everything built in: promote modules until Kconfig settles.
i=0
while grep -qE '^CONFIG_[A-Za-z0-9_]+=m$' "$obj/.config" && [ $i -lt 10 ]; do
	sed -i -E 's/^(CONFIG_[A-Za-z0-9_]+)=m$/\1=y/' "$obj/.config"
	make $make_args olddefconfig > /dev/null
	i=$((i + 1))
done
sh /steamac/check-config.sh "$obj/.config" /steamac/config/20-steamac.config > "$obj/check-config.log" || {
	cat "$obj/check-config.log"
	exit 1
}
tail -n1 "$obj/check-config.log"

echo ">> building Image with -j$JOBS"
make $make_args -j"$JOBS" Image
# temp + rename: a VM booting meanwhile reads either the old or the new Image, never half.
cp "$obj/arch/arm64/boot/Image" /out/Image.tmp
mv -f /out/Image.tmp /out/Image
cp "$obj/.config" /out/kernel.config
cp "$obj/check-config.log" /out/kernel-check-config.log
echo ">> $(cat "$obj/include/config/kernel.release")"
