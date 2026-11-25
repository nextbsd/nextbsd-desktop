#!/usr/bin/env bash
# =============================================================================
# sources-state.sh: print what a desktop build would be made from right now
# =============================================================================
#
# One line per input: each sources.lock repository with the commit at the tip
# of its ref, then the published `continuous` assets the build downloads (the
# GNUstep SDK, which also fixes the @sdk libs-back, and nextbsd-xlibre) with
# their upload times. The workflow publishes this as SOURCES next to the
# tarballs; the scheduled run compares it with the published one and builds
# only when something moved, so a merge to any component repo rebuilds the
# desktop without that repo dispatching anything.
#
# Environment: GH_TOKEN.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"

grep -v '^#' sources.lock | while read -r name url ref; do
    [ -n "$name" ] || continue
    [ "$ref" = "@sdk" ] && continue
    commit=$(git ls-remote "$url" "refs/heads/$ref" | awk '{ print $1 }')
    [ -n "$commit" ] || { echo "FAIL: $name: no branch $ref at $url" >&2; exit 1; }
    printf '%s\t%s\t%s\n' "$name" "$ref" "$commit"
done

for repo in nextbsd/nextbsd-gnustep nextbsd/nextbsd-xlibre; do
    gh release view continuous --repo "$repo" --json assets \
        -q ".assets[] | select(.name | endswith(\".tar.gz\")) | \"$repo\t\" + .name + \"\t\" + .updatedAt"
done
