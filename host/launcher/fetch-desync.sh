#!/usr/bin/env bash
# Build the pinned desync (folbricht/desync, BSD-3-Clause; pure Go, system frameworks only) from
# source into work/out/host/bin/desync, its licence into work/out/host/share/desync/LICENSE
# (build-go-tool.sh: pinned Go toolchain, module source checked against the Go checksum database
# and the pinned h1: sum below). No prebuilt release binary is used. The launcher runs it to
# rebuild the SteamOS rootfs from Valve's casync chunk store (Docker-free disk creation);
# bundle.sh ships both in the .app.
# Idempotent: rebuilds only if missing or the pinned version, sum or toolchain changed.
set -euo pipefail

VERSION=v1.1.4
MODULE=github.com/folbricht/desync
MODULE_SUM=h1:HKg5fG5LHLgEulhKGskwCezW+H42MIYSWNKtgYtbYBI=   # go.sum hash of $MODULE@$VERSION

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
DEST="${DESYNC_DEST:-$ROOT/work/out/host/bin/desync}"
LICENSE="$ROOT/work/out/host/share/desync/LICENSE"

"$HERE/build-go-tool.sh" desync "$MODULE" "$MODULE/cmd/desync" "$VERSION" "$MODULE_SUM" "$DEST" "$LICENSE"
"$DEST" --version | grep -q "$VERSION" || { echo "desync --version is not $VERSION" >&2; exit 1; }
