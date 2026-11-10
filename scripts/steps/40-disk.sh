#!/bin/bash
# Step 40 (builder container): work/out/steamos.img, the guest /dev/vda.
#
# GPT with Valve's partition names, order and type GUIDs (repair_device.sh /
# QDL lun0.xml of the Frame):
#   1 esp       256M  C12A7328-F81F-11D2-BA4B-00A0C93EC93B  FAT32 "esp"
#   2 efi-A      64M  EBD0A0A2-B9E5-4433-87C0-68B6B72699C7  FAT32 "efi-A"
#   3 efi-B      64M  EBD0A0A2-B9E5-4433-87C0-68B6B72699C7  FAT32 "efi-B"
#   4 rootfs-A  10G   4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709  btrfs (OTA image, byte-exact)
#   5 rootfs-B  10G   4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709  btrfs (copy, new fsid)
#   6 var-A      1G   4D21B016-B534-45C2-A9FB-5C16E091FD2D  ext4 "var-A"
#   7 var-B      1G   4D21B016-B534-45C2-A9FB-5C16E091FD2D  ext4 "var-B"
#   8 home      rest  933AC7E1-2EB4-4F13-B844-0E14E2AEF915  ext4 "home" -O casefold -T huge -m 0
# rootfs-X are exactly the OTA slot size (manifest.raucm size=10737418240), so
# RAUC/desync can write any future bundle into them.
#
# var-X = 1 GiB instead of Valve's 256 MiB: the file is sparse, so the cost on
# the host is only what is written; /var holds the /etc overlay upper, up to 5
# /etc backups (holo-sync-var), the desync seed index rootfs.caibx (~6 MB per
# 10 GiB image) and everything under /var/lib that is not offloaded to /home.
# post-install.sh re-creates the other var with mkfs.ext4 at whatever size the
# partition has, so the size is free to choose; 4x headroom avoids ENOSPC
# during an update's holo-sync-var in a VM that is used as a dev box.
#
# rootfs-B starts as a copy of rootfs-A with a new btrfs fsid (`btrfstune -f
# -u`), mirroring Valve's repair_device.sh, which images both slots and runs
# finalize for A and B. Against the update flow (see the analysis in
# guest/layer/usr/lib/rauc/post-install.sh):
#   - the first OTA install targets B (other of booted A) and rewrites it
#     completely via desync --in-place (chunks already present in B are reused),
#     post-install reformats var-B and re-syncs it from var-A, so B's initial
#     content never leaks into an updated system;
#   - until that first update B is a real, bootable fallback (BOOT_B_LEFT=3):
#     if A fails three boots in a row the initramfs boots B, as on the device;
#   - a distinct fsid is mandatory: two btrfs devices with one fsid confuse the
#     kernel's device scan (and pre-install.sh warns about equal rootfs UUIDs).
#   An empty B marked bad would only save ~4.5 GB of host disk and lose the
#     fallback, so the Valve layout is kept.
#
# esp:   SteamOS/conf/{A,B}.conf (created with the image's own
#        /usr/lib/steamos-efi/steamos-bootconf, as repair_device.sh does) and
#        steamac/bootenv (A/B state, BOOT_ORDER="A B", BOOT_x_LEFT=3).
# efi-X: SteamOS/partsets/{all,self,other,shared,A,B} in steamos-partsets
#        format ("<name> <partuuid>") for slot X's point of view.
# var-X: lib/overlays/etc/{upper,work} like the recovery var-A, plus in upper:
#        shadow (password for `steamos`), sshd enablement, a unique machine-id;
#        var-A also gets lib/steamos-atomupd/rootfs.caibx = the bundle index of
#        rootfs-A (what post-install.sh stores for a freshly installed slot).
# home:  empty, as after factory reset; steamos-create-homedir and the
#        steamos-offload bind mounts populate it on first boot.
set -euo pipefail
. /src/scripts/config.env
. /src/scripts/steps/lib.sh

OUT=/work/out/steamos.img
CACHE=/work/cache/rootfs/$STEAMOS_BUILDID
ROOTFS=$CACHE/rootfs.img

log() { echo "[disk] $*" >&2; }

if [[ -e $OUT && ${FORCE_DISK:-} != 1 ]]; then
    log "$OUT exists (it holds the VM's state once booted); keeping it. FORCE_DISK=1 rebuilds it."
    exit 0
fi
[[ $(cat "$CACHE/rootfs.img.verified" 2>/dev/null) == "$STEAMOS_ROOTFS_SHA256" ]] \
    || { log "verified rootfs missing, run the rootfs step"; exit 1; }
