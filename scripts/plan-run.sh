#!/usr/bin/env bash
# Runs one planning pass on a project's plan issue: the open issue labelled ai-plan that
# GoBuild's Plan screen talks over with the agent (the format is in GoApps213/gobuild's
# docs/plan.md). Called by .github/workflows/agent.yml instead of agent-run.sh for that
# issue, when the owner adds ai-plan to it or comments on it.
#
# The plan is the Markdown files in docs/Tasks/, with docs/Changelog.md and docs/UserGuide.md.
# The agent keeps its changes to them on one open pull request from ai/plan, adding to it as
# the owner's messages come in. Only the owner's approval merges it: an "approve" comment
# naming the commit they saw. Nothing is verified or built, and release.yml ignores docs/**.
#
# A run deals with the owner's comments since the newest one the last run handled, which the
# status comment's data keeps as "handled": first the latest approval, then any messages. A
# run that fails leaves them unhandled, so the owner's next comment takes them up again.
# Env: ISSUE_NUMBER, GH_TOKEN, GITHUB_REPOSITORY, PIPELINE_DIR (this pipeline, downloaded),
#      PIPELINE_OWNER (whose comments count); optional TRIGGER (the event name: "issues" when
#      the label was added).
set -Eeuo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/steps.sh"

BRANCH=ai/plan
BOT='github-actions[bot]'
STATUS_MARKER='<!-- ai-status -->'

# The helpers below read the issue's comments as a JSON array of {id, body, user}, oldest first.
# kind: the plan marker a comment starts with ("message", "approve", "concern", "review",
# "updated"), or "" for none. data: the object on its data line, or {}.
JQ_DEFS='
  def kind: (.body | sub("^\\s+"; "") | capture("^<!-- ai-plan:(?<k>[a-z]+) -->") | .k) // "";
  def data: (.body | capture("<!-- data: (?<d>\\{.*\\}) -->") | .d | fromjson?) // {};
  def text: .body | sub("^\\s*<!-- ai-plan:[a-z]+ -->"; "") | gsub("<!-- data: \\{.*\\} -->"; "")
            | sub("^\\s+"; "") | sub("\\s+$"; "");'

# The owner's comments after comment $2
owner_comments_after() {
  jq -c --argjson after "$2" --arg owner "$3" '[.[] | select(.id > $after and .user == $owner)]' "$1"
}

# "<pr>\t<sha>" from the latest approval among the comments on stdin; nothing without one
latest_approval() {
  jq -r "$JQ_DEFS"'[.[] | select(kind == "approve") | data | select(.pr and .sha)] | last
                   | select(. != null) | "\(.pr)\t\(.sha)"'
}

# How many of the comments on stdin are messages: anything the owner wrote but an approval
message_count() {
  jq "$JQ_DEFS"'[.[] | select(kind != "approve")] | length'
}

