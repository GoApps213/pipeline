#!/usr/bin/env bash
# The agent adapter: task and run folder in, result.json out.
# Usage: claude-code.sh <task> <run-dir>
# Writes <run-dir>/result.json: {"status": "success|failure|needs_input", "session_id": "..."}
# and adds a line of token counts to <run-dir>/usage.jsonl
# Optional env: PROMPT_DIR (default .agent), RESUME_SESSION, AGENT_MODEL
set -uo pipefail
TASK=$1; RUN=$2
PROMPT_DIR=${PROMPT_DIR:-.agent}

# The file tools are deliberately not in these lists: a bare Read, Edit or Write
# rule reaches the whole disk. Without one, reads are limited to the working
# directory, and writes to what the permission mode and the rules here accept.
case "$TASK" in
  implement) MODE=acceptEdits   # edits inside the working directory are accepted
             # verify.sh takes test names and refuses anything else, so its arguments are open
             ALLOWED="Bash(scripts/verify.sh),Bash(scripts/verify.sh:*),Bash(git diff:*),Bash(git status:*)" ;;
  # The reviewer writes only its review files; review.sh discards any other change
  review)    MODE=default
             ALLOWED="Edit(.agent/run/**),Bash(git diff:*)" ;;
  *) echo "Unknown task: $TASK" >&2; exit 2 ;;
esac

# --setting-sources project keeps your personal Claude Code settings, hooks and
# allow rules out of the run; .agent/settings.json adds the deny rules and sandbox.
ARGS=(-p "$(cat "$PROMPT_DIR/prompt-$TASK.md")"
      --output-format json
      --permission-mode "$MODE"
      --setting-sources project
      --settings "$PROMPT_DIR/settings.json"
      --strict-mcp-config)
[ -n "${AGENT_MODEL:-}" ] && ARGS+=(--model "$AGENT_MODEL")

CLAUDE=$(command -v claude || echo "$HOME/.local/bin/claude")

# Appends this session's token counts to <run-dir>/usage.jsonl, one line per session,
# failed ones included. status.sh adds them to the ticket's running total.
record_usage() {
  jq -c '{input: .usage.input_tokens, output: .usage.output_tokens,
          cache_read: .usage.cache_read_input_tokens, cache_write: .usage.cache_creation_input_tokens,
          cost: .total_cost_usd} | select(.output != null)' <<<"$OUT" >> "$RUN/usage.jsonl" 2>/dev/null || true
}

# Runs the agent once. Sets OUT and returns 0 only for a run that finished without error.
run_agent() {
  local resume=$1 args=("${ARGS[@]}") rc=0
  [ -n "$resume" ] && args+=(--resume "$resume")
  args+=(--allowedTools "$ALLOWED")    # last: it takes a list
  OUT=$("$CLAUDE" "${args[@]}" < /dev/null) || rc=$?
  record_usage
  [ "$rc" -eq 0 ] || return 1
  [ "$(jq -r '.is_error' <<<"$OUT" 2>/dev/null)" = "false" ]
}

OK=0
if run_agent "${RESUME_SESSION:-}"; then
  OK=1
elif [ -n "${RESUME_SESSION:-}" ]; then
  # The saved session may be gone. A fresh one still has the ticket, the
  # questions, the answers and any work-in-progress commit to go on.
  echo "Could not resume session $RESUME_SESSION; starting a fresh one."
  run_agent "" && OK=1
fi

SID=""; STATUS=failure
if [ "$OK" = 1 ]; then
  printf '%s\n' "$OUT" > "$RUN/agent-output.json"
  SID=$(jq -r '.session_id // ""' <<<"$OUT")
  echo "--- Agent said:"; jq -r '.result // ""' <<<"$OUT"; echo "---"
  if [ -f "$RUN/questions.md" ]; then STATUS=needs_input; else STATUS=success; fi
else
  printf '%s\n' "${OUT:-}" | tail -20
fi
jq -n --arg s "$STATUS" --arg id "$SID" '{status: $s, session_id: $id}' > "$RUN/result.json"
