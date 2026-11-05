#!/bin/sh
# Runs in TOOLS_IMAGE with the source volume at /src. Leaves an exact checkout of
# $MESA_COMMIT at /src/mesa plus the venus-protocol subproject Mesa's wrap requires
# (pre-fetched so the builds can run with --wrap-mode=nodownload on a read-only tree).
# Re-uses an existing checkout when it is already at the pinned commits.
set -eu
: "${MESA_URL:?}" "${MESA_COMMIT:?}" "${VENUS_PROTOCOL_URL:?}" "${VENUS_PROTOCOL_COMMIT:?}"
apk add --no-cache -q git ca-certificates >/dev/null

# fetch_commit <dir> <url> <commit>
fetch_commit() {
    rm -rf "$1"
    git init -q "$1"
    git -C "$1" remote add origin "$2"
    n=0
    until git -C "$1" fetch -q --depth 1 origin "$3"; do
        n=$((n + 1)); [ "$n" -ge 5 ] && { echo "fetch of $2 $3 failed" >&2; exit 1; }
        sleep 5
    done
    git -C "$1" -c advice.detachedHead=false checkout -q FETCH_HEAD
    test "$(git -C "$1" rev-parse HEAD)" = "$3"
}

# at_commit <dir> <commit>
at_commit() {
    [ -d "$1/.git" ] && [ "$(git -C "$1" rev-parse HEAD 2>/dev/null)" = "$2" ] \
        && [ -z "$(git -C "$1" status --porcelain --untracked-files=no)" ]
}

if at_commit /src/mesa "$MESA_COMMIT"; then
    # The volume persists between builds: drop untracked and ignored files a previous run
    # left (no receipt covers them), keeping only the venus-protocol checkout handled below.
    vp_name=$(sed -n 's/^directory *= *//p' /src/mesa/subprojects/venus-protocol.wrap)
    git -C /src/mesa clean -ffdxq -e "/subprojects/$vp_name/"
    echo "mesa source already at $MESA_COMMIT (cleaned)"
else
    fetch_commit /src/mesa "$MESA_URL" "$MESA_COMMIT"
    echo "mesa: $(git -C /src/mesa log -1 --format='%H %s')"
fi

# The wrap names the directory and tag; we pin the tag's commit.
wrap=/src/mesa/subprojects/venus-protocol.wrap
vp_dir=/src/mesa/subprojects/$(sed -n 's/^directory *= *//p' "$wrap")
vp_rev=$(sed -n 's/^revision *= *//p' "$wrap")
if at_commit "$vp_dir" "$VENUS_PROTOCOL_COMMIT"; then
    git -C "$vp_dir" clean -ffdxq
    echo "venus-protocol already at $VENUS_PROTOCOL_COMMIT (cleaned)"
else
    fetch_commit "$vp_dir" "$VENUS_PROTOCOL_URL" "$VENUS_PROTOCOL_COMMIT"
    echo "venus-protocol ($vp_rev): $(git -C "$vp_dir" log -1 --format='%H %s')"
fi