# The marker is a file in host-writable work/cache: hash the image itself before mounting it and
# running its steamos-bootconf as root below.
echo "$STEAMOS_ROOTFS_SHA256  $ROOTFS" | sha256sum -c --status - \
    || { log "$ROOTFS does not match the pinned sha256; rerun the rootfs step"; exit 1; }

TMP=$OUT.tmp
LOOPS=()
MNTS=()
cleanup() {
    local m l
    for ((i = ${#MNTS[@]} - 1; i >= 0; i--)); do umount "${MNTS[i]}" 2>/dev/null || :; done
    for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null || :; done
}
trap cleanup EXIT

mib=$((1024 * 1024))
# 1 MiB in front (GPT + alignment) and 1 MiB behind home: home ends on a 1 MiB
# boundary with the backup GPT after it. systemd-repart (repart.d/90-home.conf,
# grows home when the host enlarges the image) refuses to run ("Can't fit
# requested partitions") if home ends unaligned on the last usable sector.
home_mib=$((HOME_SIZE_GIB * 1024))
total_mib=$((1 + PART_SIZE_ESP + 2 * PART_SIZE_EFI + 2 * PART_SIZE_ROOT + 2 * PART_SIZE_VAR + home_mib + 1))
rm -f "$TMP"
truncate -s $((total_mib * mib)) "$TMP"

T_ESP=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
T_EFI=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
T_ROOT=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
T_VAR=4D21B016-B534-45C2-A9FB-5C16E091FD2D
T_HOME=933AC7E1-2EB4-4F13-B844-0E14E2AEF915
names=(esp efi-A efi-B rootfs-A rootfs-B var-A var-B home)
types=($T_ESP $T_EFI $T_EFI $T_ROOT $T_ROOT $T_VAR $T_VAR $T_HOME)
sizes=(+${PART_SIZE_ESP}M +${PART_SIZE_EFI}M +${PART_SIZE_EFI}M +${PART_SIZE_ROOT}M +${PART_SIZE_ROOT}M +${PART_SIZE_VAR}M +${PART_SIZE_VAR}M +${home_mib}M)
declare -A PARTUUID
args=(--clear --disk-guid=R)
for i in "${!names[@]}"; do
    n=$((i + 1))
    PARTUUID[${names[i]}]=$(cat /proc/sys/kernel/random/uuid)
    args+=(-n "$n:0:${sizes[i]}" -t "$n:${types[i]}" -c "$n:${names[i]}" -u "$n:${PARTUUID[${names[i]}]}")
done
sgdisk -a 2048 "${args[@]}" "$TMP" >/dev/null
sgdisk -v "$TMP" | grep -q 'No problems found' || { sgdisk -v "$TMP"; exit 1; }

# One loop device per partition (the container has no udev, so no loopNpM nodes).
declare -A DEV
while read -r num start end; do
    name=${names[num - 1]}
    l=$(newloop --offset $((start * 512)) --sizelimit $(((end - start + 1) * 512)) "$TMP")
    LOOPS+=("$l")
    DEV[$name]=$l
done < <(sgdisk -p "$TMP" | awk '/^ +[0-9]+ /{print $1, $2, $3}')
for n in "${names[@]}"; do [[ -n ${DEV[$n]:-} ]] || { log "no loop for $n"; exit 1; }; done

# --- filesystems
mkfs.vfat -F 32 -n esp "${DEV[esp]}" >/dev/null
mkfs.vfat -F 32 -s 1 -n efi-A "${DEV[efi-A]}" >/dev/null
mkfs.vfat -F 32 -s 1 -n efi-B "${DEV[efi-B]}" >/dev/null
log "writing rootfs-A (OTA $STEAMOS_BUILDID, sparse copy)"
dd if="$ROOTFS" of="${DEV[rootfs-A]}" bs=4M conv=sparse,fsync status=none
log "writing rootfs-B (copy + btrfstune -f -u)"
dd if="$ROOTFS" of="${DEV[rootfs-B]}" bs=4M conv=sparse,fsync status=none
btrfstune -f -u "${DEV[rootfs-B]}"
btrfs check --readonly "${DEV[rootfs-B]}" >/dev/null 2>&1 || { log "btrfs check rootfs-B failed"; btrfs check --readonly "${DEV[rootfs-B]}"; exit 1; }
mkfs.ext4 -q -F -L var-A "${DEV[var-A]}"
mkfs.ext4 -q -F -L var-B "${DEV[var-B]}"
mkfs.ext4 -q -F -L home -O casefold -T huge -m 0 "${DEV[home]}"

mnt() { mkdir -p "$2"; mount "${@:3}" "$1" "$2"; MNTS+=("$2"); }
M=$(mktemp -d)
mnt "${DEV[rootfs-A]}" "$M/root" -o ro
mnt "${DEV[esp]}" "$M/esp"
mnt "${DEV[efi-A]}" "$M/efi-A"
mnt "${DEV[efi-B]}" "$M/efi-B"
mnt "${DEV[var-A]}" "$M/var-A"
mnt "${DEV[var-B]}" "$M/var-B"

# --- efi-X: partsets, same algorithm/output as /usr/bin/steamos-partsets
# (iterate partitions in table order; ESP is "esp" by type GUID; label suffix
# -A/-B decides self/other; no suffix = shared; "all" lists full labels).
write_partsets() { # slot dir
    local self=$1 dir=$2 other name set link
    [[ $self == A ]] && other=B || other=A
    rm -rf "$dir"; mkdir -p "$dir"
    : > "$dir/all"; : > "$dir/self"; : > "$dir/other"; : > "$dir/shared"; : > "$dir/A"; : > "$dir/B"
    for name in "${names[@]}"; do
        local uuid=${PARTUUID[$name],,}
        set=${name##*-}; link=${name%-*}
        [[ $set == "$name" ]] && set=
        case $set in
            "")       echo "$link $uuid" >> "$dir/shared" ;;
            "$self")  echo "$link $uuid" >> "$dir/$set"; echo "$link $uuid" >> "$dir/self" ;;
            "$other") echo "$link $uuid" >> "$dir/$set"; echo "$link $uuid" >> "$dir/other" ;;
        esac
        echo "$name $uuid" >> "$dir/all"
    done
}
write_partsets A "$M/efi-A/SteamOS/partsets"
write_partsets B "$M/efi-B/SteamOS/partsets"

# --- esp: bootconf files via the image's own (static aarch64) tool, + A/B state
mkdir -p "$M/esp/SteamOS/conf" "$M/esp/steamac"
for s in A B; do
    "$M/root/usr/lib/steamos-efi/steamos-bootconf" create --image "$s" \
        --conf-dir "$M/esp/SteamOS/conf" --efi-dir "$M/efi-$s" --set title "$s"
done
cat > "$M/esp/steamac/bootenv" <<EOF
# steamac A/B boot state (splctl semantics); written by initramfs and /usr/bin/splctl
BOOT_ORDER=A B
BOOT_A_LEFT=3
BOOT_B_LEFT=3
EOF

# --- var-X: /etc overlay upper with the VM's login settings
hash=$(openssl passwd -6 "$STEAMOS_PASSWORD")
for s in A B; do
    v=$M/var-$s
    install -d -m 0755 "$v/lib" "$v/lib/overlays" "$v/lib/overlays/etc" \
        "$v/lib/overlays/etc/upper" "$v/lib/overlays/etc/work"
    up=$v/lib/overlays/etc/upper
    # shadow: stock file with the empty steamos password field filled in
    awk -F: -v OFS=: -v h="$hash" '$1 == "steamos" { $2 = h } { print }' "$M/root/etc/shadow" > "$up/shadow"
    chmod 0600 "$up/shadow"
    grep -q '^steamos:\$6\$' "$up/shadow" || { log "failed to set steamos password"; exit 1; }
    # sshd enabled (kept across updates by atomic-update-keep.conf: *.wants/**)
    install -d -m 0755 "$up/systemd" "$up/systemd/system" "$up/systemd/system/multi-user.target.wants"
    ln -sfn /usr/lib/systemd/system/sshd.service "$up/systemd/system/multi-user.target.wants/sshd.service"
    # The stock rootfs ships one fixed machine-id for every device; give this
    # VM its own (kept across updates: /etc/machine-id is in the keep list).
    tr -d '-' < /proc/sys/kernel/random/uuid > "$up/machine-id"
    chmod 0444 "$up/machine-id"
done
cp "$M/var-B/lib/overlays/etc/upper/machine-id" "$M/var-A/lib/overlays/etc/upper/machine-id"
install -d -m 0755 "$M/var-A/lib/steamos-atomupd"
cp "$CACHE/rootfs.img.caibx" "$M/var-A/lib/steamos-atomupd/rootfs.caibx"

sync
cleanup
trap - EXIT
mv "$TMP" "$OUT"
{
    echo "# steamac disk $(date -u +%FT%TZ) rootfs $STEAMOS_BUILDID ($STEAMOS_VERSION)"
    for n in "${names[@]}"; do echo "$n ${PARTUUID[$n]}"; done
} > /work/out/steamos.img.partuuids
log "$OUT ready (apparent $(du -h --apparent-size "$OUT" | cut -f1), allocated $(du -h "$OUT" | cut -f1))"
