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
# - The user's Go configuration does not reach the build: GOENV=off ignores `go env -w`
#   settings, and every variable that changes code generation is set or cleared here. The
#   binary's recorded build settings must be exactly EXPECTED_BUILD.
# - Caches live in work/build/go (module cache, toolchain); nothing outside the repo's work/.
#
# Idempotent: skips the build only if the stamp (<dest>.source) names this module, sum, toolchain
# and script, and <dest> still has the sha256 recorded there; otherwise rebuilds.
set -euo pipefail

GO_TOOLCHAIN=go1.25.14
# `go version -m` build lines of a correct build (-ldflags is not recorded with -trimpath).
EXPECTED_BUILD='-buildmode=exe
-compiler=gc
-trimpath=true
CGO_ENABLED=0
GOARCH=arm64
GOOS=darwin
GOARM64=v8.0'

[[ $# == 6 || $# == 7 ]] \
    || { echo "usage: $0 <name> <module> <package> <version> <h1-sum> <dest> [<license dest>]" >&2; exit 64; }
name=$1 module=$2 package=$3 version=$4 sum=$5 dest=$6 license=${7:-}

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
GOCACHE_ROOT="$ROOT/work/build/go"
stamp_file="$dest.source"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
die() { echo "$name: $*" >&2; exit 1; }

# Everything the stamp binds except the output hash: a change to any of it forces a rebuild.
stamp_key="source $module@$version $sum $GO_TOOLCHAIN darwin/arm64 script=$(sha256 "$0")"

if [[ -x "$dest" && ( -z $license || -f $license ) && -f "$stamp_file" ]]; then
    recorded=$(cat "$stamp_file")
    if [[ "$recorded" == "$stamp_key sha256="* && "${recorded##* sha256=}" == "$(sha256 "$dest")" ]]; then
        echo "$name $version already at $dest (built from source, sha256 verified)"
        exit 0
    fi
    echo "$name: $dest does not match its stamp, rebuilding"
fi

command -v go >/dev/null || die "go not found (brew install go)"

# Ignore the user's Go configuration; pin everything that affects fetching or code generation.
unset GOROOT GODEBUG GOAUTH GOAMD64 GOARM GO386 GOMIPS GOMIPS64 GOPPC64 GORISCV64 GOWASM
export GOENV=off GO111MODULE=on GOEXPERIMENT= GOFIPS140=off GOARM64=v8.0
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

goversion=$(go env GOVERSION) || die "cannot run the Go toolchain $GO_TOOLCHAIN"
[[ $goversion == "$GO_TOOLCHAIN" ]] || die "Go toolchain is $goversion, want $GO_TOOLCHAIN"

# Module source: the go command verifies it against sum.golang.org; check the pinned sum too.
# On failure `go mod download -json` reports the error in its JSON output, not on stderr.
if ! info=$(go mod download -json "$module@$version"); then
    echo "$name: go mod download $module@$version failed:" >&2
    printf '%s\n' "$info" >&2
    exit 1
fi
field() { printf '%s' "$info" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d.get("Error") or d[sys.argv[1]])' "$1"; }
got=$(field Sum)
[[ "$got" == "$sum" ]] || die "module $module@$version sum mismatch: got $got want $sum"

mkdir -p "$(dirname "$dest")"
tmp="$dest.build.$$"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"
GOBIN="$tmp" go install -trimpath -ldflags='-s -w' "$package@$version"
bin="$tmp/$(basename "$package")"
[[ -x "$bin" ]] || die "go install produced no $bin"

# The binary must describe exactly this build (plain string tests: no grep in a pipeline,
# which could fail on SIGPIPE under pipefail).
buildinfo=$(go version -m "$bin")
nl=$'\n' tab=$'\t'
first=${buildinfo%%"$nl"*}
[[ $first == *": $GO_TOOLCHAIN" ]] || die "binary was not built by $GO_TOOLCHAIN ($first)"
[[ "$nl$buildinfo$nl" == *"$nl${tab}mod${tab}$module${tab}$version${tab}$sum$nl"* ]] \
    || die "binary build info does not name $module $version $sum"
build=
while IFS= read -r line; do
    [[ $line == "${tab}build${tab}"* ]] && build+="${line#"${tab}build${tab}"}$nl"
done <<<"$buildinfo"
[[ "$build" == "$EXPECTED_BUILD$nl" ]] \
    || die "unexpected build settings:$nl$build(want:$nl$EXPECTED_BUILD)"

if [[ -n $license ]]; then
    src=$(field Dir)
    [[ -f "$src/LICENSE" ]] || die "no LICENSE in $src"
    mkdir -p "$(dirname "$license")"
    cp -f "$src/LICENSE" "$license"
    chmod 644 "$license"
fi
mv -f "$bin" "$dest"
echo "$stamp_key sha256=$(sha256 "$dest")" > "$stamp_file"
echo "$name $version -> $dest (built from source with $GO_TOOLCHAIN)"
