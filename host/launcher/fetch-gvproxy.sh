#!/usr/bin/env bash
# Build the pinned gvproxy (containers/gvisor-tap-vsock, Apache-2.0) from source into
# work/out/host/bin/gvproxy (build-go-tool.sh: pinned Go toolchain, module source checked against
# the Go checksum database and the pinned h1: sum below). No prebuilt release binary is used.
# Idempotent: rebuilds only if missing or the pinned version, sum or toolchain changed.
set -euo pipefail

VERSION=v0.8.9
MODULE=github.com/containers/gvisor-tap-vsock
MODULE_SUM=h1:6b7pqxFcKJ0EycBt1V4zPo3FQtgLLgs50AYkbFIb9eU=   # go.sum hash of $MODULE@$VERSION

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
DEST="${GVPROXY_DEST:-$ROOT/work/out/host/bin/gvproxy}"

"$HERE/build-go-tool.sh" gvproxy "$MODULE" "$MODULE/cmd/gvproxy" "$VERSION" "$MODULE_SUM" "$DEST"
"$DEST" -version | grep -qx "gvproxy version $VERSION" \
    || { echo "gvproxy -version is not $VERSION" >&2; exit 1; }
