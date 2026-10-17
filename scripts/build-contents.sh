#!/usr/bin/env bash
# Works out what a release build contains: everything merged since the last
# successful Release run. One build can therefore cover several merges.
# Prints the ticket numbers closed by those merges, space-separated, and writes
# TICKETS and WHAT_TO_TEST (the text shown in TestFlight) to $GITHUB_ENV.
# Env: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SHA, GITHUB_ENV. Needs full git history.
# Optional env: LAST_BUILD_SHA overrides the lookup of the last successful build.
set -euo pipefail
REPO="$GITHUB_REPOSITORY"; HEAD_SHA="$GITHUB_SHA"

LAST=${LAST_BUILD_SHA:-$(gh run list -R "$REPO" --workflow Release --status success --limit 1 \
  --json headSha --jq '.[0].headSha // ""')}

if [ "$LAST" = "$HEAD_SHA" ]; then
  COMMITS=""                                   # a rebuild of what is already out
elif [ -n "$LAST" ] && git merge-base --is-ancestor "$LAST" "$HEAD_SHA" 2>/dev/null; then
  COMMITS=$(git rev-list --reverse "$LAST..$HEAD_SHA")
else
  COMMITS="$HEAD_SHA"                          # first build, or history was rewritten
fi

TICKETS=""
for c in $COMMITS; do
  n=$(gh api "repos/$REPO/commits/$c/pulls" --jq '.[0].body // ""' \
        | grep -oE 'Closes #[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  case " $TICKETS " in *" $n "*) ;; *) [ -n "$n" ] && TICKETS="$TICKETS $n" ;; esac
done
TICKETS=${TICKETS# }

count=$(wc -w <<<"$COMMITS" | tr -d ' ')
if [ "$count" -eq 0 ]; then
  NOTES="Rebuild; no changes since the last build."
elif [ "$count" -eq 1 ]; then
  NOTES=$(git log -1 --format=%B "$COMMITS")   # the PR title and the agent's summary
else
  NOTES=$(for c in $COMMITS; do git log -1 --format='- %s' "$c"; done)
fi

echo "Commits in this build: $count; tickets: ${TICKETS:-none}" >&2
# The notes come from commit messages, which include the agent's summary. A random
# delimiter keeps a line in them from ending the value and setting other variables.
DELIM="NOTES_$(uuidgen)"
{
  echo "TICKETS=$TICKETS"
  echo "WHAT_TO_TEST<<$DELIM"
  echo "$NOTES"
  echo "$DELIM"
} >> "$GITHUB_ENV"
echo "$TICKETS"
