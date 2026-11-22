#!/usr/bin/env bash
# =============================================================================
# fetch-sdk.sh: download and unpack nextbsd-gnustep's GNUstep SDK
# =============================================================================
#
# Takes nextbsd-gnustep-sdk-<arch>.tar.gz from nextbsd-gnustep's `continuous`
# release, or, while there is none (or SDK_RUN names a run), from the
# artifacts of its latest successful build on main (any branch if main has
# none), and unpacks it into $OUT/nextbsd-gnustep-sdk-<arch>. Prints where it
# came from to $OUT/SDK-ORIGIN.
#
# Environment: T (amd64 | arm64), OUT (a new directory), GH_TOKEN, and
# optionally SDK_RUN (a nextbsd-gnustep workflow run id to take it from).
# =============================================================================

set -euo pipefail

: "${T:?set T to amd64 or arm64}"
: "${OUT:?set OUT to a new directory}"
: "${SDK_RUN:=}"
REPO=nextbsd/nextbsd-gnustep
NAME=nextbsd-gnustep-sdk-$T

[ ! -e "$OUT/$NAME" ] || { echo "FAIL: $OUT/$NAME already exists" >&2; exit 1; }
mkdir -p "$OUT/download"

origin=
if [ -z "$SDK_RUN" ] &&
        gh release download continuous --repo "$REPO" --pattern "$NAME.tar.gz" --dir "$OUT/download" 2>/dev/null; then
    origin="release continuous, $(gh release view continuous --repo "$REPO" --json assets \
        -q ".assets[] | select(.name == \"$NAME.tar.gz\") | .updatedAt")"
else
    run=$SDK_RUN
    for branch in main ""; do
        [ -n "$run" ] && break
        run=$(gh run list --repo "$REPO" --workflow build.yml ${branch:+--branch "$branch"} \
            --status success --limit 1 --json databaseId -q '.[0].databaseId')
    done
    [ -n "$run" ] || { echo "FAIL: no continuous release and no successful run of $REPO" >&2; exit 1; }
    gh run download "$run" --repo "$REPO" --name "$NAME" --dir "$OUT/download"
    origin="workflow run $run ($(gh run view "$run" --repo "$REPO" --json headBranch,headSha \
        -q '.headBranch + " " + .headSha'))"
fi

tar -C "$OUT" -xzf "$OUT/download/$NAME.tar.gz"
[ -f "$OUT/$NAME/env.sh" ] || { echo "FAIL: $NAME.tar.gz holds no env.sh" >&2; exit 1; }
echo "$REPO $origin" > "$OUT/SDK-ORIGIN"
cat "$OUT/SDK-ORIGIN"
