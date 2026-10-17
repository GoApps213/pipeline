#!/usr/bin/env bash
# Watches the pipeline from a terminal: announces workflow runs as they come in,
# shows each step as it starts and finishes, and streams the live step logs
# from the self-hosted runner on this Mac.
#
# Usage: scripts/watch.sh            # leave it running; Ctrl-C to stop
#        QUIET=1 scripts/watch.sh    # runs and steps only, no log lines
# Optional env: REPO (owner/name), RUNNER_DIR (default ~/actions-runner)
set -uo pipefail

RUNNER_DIR=${RUNNER_DIR:-$HOME/actions-runner}
PAGES="$RUNNER_DIR/_diag/pages"   # the runner writes each step's live log here
REPO=${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
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

# Print step changes for one run that haven't been printed yet
show_steps() {
  gh run view "$1" -R "$REPO" --json jobs --jq '
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

list_runs() {
  gh run list -R "$REPO" --limit 15 \
    --json databaseId,status,conclusion,displayTitle,workflowName,event,url \
    --jq '.[] | [.databaseId, .status, (.conclusion // ""), .workflowName, .event, .url, .displayTitle] | @tsv' 2>/dev/null
}

say "${bold}Watching $REPO${off}  (Ctrl-C to stop)"
runner_hint

# Runs that finished before the watcher started are not reported
list_runs | awk -F'\t' '$2 == "completed" {print $1}' > "$STATE/done"

[ -n "${QUIET:-}" ] || stream_logs &

idle_note=0
while true; do
  active=0
  while IFS=$'\t' read -r id status conclusion workflow event url title; do
    [ -n "$id" ] || continue
    grep -Fxq "$id" "$STATE/done" && continue

    if ! grep -Fxq "$id" "$STATE/announced"; then
      echo "$id" >> "$STATE/announced"
      echo
      say "${bold}━━ $workflow run started ($event): $title${off}"
      say "${dim}$url${off}"
      [ "$status" = queued ] && runner_hint
    fi

    show_steps "$id"

    if [ "$status" = completed ]; then
      echo "$id" >> "$STATE/done"
      sleep 2   # let the last log lines print before the result
      if [ "$conclusion" = success ]; then
        say "${green}${bold}━━ $workflow finished: success${off}"
      else
        say "${red}${bold}━━ $workflow finished: $conclusion${off}"
        say "Log of the failed step:"
        gh run view "$id" -R "$REPO" --log-failed 2>/dev/null | cut -f3- | tail -40
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
