#!/usr/bin/env bash
# After a pull request is merged into main: finds the open pull requests that now conflict
# with main. An agent pull request (ai/issue-*) gets an agent run that merges main and
# resolves the conflicts; any other pull request gets a comment saying it conflicts.
# Pull requests that still merge cleanly are left alone.
# Usage: conflicts.sh <merged PR number>
# Env: GH_TOKEN, GITHUB_REPOSITORY; optional DRY_RUN=1 prints what it would do.
set -euo pipefail
MERGED=$1
export GH_REPO="$GITHUB_REPOSITORY"
. "$(dirname "$0")/retry.sh"

# Run a command, or only print it under DRY_RUN
act() {
  if [ -n "${DRY_RUN:-}" ]; then echo "Would run: $*" >&2; else retry "$@"; fi
}

# GitHub works out whether a pull request merges only when asked, so the first answer
# after a merge is often UNKNOWN.
mergeable() {
  local state
  for _ in 1 2 3 4 5 6; do
    state=$(retry gh pr view "$1" --json mergeable --jq .mergeable)
    [ "$state" != UNKNOWN ] && { echo "$state"; return; }
    sleep 10
  done
  echo UNKNOWN
}

retry gh pr list --base main --state open --limit 100 --json number,headRefName \
  --jq '.[] | [.number, .headRefName] | @tsv' |
while IFS=$'\t' read -r pr head; do
  [ "$pr" = "$MERGED" ] && continue
  state=$(mergeable "$pr")
  case "$state" in
    CONFLICTING) ;;
    UNKNOWN) echo "#$pr: GitHub has not worked out whether it merges; skipped."; continue ;;
    *) echo "#$pr: merges cleanly."; continue ;;
  esac

  case "$head" in
    ai/issue-*)
      echo "#$pr: conflicts with main; starting an agent run to resolve them."
      # Started from main, where the project's agent.yml takes the pr input. A project
      # whose agent.yml predates it refuses the dispatch; that only costs the warning.
      act gh workflow run agent.yml --ref main -f "pr=$pr" ||
        echo "::warning::Could not start an agent run for #$pr. Does .github/workflows/agent.yml have the workflow_dispatch trigger from the pipeline's template?"
      ;;
    *)
      marker="<!-- conflicts-after-$MERGED -->"
      if retry gh pr view "$pr" --json comments --jq '.comments[].body' | grep -qF "$marker"; then
        echo "#$pr: conflicts with main; already said so."
        continue
      fi
      echo "#$pr: conflicts with main; commenting."
      act gh pr comment "$pr" --body "$marker
This pull request conflicts with main since #$MERGED was merged." >/dev/null
      ;;
  esac
done
