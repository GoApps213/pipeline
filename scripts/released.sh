#!/usr/bin/env bash
# Marks released any ticket still "building" whose merge is in a build already on
# TestFlight. A build normally releases the tickets build-contents.sh finds, but one
# superseded by a newer push can leave its tickets behind; this catches them.
# Usage: released.sh [<build sha>]
#   With a sha: the build at that commit just succeeded (the release job passes its own,
#   with BUILD_NUMBER set). Without: the last successful Release run's commit, skipped
#   while a release is queued or running, since that run will release its own tickets.
# Env: GH_TOKEN, GITHUB_REPOSITORY; optional BUILD_NUMBER.
set -euo pipefail
REPO="$GITHUB_REPOSITORY"
HERE=$(cd "$(dirname "$0")" && pwd)
BUILD_SHA=${1:-}

if [ -z "$BUILD_SHA" ]; then
  pending=$(gh run list -R "$REPO" --workflow Release --limit 20 --json status \
    --jq '[.[] | select(.status != "completed")] | length')
  if [ "$pending" -gt 0 ]; then echo "A release is under way; leaving it to mark its tickets."; exit 0; fi
  BUILD_SHA=$(gh run list -R "$REPO" --workflow Release --status success --limit 1 \
    --json headSha --jq '.[0].headSha // ""')
  [ -n "$BUILD_SHA" ] || { echo "No successful release yet."; exit 0; }
fi
echo "Last build: $BUILD_SHA"

if [ -n "${BUILD_NUMBER:-}" ]; then MSG="On TestFlight (build $BUILD_NUMBER)"
else MSG="On TestFlight; included in a later build"; fi

gh issue list -R "$REPO" --label ai:building --state all --limit 100 --json number --jq '.[].number' \
| while read -r n; do
    merge=$(gh pr list -R "$REPO" --state merged --head "ai/issue-$n" --limit 1 \
      --json mergeCommit --jq '.[0].mergeCommit.oid // ""')
    if [ -z "$merge" ]; then echo "#$n: no merged pull request found; skipping"; continue; fi
    # "ahead" or "identical": the build's commit has the merge in its history
    case $(gh api "repos/$REPO/compare/$merge...$BUILD_SHA" --jq .status 2>/dev/null || true) in
      ahead|identical) "$HERE/status.sh" "$n" released "$MSG" ;;
      *) echo "#$n: merge $merge is not in that build yet" ;;
    esac
  done
