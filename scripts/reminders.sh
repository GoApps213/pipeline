#!/usr/bin/env bash
# For tickets waiting on an answer: one reminder after REMIND_DAYS, and parked as
# failed after PARK_DAYS. Ages count from when the agent asked, so a reminder
# doesn't reset the clock. Run daily by .github/workflows/housekeeping.yml.
# Env: GH_TOKEN, GITHUB_REPOSITORY; optional REMIND_DAYS (2), PARK_DAYS (7).
set -euo pipefail
REPO="$GITHUB_REPOSITORY"
REMIND_DAYS=${REMIND_DAYS:-2}; PARK_DAYS=${PARK_DAYS:-7}
MARK='<!-- ai-reminder -->'
HERE=$(cd "$(dirname "$0")" && pwd)

gh issue list -R "$REPO" --label ai:needs-input --state open --json number --jq '.[].number' \
| while read -r n; do
    comments=$(gh api "repos/$REPO/issues/$n/comments" --paginate \
      --jq '.[] | {body, created_at}' | jq -s .)

    # When the agent last asked, from the status comment's data
    asked=$(jq -r '.[] | select(.body | startswith("<!-- ai-status -->")) | .body' <<<"$comments" \
      | sed -n 's/^<!-- data: \(.*\) -->$/\1/p' | head -1 \
      | jq -r '[.events[] | select(.state == "needs-input")] | last | .at // ""')
    if [ -z "$asked" ]; then echo "#$n: no question time recorded; skipping"; continue; fi

    age=$(jq -n --arg t "$asked" '((now - ($t | fromdateiso8601)) / 86400) | floor')
    reminded=$(jq -r --arg m "$MARK" --arg t "$asked" \
      '[.[] | select((.body | startswith($m)) and .created_at > $t)] | length' <<<"$comments")

    if [ "$age" -ge "$PARK_DAYS" ]; then
      "$HERE/status.sh" "$n" failed "No answer after $PARK_DAYS days"
    elif [ "$age" -ge "$REMIND_DAYS" ] && [ "$reminded" -eq 0 ]; then
      gh issue comment "$n" -R "$REPO" \
        --body "$MARK
Reminder: the agent is waiting for your answer on this request." >/dev/null
      echo "#$n: reminded (waiting $age days)"
    else
      echo "#$n: waiting $age days; nothing to do"
    fi
  done
