#!/usr/bin/env bash
# Process handling for scripts/agent-run.sh, which sources this file. It runs the long steps
# (agent, verification, review) so that a cancelled job can stop everything they started, and
# stops what an earlier run left behind.
#
# Every kill here is of a process this run or an earlier run started, or one under it. A
# process is identified by its PID and start time together, never by name, so a PID that
# has since been given to something else is left alone.
#
# Needs STEPS_FILE: where the running script and step are recorded. It must be outside the
# checkout, so it survives the next job's clean checkout.

STEP_PID=""            # the step under way, or empty
LEFTOVERS_STOPPED=""   # set by stop_leftovers when it stopped something

# The caller's ERR trap reaches into these functions and their $( ) subshells, so a command
# that fails for a process that has gone is always followed by || true.

# When PID $1 started. Empty once the process is gone.
started_at() { { ps -o lstart= -p "$1" 2>/dev/null || true; } | tr -s ' ' | sed 's/^ //; s/ $//'; }

# Every process under PID $1, from one snapshot of the process table
descendants() {
  ps -axo pid=,ppid= | awk -v root="$1" '
    { parent[$1] = $2 }
    END {
      for (pid in parent) {
        p = pid
        while (p in parent && p != root) p = parent[p]
        if (p == root && pid != root) print pid
      }
    }'
}

# Stops PID $1 and everything under it: TERM, then KILL for whatever is left after 3 seconds.
# The process group is signalled too when $1 leads one, which reaches a child whose parent
# has already gone.
stop_tree() {
  local root=$1 pids group="" pid alive
  pids="$root $(descendants "$root" | tr '\n' ' ')"
  if [ "$({ ps -o pgid= -p "$root" 2>/dev/null || true; } | tr -d ' ')" = "$root" ]; then group="-$root"; fi

  signal_all() {
    # shellcheck disable=SC2086  # the list is meant to split
    kill "-$1" $pids 2>/dev/null || true
    if [ -n "$group" ]; then kill "-$1" -- "$group" 2>/dev/null || true; fi
  }
  signal_all TERM
  for _ in 1 2 3; do
    alive=""
    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then alive=1; fi
    done
    if [ -n "$group" ] && kill -0 -- "$group" 2>/dev/null; then alive=1; fi
    [ -n "$alive" ] || return 0
    sleep 1
  done
  signal_all KILL
}

# Writes this script, and the step under way if there is one, to STEPS_FILE
record_steps() {
  {
    echo "$$|$(started_at $$)"
    if [ -n "$STEP_PID" ]; then echo "$STEP_PID|$(started_at "$STEP_PID")"; fi
  } > "$STEPS_FILE"
}

# Runs a command as a step: in its own process group, and waited for in a way a signal can
# interrupt, so the cancel handler runs at once instead of after the step has finished.
run_step() {
  local rc=0
  set -m          # job control gives the background command a process group of its own
  "$@" &
  STEP_PID=$!
  set +m
  record_steps
  wait "$STEP_PID" || rc=$?
  STEP_PID=""
  record_steps
  return "$rc"
}

# Stops the step under way, if there is one
stop_step() {
  if [ -n "$STEP_PID" ]; then stop_tree "$STEP_PID"; fi
  STEP_PID=""
}

# Stops the script and step an earlier run recorded, if they are still running. A run that
# ended normally removed its STEPS_FILE, so this finds something only after a run was killed.
stop_leftovers() {
  local pid start
  LEFTOVERS_STOPPED=""
  [ -f "$STEPS_FILE" ] || return 0
  while IFS='|' read -r pid start; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    if [ "$pid" != "$$" ] && [ -n "$start" ] && [ "$(started_at "$pid")" = "$start" ]; then
      echo "Stopping process $pid, left behind by an earlier run."
      stop_tree "$pid"
      LEFTOVERS_STOPPED=1
    fi
  done < "$STEPS_FILE"
  rm -f "$STEPS_FILE"
}
