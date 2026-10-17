#!/usr/bin/env bash
# Watches the pipeline from a terminal: announces workflow runs as they come in, in every
# repo of the organization that has workflows, shows each step as it starts and finishes,
# and streams the live step logs from the self-hosted runner on this Mac. The repos are
# found when it starts, so restart it after adding a project.
#
# Usage: scripts/watch.sh            # leave it running; Ctrl-C to stop
#        QUIET=1 scripts/watch.sh    # runs and steps only, no log lines
# Optional env: REPO (owner/name: watch only that one), PIPELINE_ORG (default GoApps213),
#               RUNNER_DIR (default ~/actions-runner)
set -uo pipefail

RUNNER_DIR=${RUNNER_DIR:-$HOME/actions-runner}
PAGES="$RUNNER_DIR/_diag/pages"   # the runner writes each step's live log here
ORG=${PIPELINE_ORG:-GoApps213}
REPOS=()
if [ -n "${REPO:-}" ]; then
  REPOS=("$REPO")
else
  while IFS= read -r r; do
    [ "$(gh api "repos/$r/actions/workflows" --jq .total_count 2>/dev/null || echo 0)" -gt 0 ] && REPOS+=("$r")
  done < <(gh repo list "$ORG" --no-archived --limit 100 --json nameWithOwner --jq '.[].nameWithOwner' | sort)
fi
STATE=$(mktemp -d)
touch "$STATE/events" "$STATE/announced" "$STATE/done"

bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; cyan=$'\033[36m'; off=$'\033[0m'
say() { printf '%s%s%s %s\n' "$dim" "$(date +%H:%M:%S)" "$off" "$*"; }

cleanup() {
  for m in "$STATE"/tail-*; do [ -s "$m" ] && kill "$(cat "$m")" 2>/dev/null; done
  kill $(jobs -p) 2>/dev/null
  rm -rf "$STATE"
}
trap cleanup EXIT
trap 'exit 0' INT TERM

# Follow every log file the runner creates. The runner deletes a file once the
# step's log is uploaded, so each tail is stopped when its file disappears.
stream_logs() {
  while true; do
    for f in "$PAGES"/*.log; do
      [ -e "$f" ] || continue
      m="$STATE/tail-$(basename "$f")"
      [ -e "$m" ] && continue
      ( tail -n +1 -f "$f" 2>/dev/null & echo $! > "$m"; wait ) 2>/dev/null \
        | sed -l -E "s/^[0-9-]+T[0-9:.]+Z //; s/^/${dim}  │${off} /" &
    done
    for m in "$STATE"/tail-*; do
      [ -s "$m" ] || continue
      f="$PAGES/${m##*/tail-}"
      if [ ! -e "$f" ]; then
        sleep 1                       # let tail drain the last lines
        kill "$(cat "$m")" 2>/dev/null
        : > "$m"                      # keep the marker so the file isn't followed twice
      fi
    done
    sleep 0.5
  done
}

runner_hint() {
  if pgrep -f "Runner.Listener" >/dev/null; then
    say "${green}Runner is up.${off}"
  else
    say "${yellow}Runner is not running; jobs will wait in the queue.${off}"
    say "${yellow}Start it in another terminal: cd $RUNNER_DIR && ./run.sh${off}"
  fi
}

# Print step changes for run $1 in repo $2 that haven't been printed yet
show_steps() {
  gh run view "$1" -R "$2" --json jobs --jq '
    .jobs[] | .name as $j | .steps[] | select(.status != "pending" and .status != "queued")
    | [$j, .name, .status, (.conclusion // "")] | @tsv' 2>/dev/null \
  | while IFS=$'\t' read -r job step status conclusion; do
      key="$1|$job|$step|$status"
      grep -Fxq "$key" "$STATE/events" && continue
      echo "$key" >> "$STATE/events"
      case "$status/$conclusion" in
        in_progress/*)       say "${cyan}▶ $step${off}" ;;
        completed/success)   say "${green}✓ $step${off}" ;;
        completed/skipped)   say "${dim}- $step (skipped)${off}" ;;
        completed/*)         say "${red}✗ $step ($conclusion)${off}" ;;
      esac
    done
}

# One line per recent run of every watched repo: the repo first, then the run's fields.
# A run with no conclusion yet gets "-": read merges two tabs in a row, which would shift the
# fields after an empty one.
list_runs() {
  local r
  for r in "${REPOS[@]}"; do
    gh run list -R "$r" --limit 15 \
      --json databaseId,status,conclusion,displayTitle,workflowName,event,url \
      --jq '.[] | [.databaseId, .status, (if (.conclusion // "") == "" then "-" else .conclusion end),
                   .workflowName, .event, .url, .displayTitle] | @tsv' \
      2>/dev/null | awk -v r="$r" '{ print r "\t" $0 }'
  done
}

[ "${#REPOS[@]}" -gt 0 ] || { say "No repo in $ORG has workflows to watch."; exit 1; }
say "${bold}Watching ${REPOS[*]#*/}${off}  (Ctrl-C to stop)"
runner_hint

# Runs that finished before the watcher started are not reported
list_runs | awk -F'\t' '$3 == "completed" {print $2}' > "$STATE/done"

[ -n "${QUIET:-}" ] || stream_logs &

idle_note=0
while true; do
  active=0
  while IFS=$'\t' read -r repo id status conclusion workflow event url title; do
    [ -n "$id" ] || continue
    grep -Fxq "$id" "$STATE/done" && continue

    if ! grep -Fxq "$id" "$STATE/announced"; then
      echo "$id" >> "$STATE/announced"
      echo
      say "${bold}━━ ${repo#*/}: $workflow run started ($event): $title${off}"
      say "${dim}$url${off}"
      [ "$status" = queued ] && runner_hint
    fi

    show_steps "$id" "$repo"

    if [ "$status" = completed ]; then
      echo "$id" >> "$STATE/done"
      sleep 2   # let the last log lines print before the result
      if [ "$conclusion" = success ]; then
        say "${green}${bold}━━ ${repo#*/}: $workflow finished: success${off}"
      else
        say "${red}${bold}━━ ${repo#*/}: $workflow finished: $conclusion${off}"
        say "Log of the failed step:"
        gh run view "$id" -R "$repo" --log-failed 2>/dev/null | cut -f3- | tail -40
      fi
      echo
    else
      active=1
    fi
  done < <(list_runs)

  if [ "$active" = 1 ]; then
    idle_note=0; sleep 4
  else
    [ "$idle_note" = 0 ] && say "${dim}Waiting for the next run…${off}" && idle_note=1
    sleep 10
  fi
done
