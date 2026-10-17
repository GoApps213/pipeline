#!/usr/bin/env bash
# AI review of the ticket's pull request, by a fresh agent session that only reads.
# Usage: review.sh <issue>
# Exit 0 = clean, skipped, or the review could not be produced; exit 2 = blocking findings.
# A review that was produced but could not be posted is printed to the log, and its
# findings count all the same.
# Env: GH_TOKEN, GITHUB_REPOSITORY, PROMPT_DIR;
#      optional SMALL_CHANGE_LINES (20), AGENT_ADAPTER (claude-code),
#      REVIEW_MODEL (default: same model as the author; must be one the same adapter takes).
set -euo pipefail
N=$1; RUN=.agent/run
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/retry.sh"
PR="ai/issue-$N"
SMALL_CHANGE_LINES=${SMALL_CHANGE_LINES:-20}
SKIP_FILES_RE='(\.xcassets/|\.xcstrings$|\.strings$)'   # files that never need review

# Small-change rule: the ticket asked to skip, only skip-list files, or few lines
LINES=$(git diff --numstat origin/main...HEAD | awk '{s += $1 + $2} END {print s + 0}')
REVIEWABLE=$(git diff --name-only origin/main...HEAD | grep -vE "$SKIP_FILES_RE" || true)
REASON=""
if jq -e '.labels[].name | select(. == "ai-skip-review")' "$RUN/issue.json" >/dev/null; then
  REASON="the request asked to skip it"
elif [ -z "$REVIEWABLE" ]; then
  REASON="only assets or strings changed"
elif [ "$LINES" -lt "$SMALL_CHANGE_LINES" ]; then
  REASON="small change ($LINES lines)"
fi
if [ -n "$REASON" ]; then
  retry gh pr comment "$PR" --body "AI review skipped: $REASON." >/dev/null
  echo "AI review skipped: $REASON."
  exit 0
fi

"$HERE/status.sh" "$N" running "AI review"
rm -f "$RUN/review.md" "$RUN/review.json"
# A new session with no tokens, so the reviewer has no memory of writing the change
env -u GH_TOKEN -u GITHUB_TOKEN -u ATTACHMENTS_TOKEN -u RESUME_SESSION \
  AGENT_MODEL="${REVIEW_MODEL:-${AGENT_MODEL:-}}" "$HERE/adapters/${AGENT_ADAPTER:-claude-code}.sh" review "$RUN"

# The reviewer never changes code: put back anything it touched
git checkout -q -- . && git clean -fdq

if [ ! -s "$RUN/review.md" ]; then
  retry gh pr comment "$PR" --body "AI review did not produce a result; this pull request has not been reviewed." >/dev/null
  echo "AI review did not produce a result."
  exit 0
fi

{ echo "**AI review**"; echo; cat "$RUN/review.md"; } > "$RUN/review-comment.md"
if ! retry gh pr review "$PR" --comment --body-file "$RUN/review-comment.md" >/dev/null; then
  # The run folder is cleaned before the next run, so the log is the only place left for it
  echo "AI review could not be posted to the pull request. The review:"
  cat "$RUN/review.md"
  retry gh pr comment "$PR" --body "AI review ran, but GitHub did not accept the review when it was posted. It is in the log of the pipeline run." >/dev/null || true
fi
if jq -e '.blocking == true' "$RUN/review.json" >/dev/null 2>&1; then
  echo "AI review: blocking findings."
  exit 2
fi
echo "AI review: no blocking findings."
