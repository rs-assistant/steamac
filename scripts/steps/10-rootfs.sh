#!/bin/bash
# Step 10 (runs inside the builder container): fetch the official signed RAUC
# bundle, verify it, and rebuild the 10 GiB btrfs rootfs.img from Valve's
# casync chunk store, exactly like steamos-atomupd/RAUC would write it into a
# slot. Result is cached in /work/cache/rootfs/<buildid>/ and re-verified.
#
# Verification chain:
#   1. bundle sha256 == STEAMOS_BUNDLE_SHA256 (pin)
#   2. CMS signature (trailing DER blob, size = last 8 bytes big-endian) verifies
#      against the Valve RAUC CA "CN=steamdeck-images, O=Valve Corp"
#      (scripts/keys/steamdeck-images.pem, byte-identical to the rootfs keyring
#      /etc/rauc/trusted_keys/ba942c60.0; SHA-256 fingerprint pinned in
#      config.env). The bundle is signed by the leaf "CN=frame-images" issued by
#      that CA, i.e. exactly the chain RAUC itself checks on the device.
#   3. manifest.raucm (inside the signed squashfs) says compatible=steamos-aarch64
#      and its [image.rootfs] sha256/size equal our pins.
#   4. the reconstructed rootfs.img sha256 == manifest sha256.
set -euo pipefail
. /src/scripts/config.env

CACHE=/work/cache/rootfs/${STEAMOS_BUILDID}
mkdir -p "$CACHE"
cd "$CACHE"

log() { echo "[rootfs] $*" >&2; }

bundle=$(basename "$STEAMOS_BUNDLE_PATH")
if [[ ! -f $bundle ]] || ! echo "$STEAMOS_BUNDLE_SHA256  $bundle" | sha256sum -c --status -; then
    log "downloading $STEAMOS_IMAGES_URL/$STEAMOS_BUNDLE_PATH"
    curl -fL --retry 5 -o "$bundle.part" "$STEAMOS_IMAGES_URL/$STEAMOS_BUNDLE_PATH"
    mv "$bundle.part" "$bundle"
fi
echo "$STEAMOS_BUNDLE_SHA256  $bundle" | sha256sum -c -

# --- split payload / signature and verify the CMS signature
size=$(stat -c %s "$bundle")
sig_size=$(tail -c 8 "$bundle" | od -An -t u8 --endian=big | tr -d ' ')
head -c $((size - sig_size - 8)) "$bundle" > bundle.sqfs
tail -c $((sig_size + 8)) "$bundle" | head -c "$sig_size" > bundle.sig
ca=/src/scripts/keys/steamdeck-images.pem
fp=$(openssl x509 -in "$ca" -noout -fingerprint -sha256 | cut -d= -f2)
if [[ $fp != "$STEAMOS_CA_FP_SHA256" ]]; then
    log "CA fingerprint $fp does not match pinned $STEAMOS_CA_FP_SHA256"; exit 1
fi
openssl pkcs7 -inform DER -in bundle.sig -print_certs -noout
openssl cms -verify -binary -inform DER -in bundle.sig -content bundle.sqfs \
    -CAfile "$ca" -purpose any -out /dev/null

rm -rf bundle
unsquashfs -q -d bundle bundle.sqfs
grep -qx 'compatible=steamos-aarch64' bundle/manifest.raucm
m_sha=$(sed -n '/^\[image.rootfs\]/,/^\[/s/^sha256=//p' bundle/manifest.raucm)
m_size=$(sed -n '/^\[image.rootfs\]/,/^\[/s/^size=//p' bundle/manifest.raucm)
[[ $m_sha == "$STEAMOS_ROOTFS_SHA256" ]] || { log "manifest sha256 $m_sha != pin"; exit 1; }
[[ $m_size == "$STEAMOS_ROOTFS_SIZE" ]] || { log "manifest size $m_size != pin"; exit 1; }
cp bundle/rootfs.img.caibx rootfs.img.caibx
cp bundle/UUID rootfs.uuid
log "manifest OK: sha256=$m_sha size=$m_size uuid=$(cat rootfs.uuid)"

# --- reconstruct rootfs.img (skip if a cached copy still has the pinned sha256)
# The marker only says a previous run verified it; work/cache is writable from the host, so the
# bytes are hashed again before they are trusted (40-disk mounts and runs tools from them).
if [[ -f rootfs.img.verified ]] && [[ $(cat rootfs.img.verified) == "$STEAMOS_ROOTFS_SHA256" ]] \
   && [[ $(stat -c %s rootfs.img 2>/dev/null || echo 0) == "$STEAMOS_ROOTFS_SIZE" ]] \
   && log "re-hashing cached rootfs.img" \
   && echo "$STEAMOS_ROOTFS_SHA256  rootfs.img" | sha256sum -c --status -; then
    log "cached rootfs.img verified (sha256 matches the pin)"
else
    rm -f rootfs.img.verified
    log "desync extract from $STEAMOS_IMAGES_URL/$STEAMOS_CHUNKS_STORE_PATH (10 GiB, takes a while)"
    # The per-build store is tried first (as the SM8650 port does), then the
    # shared vr store that atomupd uses (chunks_store_path in stable.json).
    desync extract -n 16 --error-retry 10 \
        -s "$STEAMOS_IMAGES_URL/${STEAMOS_BUNDLE_PATH%.raucb}.castr/" \
        -s "$STEAMOS_IMAGES_URL/$STEAMOS_CHUNKS_STORE_PATH/" \
        rootfs.img.caibx rootfs.img
    echo "$STEAMOS_ROOTFS_SHA256  rootfs.img" | sha256sum -c -
    echo "$STEAMOS_ROOTFS_SHA256" > rootfs.img.verified
fi
rm -f bundle.sqfs
log "rootfs ready: $CACHE/rootfs.img"
