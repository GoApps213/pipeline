#!/usr/bin/env bash
# Runs one agent pass for a ticket: gather the issue, run the agent, verify, open the PR,
# then have a second agent session review it.
# Called by .github/workflows/agent.yml for a new request, a reply to the agent's
# questions, or an "@agent" comment on the ticket's pull request. It runs in the project's
# checkout, on main; the project supplies .agent/project.json and scripts/verify.sh.
# Env: ISSUE_NUMBER, GH_TOKEN, GITHUB_REPOSITORY, PIPELINE_DIR (this pipeline, downloaded);
#      optional PR_NUMBER (set for a PR comment), TRIGGER (the event name),
#      ATTACHMENTS_TOKEN, PIPELINE_OWNER (the person asked to review the PR).
# The agent and its model are the ones chosen with scripts/model.sh on this Mac.
#
# The order below matters: map a PR to its ticket, check the ticket, gather it,
# detect a resume, run the loop, then review.
# The agent, verification and review run through run_step (scripts/steps.sh), so a
# cancelled job stops them. The workflow starts this script with exec so the runner's
# signal reaches it.
set -Eeuo pipefail
. "$(dirname "$0")/steps.sh"

main() {
  export GH_REPO="$GITHUB_REPOSITORY"
  N="$ISSUE_NUMBER"
  PR_NUMBER="${PR_NUMBER:-}"
  RUN=.agent/run
  MAX_RETRIES=2
  MAX_REVIEW_ROUNDS=2
  # Paths the agent must never change: the pipeline's parts in the project, files that run
  # code at build time, and the instructions later runs read. The project adds its own, such
  # as its Xcode project file, in .agent/project.json (read below).
  PROTECTED=(scripts fastlane .github .claude .agent/project.json CLAUDE.md .mcp.json)

  # A comment on the PR: map it back to the ticket
  if [ -n "$PR_NUMBER" ]; then
    IFS=$'\t' read -r head pr_state < <(gh pr view "$PR_NUMBER" --json headRefName,state \
      --jq '[.headRefName, .state] | @tsv')
    case "$head" in
      ai/issue-*) N="${head#ai/issue-}" ;;
      *) echo "PR #$PR_NUMBER was not opened by the pipeline; nothing to do."; exit 0 ;;
    esac
    if [ "$pr_state" != OPEN ]; then
      echo "PR #$PR_NUMBER is no longer open; nothing to do."; exit 0
    fi
  fi
  BRANCH="ai/issue-$N"

  # A run that was killed can leave an agent or a build working in this checkout. Stop it
  # before anything is read from the checkout, and drop whatever it wrote after the checkout step.
  STEPS_FILE="${RUNNER_WORKSPACE:-$(dirname "$PWD")}/agent-run.steps"
  trap 'rm -rf "${TOOLS:-}" "$STEPS_FILE"' EXIT
  stop_leftovers
  if [ -n "$LEFTOVERS_STOPPED" ]; then
    git reset -q --hard && git clean -qffdx
  fi
  record_steps

  # Run from copies taken before anything else happens, so a branch switch or an agent edit
  # can't change the code that is running: the pipeline's scripts and agent files from the
  # download the workflow made, and the project's scripts and config (below) from main.
  TOOLS=$(mktemp -d)
  cp -R "$PIPELINE_DIR/scripts" "$TOOLS/scripts"
  cp -R "$PIPELINE_DIR/agent" "$TOOLS/agent"
  export PROMPT_DIR="$TOOLS/agent"

  status() { "$TOOLS/scripts/status.sh" "$N" "$@"; }
  fail()   { status failed "$1"; exit 1; }
  push()   {
    local auth; auth=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64)
    git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" push -q -u origin "$BRANCH" ||
      fail "Could not push $BRANCH; see the Actions log. If main changed a workflow file since the branch was made, merge main into it by hand"
  }
  # Asks the owner to review, which is what sends them a notification. A request that is
  # still pending is withdrawn first, since asking again would otherwise send nothing.
  # Never fails the run.
  request_review() {
    [ -n "${PIPELINE_OWNER:-}" ] || return 0
    local pr; pr=$(gh pr view "$BRANCH" --json number --jq .number) || return 0
    gh api -X DELETE "repos/$GITHUB_REPOSITORY/pulls/$pr/requested_reviewers" \
      -f "reviewers[]=$PIPELINE_OWNER" >/dev/null 2>&1 || true
    gh api -X POST "repos/$GITHUB_REPOSITORY/pulls/$pr/requested_reviewers" \
      -f "reviewers[]=$PIPELINE_OWNER" >/dev/null || echo "Could not request a review" >&2
  }
  # Called after the agent and again after verification, because the build and the
  # tests run code the agent wrote and everything in the tree is committed afterwards.
  check_protected() {
    if merging; then
      # Until the merge is committed, what main changed in these paths is staged too. The
      # branch never changes them, so after a merge they must be exactly main's.
      if [ -n "$(git diff --name-only origin/main -- "${PROTECTED[@]}"
                 git ls-files --others --exclude-standard -- "${PROTECTED[@]}")" ]; then
        fail "Protected pipeline files differ from main after merging it; nothing was pushed"
      fi
    elif [ -n "$(git status --porcelain -- "${PROTECTED[@]}")" ]; then
      fail "Agent changed protected pipeline files; nothing was pushed"
    fi
  }
  # A merge of main that stopped on conflicts and has not been committed yet
  merging() { git rev-parse -q --verify MERGE_HEAD >/dev/null; }
  # Brings an existing branch up to date with main, so the agent works on, and verification
  # tests, what merging the pull request would produce. The agent can't run git merge, so
  # conflicts are left in the files for it to resolve by editing; the commit made after
  # verification concludes the merge.
  CONFLICTS=""
  merge_main() {
    if git merge-base --is-ancestor origin/main HEAD; then return 0; fi
    if git merge -q --no-edit -m "Merge main into $BRANCH" origin/main >/dev/null 2>&1; then
      echo "Merged main into $BRANCH."
      echo "main was merged into this branch before this run, so files may differ from what you last saw." > "$RUN/merge.md"
      return 0
    fi
    CONFLICTS=$(git diff --name-only --diff-filter=U)
    if [ -z "$CONFLICTS" ]; then fail "Could not merge main into $BRANCH"; fi
    if [ -n "$(git diff --name-only --diff-filter=U -- "${PROTECTED[@]}")" ]; then
      fail "main conflicts with $BRANCH in pipeline files the agent may not edit; merge it by hand"
    fi
    echo "Merged main into $BRANCH; conflicts in:"; echo "$CONFLICTS"
    {
      echo "main was merged into this branch before this run, so files may differ from what you last saw."
      echo "These files conflicted and hold conflict markers (<<<<<<< HEAD is this branch, >>>>>>> origin/main is main):"
      echo
      sed 's/^/- /' <<<"$CONFLICTS"
    } > "$RUN/merge.md"
  }
  # Fails, with the reason in feedback.log, while a file that conflicted still has markers.
  # The build catches them in Swift files, but not in a rules file or a document.
  resolved() {
    [ -n "$CONFLICTS" ] || return 0
    local f left=""
    while IFS= read -r f; do
      if [ -f "$f" ] && grep -qE '^(<<<<<<<|>>>>>>>) ' "$f"; then left+="- $f"$'\n'; fi
    done <<<"$CONFLICTS"
    [ -z "$left" ] && return 0
    printf 'Conflict markers from the merge of main are still in:\n%s' "$left" > "$RUN/feedback.log"
    return 1
  }
  # A cancelled ticket is closed first and its run stopped afterwards (scripts/cancel.sh).
  # That run must not report a failure on its way out.
  on_error() {
    if [ "$(gh api "repos/$GITHUB_REPOSITORY/issues/$N" --jq .state 2>/dev/null)" = closed ]; then
      echo "Ticket #$N was closed during the run; leaving its status alone."
      return
    fi
    status failed "Agent run stopped unexpectedly; see the Actions log" || true
  }
  trap on_error ERR
  # The job hit its time limit or was cancelled. The runner allows about ten seconds before it
  # kills this script, and a step that outlived it would carry on in the next run's checkout.
  on_cancel() {
    trap '' INT TERM
    trap - ERR
    echo "Run cancelled; stopping the step under way."
    stop_step
    exit 130
  }
  trap on_cancel INT TERM

  # The project's part: scripts/verify.sh (and anything it calls), and .agent/project.json,
  # which names the files it protects as well and where its ticket images are kept. The
  # agent's settings get a deny rule for each of those files.
  [ -x scripts/verify.sh ] || fail "This repo has no scripts/verify.sh; see the pipeline repo's README"
  cp -R scripts "$TOOLS/project"
  PROJECT="$TOOLS/project.json"
  cp .agent/project.json "$PROJECT" 2>/dev/null ||
    fail "This repo has no .agent/project.json; see the pipeline repo's README"
  jq -e '(.protected // []) | type == "array" and all(.[]; type == "string" and length > 0)' \
    "$PROJECT" >/dev/null || fail ".agent/project.json is not valid: \"protected\" must be a list of paths"
  while IFS= read -r file; do PROTECTED+=("$file"); done < <(jq -r '.protected // [] | .[]' "$PROJECT")
  jq --slurpfile p "$PROJECT" '.permissions.deny += [($p[0].protected // [])[] | "Edit(\(.))"]' \
    "$PIPELINE_DIR/agent/settings.json" > "$TOOLS/agent/settings.json"
  attachments=$(jq -r '.attachments_repo // ""' "$PROJECT")
  if [ -n "$attachments" ]; then export ATTACHMENTS_REPO="${GITHUB_REPOSITORY%%/*}/$attachments"; fi

  # A run can wait in the queue for a while. Skip it quietly if the ticket was
  # deleted, closed, or had its request label removed in the meantime.
  if ! ticket=$(gh api "repos/$GITHUB_REPOSITORY/issues/$N" \
        --jq '[.state, ([.labels[].name] | join(","))] | @tsv' 2>/dev/null); then
    echo "Ticket #$N no longer exists; nothing to do."
    exit 0
  fi
  IFS=$'\t' read -r ticket_state ticket_labels <<<"$ticket"
  if [ "$ticket_state" != open ]; then
    echo "Ticket #$N is closed; nothing to do."
    exit 0
  fi
  case ",$ticket_labels," in
    *,ai-request,*|*,ai-approved,*) ;;
    *) echo "Ticket #$N no longer has a request label; nothing to do."; exit 0 ;;
  esac

  # Which agent and model: the one chosen with scripts/model.sh, looked up in main's list
  if ! chosen=$(MODELS_FILE="$TOOLS/agent/models.json" "$TOOLS/scripts/model.sh" --resolve); then
    fail "The chosen model is not in the pipeline's agent/models.json; run scripts/model.sh on the Mac"
  fi
  AGENT_NAME=$(jq -r .name <<<"$chosen")
  export AGENT_ADAPTER="$(jq -r .adapter <<<"$chosen")"
  export AGENT_MODEL="$(jq -r .model <<<"$chosen")"
  ADAPTER="$TOOLS/scripts/adapters/$AGENT_ADAPTER.sh"
  [ -x "$ADAPTER" ] || fail "There is no adapter for $AGENT_NAME (scripts/adapters/$AGENT_ADAPTER.sh)"
  echo "Agent: $AGENT_NAME"

  # What kind of run is this?
  MODE=new
  case ",$ticket_labels," in *,ai:needs-input,*) MODE=answer ;; esac
  [ -n "$PR_NUMBER" ] && MODE=feedback

  # A request that skips UI tests is verified with the unit tests only (VERIFY_UNIT_ONLY,
  # which verify.sh reads when it is run with no test names)
  VERIFY_ENV=()
  case ",$ticket_labels," in *,ai-skip-ui-tests,*) VERIFY_ENV=(VERIFY_UNIT_ONLY=1) ;; esac

  # A second reply sent before the first was picked up has nothing left to answer
  if [ "${TRIGGER:-}" = issue_comment ] && [ "$MODE" = new ]; then
    echo "Ticket #$N is not waiting for an answer; nothing to do."
    exit 0
  fi

  # An answer or PR feedback continues the session the agent was in
  if [ "$MODE" != new ]; then
    saved=$(gh api "repos/$GITHUB_REPOSITORY/issues/$N/comments" --paginate \
      --jq '.[] | select(.body | startswith("<!-- ai-status -->")) | .body' \
      | sed -n 's/^<!-- data: \(.*\) -->$/\1/p' | head -1 | jq -r '.session_id // ""' || true)
    [ -n "$saved" ] && export RESUME_SESSION="$saved"
  fi

  rm -rf "$RUN" && mkdir -p "$RUN/images"
  # Token counts the adapter records; each status update moves them into the ticket's total
  export USAGE_FILE="$RUN/usage.jsonl"
  git config user.name "Pipeline Agent"            # repo-local, not --global
  git config user.email "agent@users.noreply.github.com"

  case "$MODE" in
    new)      status running "Agent run started ($AGENT_NAME)" ;;
    answer)   status running "Continuing with your answer ($AGENT_NAME)" ;;
    feedback) status running "Working on your pull request comment ($AGENT_NAME)" ;;
  esac

  # 1. Gather the ticket, its images, and any PR feedback
  gh issue view "$N" --json title,body,comments,labels > "$RUN/issue.json"
  TITLE=$(jq -r .title "$RUN/issue.json")
  if [ -n "${ATTACHMENTS_TOKEN:-}" ] && [ -x "$TOOLS/scripts/attachments.sh" ]; then
    "$TOOLS/scripts/attachments.sh" download "$RUN/issue.json" "$RUN/images"
  fi
  if [ "$MODE" = feedback ]; then
    jq -n --argjson pr "$(gh pr view "$PR_NUMBER" --json comments,reviews)" \
          --argjson inline "$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/comments" \
                               --jq '[.[] | {path, line, body, user: .user.login}]')" \
      '$pr + {inline_comments: $inline}' > "$RUN/pr-feedback.json"
  fi

  # 2. Reuse the branch if it exists, otherwise start from main
  if git rev-parse --verify -q "origin/$BRANCH" >/dev/null; then
    git checkout -q -B "$BRANCH" "origin/$BRANCH"
    merge_main
  else
    git checkout -q -B "$BRANCH" origin/main
  fi

  # Agent, then verify; on failure, resume the session with the errors.
  # Returns when build and tests pass; ends the run on questions or failure.
  implement_and_verify() {
    local attempt=0
    while true; do
      # The agent gets no GitHub tokens
      run_step env -u GH_TOKEN -u GITHUB_TOKEN -u ATTACHMENTS_TOKEN \
        "$ADAPTER" implement "$RUN"
      export SESSION_ID="$(jq -r .session_id "$RUN/result.json")"

      check_protected
      case "$(jq -r .status "$RUN/result.json")" in
        needs_input)
          # keep any work in progress, since the next run starts from a clean checkout.
          # Not while conflict markers are left: the next run merges main again instead.
          if resolved; then
            git add -A
            if merging || ! git diff --cached --quiet; then
              git commit -q -m "WIP #$N: waiting for answers" && push
            fi
          fi
          { echo "**The agent has questions:**"; echo; cat "$RUN/questions.md"; } > "$RUN/q.md"
          gh issue comment "$N" --body-file "$RUN/q.md" >/dev/null
          status needs-input "Agent has questions"
          exit 0 ;;
        failure)
          fail "Agent run failed" ;;
      esac

      # Verification builds and runs the agent's code, so it gets no tokens either
      if [ ${#VERIFY_ENV[@]} -gt 0 ]; then
        echo "Verifying (build and unit tests; the request skips UI tests)…"
      else
        echo "Verifying (build and tests)…"
      fi
      if resolved && run_step env -u GH_TOKEN -u GITHUB_TOKEN -u ATTACHMENTS_TOKEN ${VERIFY_ENV[@]+"${VERIFY_ENV[@]}"} \
           "$TOOLS/project/verify.sh" > "$RUN/feedback.log" 2>&1; then
        check_protected
        rm "$RUN/feedback.log"; break
      fi
      check_protected
      tail -40 "$RUN/feedback.log"
      attempt=$((attempt + 1))
      if [ "$attempt" -gt "$MAX_RETRIES" ]; then
        fail "Build or tests still failing after $MAX_RETRIES retries"
      fi
      export RESUME_SESSION="$SESSION_ID"
    done
  }

  # 3. Implement
  implement_and_verify

  # 4. Commit, push, open the PR (or update the existing one)
  git add -A   # .agent/run is gitignored; naming it in a pathspec makes git exit 1
  if ! merging && git diff --cached --quiet; then
    if [ "$MODE" = feedback ]; then
      # Nothing to change is a valid answer to a comment. A merge of main still goes up.
      note="No changes were needed for your comment"
      if [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$BRANCH")" ]; then
        push; note="Merged main; no other changes were needed"
      fi
      if [ -s "$RUN/summary.md" ]; then gh pr comment "$PR_NUMBER" --body-file "$RUN/summary.md" >/dev/null; fi
      status in-review "$note"
      exit 0
    fi
    # A branch that already holds work in progress is fine to open as a PR
    if [ -z "$(git log --oneline "origin/main..HEAD")" ]; then
      fail "Agent finished without changing any files"
    fi
  else
    if [ "$MODE" = feedback ]; then msg="Address feedback on #$N: $TITLE"; else msg="Implement #$N: $TITLE"; fi
    if merging; then msg="$msg (merges main)"; fi
    git commit -q -m "$msg"
  fi
  push

  {
    if [ -s "$RUN/summary.md" ]; then cat "$RUN/summary.md"; else echo "The agent did not write a summary."; fi
    echo; echo "Closes #$N"
  } > "$RUN/pr-body.md"
  if gh pr view "$BRANCH" --json url >/dev/null 2>&1; then
    if [ "$MODE" = feedback ] && [ -s "$RUN/summary.md" ]; then
      gh pr comment "$BRANCH" --body-file "$RUN/summary.md" >/dev/null
    fi
    request_review
    PR_URL="$(gh pr view "$BRANCH" --json url --jq .url)" status in-review "PR updated"
    exit 0
  fi
  gh pr create --head "$BRANCH" --base main --title "$TITLE" --body-file "$RUN/pr-body.md"
  export PR_URL="$(gh pr view "$BRANCH" --json url --jq .url)"
  status running "PR opened"

  # 5. AI review, by a fresh session. Blocking findings go back to the author's session.
  AUTHOR_SESSION="$SESSION_ID"
  round=0
  while true; do
    if run_step "$TOOLS/scripts/review.sh" "$N"; then break; else rc=$?; fi
    if [ "$rc" -ne 2 ]; then
      gh pr comment "$BRANCH" --body "AI review could not run; this pull request has not been reviewed." >/dev/null
      break
    fi
    round=$((round + 1))
    if [ "$round" -gt "$MAX_REVIEW_ROUNDS" ]; then
      gh pr comment "$BRANCH" --body "Review round limit reached; open findings are left for you." >/dev/null
      break
    fi
    status running "Fixing review findings (round $round)"
    cp "$RUN/review.md" "$RUN/feedback.log"
    export RESUME_SESSION="$AUTHOR_SESSION"
    implement_and_verify
    AUTHOR_SESSION="$SESSION_ID"
    git add -A
    if git diff --cached --quiet; then
      gh pr comment "$BRANCH" --body "The author made no changes in response to the review; open findings are left for you." >/dev/null
      break
    fi
    git commit -q -m "Address review for #$N" && push
  done
  request_review
  SESSION_ID="$AUTHOR_SESSION" status in-review "Ready for your review"
}

main "$@"
