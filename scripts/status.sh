#!/usr/bin/env bash
# The only thing that changes a ticket's state: swaps the ai:* label and appends a
# line to the status comment, keeping a JSON copy hidden in the comment for the app.
# Usage: status.sh <issue> <state> <message>
# States: queued running needs-input in-review building released failed cancelled
# Optional env: SESSION_ID, PR_URL, BUILD_NUMBER are saved into the status data.
#               USAGE_FILE: token counts from the adapter, one JSON object per line. They
#               are added to the ticket's running total and to the step that was under
#               way (the last event before this one), and the file is emptied.
set -euo pipefail
N=$1; STATE=$2; MSG=$3
REPO="$GITHUB_REPOSITORY"
MARKER='<!-- ai-status -->'
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 1. Swap the state label
gh api "repos/$REPO/issues/$N" \
  --jq ".labels[].name | select(startswith(\"ai:\") and . != \"ai:$STATE\") | @uri" \
  | while read -r old; do
      gh api -X DELETE "repos/$REPO/issues/$N/labels/$old" >/dev/null
    done
gh api "repos/$REPO/issues/$N/labels" -f "labels[]=ai:$STATE" >/dev/null

# 2. Find the status comment and its data, if it exists
ID=$(gh api "repos/$REPO/issues/$N/comments" --paginate \
  --jq ".[] | select(.body | startswith(\"$MARKER\")) | .id" | head -1)
DATA='{"state":"","events":[],"session_id":"","pr":"","build":""}'
if [ -n "$ID" ]; then
  DATA=$(gh api "repos/$REPO/issues/comments/$ID" --jq .body \
    | sed -n 's/^<!-- data: \(.*\) -->$/\1/p')
fi

# 3. Add up the agent sessions since the last update. The file is in a folder the
#    agent can write to, so anything that isn't a number counts as zero.
USAGE='{}'
if [ -s "${USAGE_FILE:-}" ]; then
  USAGE=$(jq -sc 'def total(f): map(f | numbers) | add // 0;
    {input: total(.input), output: total(.output), cache_read: total(.cache_read),
     cache_write: total(.cache_write), cost: total(.cost), sessions: length}' "$USAGE_FILE" 2>/dev/null) \
    || USAGE='{}'
  : > "$USAGE_FILE"
fi

# 4. Update the data and render the comment
DATA=$(jq -c --arg s "$STATE" --arg m "$MSG" --arg t "$NOW" --argjson u "$USAGE" \
  --arg sid "${SESSION_ID:-}" --arg pr "${PR_URL:-}" --arg b "${BUILD_NUMBER:-}" '
  def plus_usage: reduce ($u | to_entries[]) as $e (. // {}; .[$e.key] = ((.[$e.key] // 0) + $e.value))
                  | .cost |= (. * 10000 | round / 10000);
  .state = $s
  # The sessions ran during the step the last event started, so they are counted on it
  | if ($u | length) > 0 and (.events | length) > 0 then .events[-1].usage |= plus_usage else . end
  | .events += [{state: $s, message: $m, at: $t}]
  | if ($u | length) > 0 then
      .usage |= plus_usage
      | if (.events | length) == 1 then .events[0].usage |= plus_usage else . end
    else . end
  | if $sid != "" then .session_id = $sid else . end
  | if $pr  != "" then .pr = $pr else . end
  | if $b   != "" then .build = $b else . end' <<<"$DATA")

BODY="$MARKER
**Pipeline status:** \`$STATE\`

$(jq -r '.events[] | "- \(.at) · \(.state) · \(.message)"' <<<"$DATA")
<!-- data: $DATA -->"

if [ -z "$ID" ]; then
  gh api "repos/$REPO/issues/$N/comments" -f body="$BODY" >/dev/null
else
  gh api -X PATCH "repos/$REPO/issues/comments/$ID" -f body="$BODY" >/dev/null
fi
echo "Ticket #$N: $STATE ($MSG)"
