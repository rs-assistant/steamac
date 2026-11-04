#!/usr/bin/env bash
# Build a pinned Go command from source for the app (darwin/arm64), instead of downloading a
# prebuilt release binary. Used by fetch-gvproxy.sh and fetch-desync.sh.
#
#   build-go-tool.sh <name> <module> <package> <version> <module h1: sum> <dest> [<license dest>]
#
# <license dest>: copy the module's top-level LICENSE (of exactly the source that was built) there.
#
# - The Go toolchain is pinned (GO_TOOLCHAIN). The installed `go` (Homebrew, >= 1.21) downloads it
#   through the Go module proxy; the go command checks it against the checksum database
#   (sum.golang.org).
# - The module source is fetched at <version> through the module proxy, checked against the
#   checksum database by the go command, and additionally against the pinned <module h1: sum>
#   here, so a changed upstream tag or proxy answer is refused even if GOSUMDB is turned off.
# - Built with `go install <package>@<version>`: the module's own go.mod/go.sum select every
#   dependency, and the binary carries its build info (`go version -m`, used by licenses.sh).
#   CGO is off (pure Go, system frameworks only), paths are trimmed, symbols stripped (-s -w,
#   as in the upstream release builds).
# - Caches live in work/build/go (module cache, toolchain); nothing outside the repo's work/.
#
# Idempotent: rebuilds only if <dest>, <license dest> or the stamp (<dest>.source) is missing or the
# stamp differs.
set -euo pipefail

GO_TOOLCHAIN=go1.25.14

[[ $# == 6 || $# == 7 ]] \
    || { echo "usage: $0 <name> <module> <package> <version> <h1-sum> <dest> [<license dest>]" >&2; exit 64; }
name=$1 module=$2 package=$3 version=$4 sum=$5 dest=$6 license=${7:-}

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
GOCACHE_ROOT="$ROOT/work/build/go"
stamp_file="$dest.source"
stamp="source $module@$version $sum $GO_TOOLCHAIN darwin/arm64"

if [[ -x "$dest" && ( -z $license || -f $license ) && "$(cat "$stamp_file" 2>/dev/null)" == "$stamp" ]]; then
    echo "$name $version already at $dest (built from source)"
    exit 0
fi

command -v go >/dev/null || { echo "$name: go not found (brew install go)" >&2; exit 1; }

export GOTOOLCHAIN=$GO_TOOLCHAIN
export GOPATH="$GOCACHE_ROOT/gopath"
export GOMODCACHE="$GOCACHE_ROOT/modcache"
export GOCACHE="$GOCACHE_ROOT/buildcache"
export GOFLAGS=-modcacherw
export GOWORK=off
export GOPROXY=https://proxy.golang.org
export GOSUMDB=sum.golang.org
export GONOSUMDB= GOPRIVATE= GONOPROXY= GOINSECURE=
export CGO_ENABLED=0 GOOS=darwin GOARCH=arm64

[[ $(go env GOVERSION) == "$GO_TOOLCHAIN" ]] \
    || { echo "$name: Go toolchain is $(go env GOVERSION), want $GO_TOOLCHAIN" >&2; exit 1; }

# Module source: the go command verifies it against sum.golang.org; check the pinned sum too.
info=$(go mod download -json "$module@$version")
field() { printf '%s' "$info" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d.get("Error") or d[sys.argv[1]])' "$1"; }
got=$(field Sum)
if [[ "$got" != "$sum" ]]; then
    echo "$name: module $module@$version sum mismatch: got $got want $sum" >&2
    exit 1
fi

mkdir -p "$(dirname "$dest")"
tmp="$dest.build.$$"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"
GOBIN="$tmp" go install -trimpath -ldflags='-s -w' "$package@$version"
bin="$tmp/$(basename "$package")"
[[ -x "$bin" ]] || { echo "$name: go install produced no $bin" >&2; exit 1; }

# The binary must describe exactly this build.
buildinfo=$(go version -m "$bin")
head -1 <<<"$buildinfo" | grep -q ": $GO_TOOLCHAIN\$" \
    || { echo "$name: binary was not built by $GO_TOOLCHAIN" >&2; exit 1; }
tab=$'\t'
printf '%s\n' "$buildinfo" | grep -qFx "${tab}mod${tab}$module${tab}$version${tab}$sum" \
    || { echo "$name: binary build info does not name $module $version $sum" >&2; exit 1; }
printf '%s\n' "$buildinfo" | grep -qFx "${tab}build${tab}CGO_ENABLED=0" \
    || { echo "$name: binary was not built with CGO_ENABLED=0" >&2; exit 1; }

if [[ -n $license ]]; then
    src=$(field Dir)
    [[ -f "$src/LICENSE" ]] || { echo "$name: no LICENSE in $src" >&2; exit 1; }
    mkdir -p "$(dirname "$license")"
    cp -f "$src/LICENSE" "$license"
    chmod 644 "$license"
fi
mv -f "$bin" "$dest"
echo "$stamp" > "$stamp_file"
echo "$name $version -> $dest (built from source with $GO_TOOLCHAIN)"
