#!/usr/bin/env bash
# Starts everything the pipeline needs on this Mac, in one terminal:
#   1. the self-hosted Actions runner (unless one is already running)
#   2. caffeinate, so the Mac doesn't sleep while this is open
#   3. the watcher (scripts/watch.sh), which shows runs, steps and live logs
#
# Usage: scripts/pipeline.sh         # Ctrl-C stops all three
# Optional env: RUNNER_DIR (default ~/actions-runner), plus anything watch.sh takes
set -uo pipefail
set -m   # children get their own process groups, so Ctrl-C reaches this script only

export RUNNER_DIR=${RUNNER_DIR:-$HOME/actions-runner}
HERE=$(cd "$(dirname "$0")" && pwd)
LISTENER="$RUNNER_DIR/bin/Runner.Listener"
WORKER="$RUNNER_DIR/bin/Runner.Worker"

dim=$'\033[2m'; yellow=$'\033[33m'; green=$'\033[32m'; off=$'\033[0m'
say() { printf '%s%s%s %s\n' "$dim" "$(date +%H:%M:%S)" "$off" "$*"; }

STARTED_RUNNER=0; RUNNER_PGID=""; WATCH_PID=""; CAFFEINATE_PID=""; WARNED=0

stop_all() {
  trap - INT TERM
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
  if [ "$STARTED_RUNNER" = 1 ]; then
    say "Stopping the runner…"
    # Signals go only to the process group this script started, never by name
    if [[ "$RUNNER_PGID" =~ ^[0-9]+$ ]] && [ "$RUNNER_PGID" -gt 1 ]; then
      kill -INT -- "-$RUNNER_PGID" 2>/dev/null     # the runner shuts down cleanly on INT
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 -- "-$RUNNER_PGID" 2>/dev/null || break
        sleep 1
      done
      kill -TERM -- "-$RUNNER_PGID" 2>/dev/null
    fi
  fi
  [ -n "$CAFFEINATE_PID" ] && kill "$CAFFEINATE_PID" 2>/dev/null
  wait 2>/dev/null
  say "Stopped. The Mac can sleep again."
  exit 0
}

on_interrupt() {
  # Stopping the runner mid-job cancels the job, so ask for a second Ctrl-C
  if [ "$STARTED_RUNNER" = 1 ] && [ "$WARNED" = 0 ] && pgrep -f "$WORKER" >/dev/null; then
    WARNED=1
    echo
    say "${yellow}A job is running. Stopping now cancels it. Press Ctrl-C again to stop anyway.${off}"
    return
  fi
  echo
  stop_all
}
trap on_interrupt INT
trap stop_all TERM

# 1. Runner
if pgrep -f "$LISTENER" >/dev/null; then
  say "${yellow}A runner is already running; using it and leaving it alone on exit.${off}"
else
  [ -x "$RUNNER_DIR/run.sh" ] || { say "No runner found in $RUNNER_DIR"; exit 1; }
  ( cd "$RUNNER_DIR" && ./run.sh ) 2>&1 | sed -l "s/^/${dim}  runner │${off} /" &
  RUNNER_PGID=$(ps -o pgid= -p $! | tr -d ' ')
  STARTED_RUNNER=1
  for _ in $(seq 1 20); do
    pgrep -f "$LISTENER" >/dev/null && break
    sleep 0.5
  done
  pgrep -f "$LISTENER" >/dev/null || { say "The runner did not start."; stop_all; }
fi

say "Agent model: $("$HERE/model.sh" --show 2>/dev/null || echo "not set; run scripts/model.sh")"

# 2. Keep the Mac awake (idle and system sleep) for as long as this script lives
caffeinate -is -w $$ &
CAFFEINATE_PID=$!
say "${green}Sleep is blocked while this is open.${off}"

# 3. Watcher
"$HERE/watch.sh" &
WATCH_PID=$!
while kill -0 "$WATCH_PID" 2>/dev/null; do
  wait "$WATCH_PID" 2>/dev/null
done
stop_all
