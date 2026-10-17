#!/usr/bin/env bash
# Ends a ticket that was closed as "not planned": stops its agent runs, closes its
# pull request and marks it cancelled. Run by .github/workflows/housekeeping.yml.
# Usage: cancel.sh <issue>
# Env: GH_TOKEN, GITHUB_REPOSITORY; optional WAIT_SECONDS (180).
set -euo pipefail
N=$1
export GH_REPO="$GITHUB_REPOSITORY"
BRANCH="ai/issue-$N"
WAIT_SECONDS=${WAIT_SECONDS:-180}
HERE=$(cd "$(dirname "$0")" && pwd)

# 1. The ticket's pull request, if it has one
PR=""; PR_STATE=""
if pr=$(gh pr view "$BRANCH" --json number,state --jq '[.number, .state] | @tsv' 2>/dev/null); then
  IFS=$'\t' read -r PR PR_STATE <<<"$pr"
fi

# 2. Stop the agent's runs for this ticket, waiting or under way. agent.yml names each run
#    "#<number> <title>"; a run started by a pull request comment carries the PR's number.
ids=$(gh run list --workflow agent.yml --limit 50 --json databaseId,status,displayTitle \
  | jq -r --arg n "$N" --arg pr "$PR" '.[]
      | select(.status != "completed")
      | select((.displayTitle | startswith("#\($n) "))
               or ($pr != "" and (.displayTitle | startswith("#\($pr) "))))
      | .databaseId')
for id in $ids; do
  echo "Cancelling run $id"
  gh run cancel "$id" || true   # it may have just finished
done

# 3. Wait for them to end, so a run on its way out and this script never write the
#    ticket's status at the same time
deadline=$((SECONDS + WAIT_SECONDS))
for id in $ids; do
  while [ "$(gh run view "$id" --json status --jq .status)" != completed ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "Run $id is still stopping after $WAIT_SECONDS seconds; carrying on."
      break
    fi
    sleep 5
  done
done

# 4. Close the pull request. The branch is kept.
if [ "$PR_STATE" = OPEN ]; then
  gh pr close "$PR" --comment "Closed because request #$N was cancelled." >/dev/null
fi

# 5. Last, so nothing changes the state after it
"$HERE/status.sh" "$N" cancelled "Cancelled"