# The conversation since the plan was last merged, for the agent: who wrote each comment,
# what kind it is, its text, and whether it came after comment $2, the last one handled. Only
# the owner's ($3) and the agent's comments count; the status comment, the review comment
# and approvals are left out.
conversation() {
  jq --arg bot "$BOT" --arg owner "$3" --arg status "$STATUS_MARKER" --argjson handled "$2" "$JQ_DEFS"'
    (map(select(.user == $bot and kind == "updated")) | last | .id // 0) as $since
    | [.[] | select(.id > $since and (.user == $bot or .user == $owner)
                    and (.body | startswith($status) | not) and kind != "review" and kind != "approve")
       | {from: (if .user == $bot then "agent" else "owner" end),
          kind: (kind | if . == "" then "message" else . end),
          new: (.id > $handled),
          text: text}]' "$1"
}

# The bot's review comment on the plan issue: "<id>\t<text>", or nothing
review_comment() {
  jq -r --arg bot "$BOT" "$JQ_DEFS"'[.[] | select(.user == $bot and kind == "review")] | first
                                     | select(. != null) | "\(.id)\t\(text | @json)"' "$1"
}

# Prints the paths on stdin that a planning run may not change
outside_plan() {
  local path
  while IFS= read -r path; do
    case "$path" in
      docs/Tasks/*|docs/Changelog.md|docs/UserGuide.md) ;;
      '') ;;
      *) echo "$path" ;;
    esac
  done
}

main() {
  export GH_REPO="$GITHUB_REPOSITORY"
  N="$ISSUE_NUMBER"
  RUN=.agent/run

  # A run that was killed can leave an agent working in this checkout. Stop it before anything
  # is read from the checkout, and drop whatever it wrote after the checkout step.
  STEPS_FILE="${RUNNER_WORKSPACE:-$(dirname "$PWD")}/agent-run.steps"
  trap 'rm -rf "${TOOLS:-}" "$STEPS_FILE"' EXIT
  stop_leftovers
  if [ -n "$LEFTOVERS_STOPPED" ]; then
    git reset -q --hard && git clean -qffdx
  fi
  record_steps

  # Run from copies taken before anything else happens, so a branch switch or an agent edit
  # can't change the code that is running
  TOOLS=$(mktemp -d)
  cp -R "$PIPELINE_DIR/scripts" "$TOOLS/scripts"
  cp -R "$PIPELINE_DIR/agent" "$TOOLS/agent"
  export PROMPT_DIR="$TOOLS/agent"

  status() { "$TOOLS/scripts/status.sh" "$N" "$@"; }
  fail()   { status failed "$1"; exit 1; }
  # Comments on the plan issue, with the body on stdin
  comment() { gh issue comment "$N" --body-file - >/dev/null; }
  concern() { { printf '<!-- ai-plan:concern -->\n\n%s\n' "$1"; } | comment; }
  push() {
    local auth; auth=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64)
    git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" push -q $FORCE -u origin "$BRANCH" ||
      fail "Could not push $BRANCH; see the Actions log"
  }
  merging() { git rev-parse -q --verify MERGE_HEAD >/dev/null; }
  # A closed plan issue is left alone, as a cancelled ticket is
  on_error() {
    if [ "$(gh api "repos/$GITHUB_REPOSITORY/issues/$N" --jq .state 2>/dev/null)" = closed ]; then
      echo "Plan issue #$N was closed during the run; leaving its status alone."
      return
    fi
    status failed "Planning run stopped unexpectedly; see the Actions log" || true
  }
  trap on_error ERR
  on_cancel() {
    trap '' INT TERM
    trap - ERR
    echo "Run cancelled; stopping the step under way."
    stop_step
    exit 130
  }
  trap on_cancel INT TERM

  # A run can wait in the queue for a while. Skip it quietly if the issue was deleted, closed,
  # or had its plan label removed in the meantime.
  if ! ticket=$(gh api "repos/$GITHUB_REPOSITORY/issues/$N" \
        --jq '[.state, ([.labels[].name] | join(","))] | @tsv' 2>/dev/null); then
    echo "Issue #$N no longer exists; nothing to do."
    exit 0
  fi
  IFS=$'\t' read -r ticket_state ticket_labels <<<"$ticket"
  if [ "$ticket_state" != open ]; then echo "Issue #$N is closed; nothing to do."; exit 0; fi
  case ",$ticket_labels," in
    *,ai-plan,*) ;;
    *) echo "Issue #$N is no longer a plan issue; nothing to do."; exit 0 ;;
  esac

  # Which agent and model: the one chosen with scripts/model.sh on this Mac
  if ! chosen=$(MODELS_FILE="$TOOLS/agent/models.json" "$TOOLS/scripts/model.sh" --resolve); then
    fail "The chosen model is not in the pipeline's agent/models.json; run scripts/model.sh on the Mac"
  fi
  AGENT_NAME=$(jq -r .name <<<"$chosen")
  export AGENT_ADAPTER="$(jq -r .adapter <<<"$chosen")"
  export AGENT_MODEL="$(jq -r .model <<<"$chosen")"
  ADAPTER="$TOOLS/scripts/adapters/$AGENT_ADAPTER.sh"
  [ -x "$ADAPTER" ] || fail "There is no adapter for $AGENT_NAME (scripts/adapters/$AGENT_ADAPTER.sh)"

  # What the owner has said since the last run. COMMENTS stays as it was when the run started.
  COMMENTS="$TOOLS/comments.json"
  fetch_comments() {
    gh api "repos/$GITHUB_REPOSITORY/issues/$N/comments" --paginate \
      --jq '.[] | {id, body, user: .user.login}' | jq -s . > "$1"
  }
  fetch_comments "$COMMENTS"
  handled=$(jq -r --arg m "$STATUS_MARKER" 'map(select(.body | startswith($m))) | first | .body // ""' "$COMMENTS" \
    | sed -n 's/^<!-- data: \(.*\) -->$/\1/p' | jq -r '.handled // 0' 2>/dev/null || true)
  handled=${handled:-0}
  newest=$(jq '[.[].id] | max // 0' "$COMMENTS")
  from_owner=$(owner_comments_after "$COMMENTS" "$handled" "${PIPELINE_OWNER:-}")
  approval=$(latest_approval <<<"$from_owner")
  messages=$(message_count <<<"$from_owner")
  # Adding the label asks for the first plan, while the project has none
  first=""
  if [ "${TRIGGER:-}" = issues ] && ! git cat-file -e origin/main:docs/Tasks/README.md 2>/dev/null; then
    first=1
  fi
  if [ -z "$approval" ] && [ "$messages" -eq 0 ] && [ -z "$first" ]; then
    echo "Nothing new from the owner on #$N; nothing to do."
    exit 0
  fi

  status running "Planning started ($AGENT_NAME)"
  note="Waiting for your messages"

  # Edits the bot's review comment, or writes it: the open plan pull request $1, with the
  # summary $2. With no pull request, empties it.
  set_review() {
    local pr=$1 summary=$2 body id
    fetch_comments "$TOOLS/latest.json"
    id=$(review_comment "$TOOLS/latest.json" | cut -f1)
    if [ -n "$pr" ]; then
      body=$(printf '<!-- ai-plan:review -->\n\n%s\n\n<!-- data: {"pr": %s} -->' "$summary" "$pr")
    else
      body='<!-- ai-plan:review -->'
      [ -n "$id" ] || return 0
    fi
    if [ -n "$id" ]; then
      gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$id" -f body="$body" >/dev/null
    else
      printf '%s\n' "$body" | comment
    fi
  }

  # 1. The latest approval: merge the plan pull request, if it is still at the commit approved
  if [ -n "$approval" ]; then
    IFS=$'\t' read -r pr sha <<<"$approval"
    info=$(gh pr view "$pr" --json headRefName,state,headRefOid \
      --jq '[.headRefName, .state, .headRefOid] | @tsv' 2>/dev/null || true)
    IFS=$'\t' read -r head state oid <<<"$info"
    if [ "$head" != "$BRANCH" ] || [ "$state" != OPEN ]; then
      concern "Plan pull request #$pr is no longer open, so there was nothing to merge."
    elif [ "$oid" != "$sha" ]; then
      concern "The plan changed after you approved it. Look at the changes again, and approve them if they're right."
    else
      files=$(gh pr view "$pr" --json files --jq '.files[].path')
      if gh pr merge "$pr" --squash --match-head-commit "$sha" >/dev/null; then
        gh api -X DELETE "repos/$GITHUB_REPOSITORY/git/refs/heads/$BRANCH" >/dev/null 2>&1 || true
        set_review "" ""
        { printf '<!-- ai-plan:updated -->\n\nMerged #%s into main:\n\n' "$pr"; sed 's/^/- /' <<<"$files"; } | comment
        note="Merged the plan into main (#$pr)"
      else
        concern "Plan pull request #$pr couldn't be merged; it may conflict with main. Send a message and the agent will bring it up to date."
      fi
    fi
  fi

  # 2. The owner's messages: the agent takes them into the plan, on the plan pull request
  if [ "$messages" -gt 0 ] || [ -n "$first" ]; then
    git fetch -q origin
    pr=$(gh pr list --head "$BRANCH" --base main --state open --json number --jq '.[0].number // ""')
    rm -rf "$RUN" && mkdir -p "$RUN"
    FORCE=""
    CONFLICTS=""
    if [ -n "$pr" ] && git rev-parse -q --verify "origin/$BRANCH" >/dev/null; then
      git checkout -q -B "$BRANCH" "origin/$BRANCH"
      # Up to date with main, where requests tick off tasks. Only plan files can conflict;
      # the agent resolves them by editing, and the commit below concludes the merge.
      if ! git merge-base --is-ancestor origin/main HEAD &&
         ! git merge -q --no-edit -m "Merge main into $BRANCH" origin/main >/dev/null 2>&1; then
        CONFLICTS=$(git diff --name-only --diff-filter=U)
        [ -n "$CONFLICTS" ] || fail "Could not merge main into $BRANCH"
        [ -z "$(outside_plan <<<"$CONFLICTS")" ] || fail "main conflicts with $BRANCH outside the plan; merge it by hand"
        { echo "main was merged into the plan branch, and these files hold conflict markers"
          echo "(<<<<<<< HEAD is the plan branch, >>>>>>> origin/main is main). Resolve them first:"
          echo; sed 's/^/- /' <<<"$CONFLICTS"; } > "$RUN/merge.md"
      fi
    else
      # A branch left behind by a closed pull request starts again from main
      pr=""
      git checkout -q -B "$BRANCH" origin/main
      FORCE=-f
    fi

    export USAGE_FILE="$RUN/usage.jsonl"
    git config user.name "Pipeline Agent"            # repo-local, not --global
    git config user.email "agent@users.noreply.github.com"
    cp -R "$TOOLS/agent/plan-templates" "$RUN/templates"
    gh issue view "$N" --json title,body > "$RUN/issue.json"
    conversation "$COMMENTS" "$handled" "${PIPELINE_OWNER:-}" > "$RUN/conversation.json"
    if [ -n "$pr" ]; then
      review_comment "$COMMENTS" | cut -f2- | jq -r . > "$RUN/review.md" 2>/dev/null || true
    fi
    jq -n --arg project "${GITHUB_REPOSITORY#*/}" --arg pr "$pr" \
      --argjson has_plan "$([ -f docs/Tasks/README.md ] && echo true || echo false)" \
      '{project: $project, has_plan: $has_plan, open_pull_request: (if $pr == "" then null else ($pr | tonumber) end)}' \
      > "$RUN/plan.json"

    # The agent gets no GitHub tokens
    run_step env -u GH_TOKEN -u GITHUB_TOKEN -u ATTACHMENTS_TOKEN "$ADAPTER" plan "$RUN"
    [ "$(jq -r .status "$RUN/result.json")" != failure ] || fail "Planning run failed"

    git add -A   # .agent/run is gitignored
    stray=$(git diff --cached --name-only origin/main | outside_plan)
    [ -z "$stray" ] || fail "The agent changed files outside the plan, so nothing was pushed: $(tr '\n' ' ' <<<"$stray")"
    if [ -n "$CONFLICTS" ] && grep -lE '^(<<<<<<<|>>>>>>>) ' $CONFLICTS 2>/dev/null; then
      fail "Conflict markers from merging main are still in the plan, so nothing was pushed"
    fi

    summary=""
    [ -s "$RUN/summary.md" ] && summary=$(cat "$RUN/summary.md")
    if merging || ! git diff --cached --quiet; then
      title=$(sed -n '/[^[:space:]]/{s/^[-*#[:space:]]*//;p;q;}' <<<"$summary")
      git commit -q -m "Plan: ${title:-update from the plan issue}"
    fi
    if [ -n "$(git log --oneline origin/main..HEAD)" ] &&
       [ "$(git rev-parse HEAD)" != "$(git rev-parse -q --verify "origin/$BRANCH" || true)" ]; then
      push
      { printf '%s\n\n' "${summary:-The agent did not write a summary.}"
        echo "From the plan issue #$N. Approve it in GoBuild's Plan screen; the pipeline merges it."
      } > "$RUN/pr-body.md"
      if [ -z "$pr" ]; then
        gh pr create --head "$BRANCH" --base main --title "Plan update" --body-file "$RUN/pr-body.md" >/dev/null
        pr=$(gh pr view "$BRANCH" --json number --jq .number)
      else
        gh pr edit "$pr" --body-file "$RUN/pr-body.md" >/dev/null
      fi
    fi
    if [ -n "$pr" ]; then
      [ -n "$summary" ] && set_review "$pr" "$summary"
      note="Plan changes waiting for your approval (#$pr)"
    fi

    # The agent's concerns, one comment each
    if [ -s "$RUN/concerns.json" ]; then
      if jq -e 'type == "array"' "$RUN/concerns.json" >/dev/null 2>&1; then
        jq -c '.[] | select(type == "string" and length > 0)' "$RUN/concerns.json" |
          while IFS= read -r one; do concern "$(jq -r . <<<"$one")"; done
      else
        echo "::warning::.agent/run/concerns.json is not a list; its concerns were not posted."
      fi
    fi
  fi

  HANDLED="$newest" status idle "$note"
}

# Sourced by a test, only the helpers above are wanted
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
