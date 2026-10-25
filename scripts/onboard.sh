#!/usr/bin/env bash
# Sets a repo of the organization up for this pipeline: the labels, Actions and merge settings,
# the release environment and the owner variable. Then checks the secrets and the project's files
# and lists what is still missing. Safe to run again; it changes only what differs.
#
# Usage: scripts/onboard.sh <owner/repo> [checkout]
#   checkout: a local clone of the repo. Templates are copied into it for the files it lacks,
#             to be edited and committed in a pull request.
# Optional env: PIPELINE_OWNER (default: the account gh is signed in as)
#
# What only a person can do, and this script only checks: the App Store Connect app record, the
# match profile in ios-certs, the release secrets, and adding the repo to the app's GitHub token.
set -euo pipefail
REPO=${1:?"Usage: scripts/onboard.sh <owner/repo> [checkout]"}
CHECKOUT=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
TEMPLATES="$HERE/../templates"
OWNER=${PIPELINE_OWNER:-$(gh api user --jq .login)}

bold=$'\033[1m'; green=$'\033[32m'; yellow=$'\033[33m'; off=$'\033[0m'
done_() { printf '%s✓%s %s\n' "$green" "$off" "$*"; }
LEFT=()
left() { LEFT+=("$*"); }

gh repo view "$REPO" --json name >/dev/null || { echo "Can't reach $REPO with gh." >&2; exit 1; }
echo "${bold}Setting up $REPO for the pipeline${off}"

# 1. Labels: the request labels GoBuild and the workflows add, and the ai:* states status.sh moves
while IFS='|' read -r name color description; do
  gh label create "$name" -R "$REPO" --color "$color" --description "$description" --force >/dev/null
done <<'EOF'
ai-request|BFD4F2|A request for the pipeline's agent
ai-approved|C2E0C6|Starts the agent on a request filed by someone else
ai-skip-review|FEF2C0|The agent's pull request skips the AI review
ai-skip-ui-tests|FEF2C0|The agent adds no UI tests and verifies with the unit tests only
ai-archived|ededed|Archived in GoBuild; the pipeline ignores it
ai-mockup|0E8A16|Not used yet
ai-plan|D4C5F9|The project's plan, talked over with the agent in GoBuild's Plan screen
ai:queued|5319E7|Pipeline: waiting for the runner
ai:running|BFD4F2|Pipeline: the agent is working on it
ai:needs-input|0052CC|Pipeline: the agent has a question
ai:in-review|FBCA04|Pipeline: the pull request is ready for review
ai:building|D93F0B|Pipeline: merged, and building for TestFlight
ai:released|0052CC|Pipeline: on TestFlight
ai:failed|1D76DB|Pipeline: the run stopped with an error
ai:cancelled|cccccc|Pipeline: cancelled by the owner
ai:idle|ededed|Pipeline: the plan's agent is waiting for the owner
EOF
# The models a request can ask for, one ai-model:<id> label per entry in agent/models.json
jq -r '.models[] | "ai-model:\(.id)|C5DEF5|The agent runs with \(.name)"' "$HERE/../agent/models.json" |
while IFS='|' read -r name color description; do
  gh label create "$name" -R "$REPO" --color "$color" --description "$description" --force >/dev/null
done
done_ "Labels"

# 2. Actions: the workflow token is read-only unless a workflow asks for more, and may open pull requests
gh api -X PUT "repos/$REPO/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true >/dev/null
done_ "Actions permissions"

# 3. Merges: squash only, with the pull request's title and body as the message (the release job
#    reads "Closes #N" from it), and merged branches deleted
gh api -X PATCH "repos/$REPO" -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY >/dev/null
done_ "Squash merges only"

# 4. The release environment, which holds the signing secrets, limited to main
gh api -X PUT "repos/$REPO/environments/release" \
  -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true' >/dev/null
if ! gh api "repos/$REPO/environments/release/deployment-branch-policies" --jq '.branch_policies[].name' | grep -qx main; then
  gh api -X POST "repos/$REPO/environments/release/deployment-branch-policies" -f name=main -f type=branch >/dev/null
fi
done_ "The release environment, limited to main"

# 5. Whose labels and comments start the agent. On the repo, not the organization: on GitHub Free,
#    organization variables and secrets don't reach private repos' workflows.
gh variable set PIPELINE_OWNER -R "$REPO" --body "$OWNER"
done_ "PIPELINE_OWNER is $OWNER"

# 6. Secrets: only their names can be read
secrets=$(gh secret list -R "$REPO" --json name --jq '.[].name')
grep -qx ATTACHMENTS_TOKEN <<<"$secrets" ||
  left "Set the ATTACHMENTS_TOKEN secret: gh secret set ATTACHMENTS_TOKEN -R $REPO"
release=$(gh secret list -R "$REPO" --env release --json name --jq '.[].name')
for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_CONTENT MATCH_PASSWORD MATCH_GIT_BASIC_AUTHORIZATION; do
  grep -qx "$name" <<<"$release" || left "Set the release secret $name: gh secret set $name -R $REPO --env release"
done

# 7. The project's files, on its default branch; copied from the templates into a checkout if given
copy() {   # <template> <path in the repo>
  if [ -n "$CHECKOUT" ] && [ ! -e "$CHECKOUT/$2" ]; then
    mkdir -p "$(dirname "$CHECKOUT/$2")" && cp "$TEMPLATES/$1" "$CHECKOUT/$2"
    left "Edit and commit $2 (copied from templates/$1)"
  else
    left "Add $2 (see templates/$1)"
  fi
}
has() { gh api "repos/$REPO/contents/$1" --jq .name >/dev/null 2>&1 || { [ -n "$CHECKOUT" ] && [ -e "$CHECKOUT/$1" ]; }; }
# A workflow is the pipeline's when it calls the reusable one here; an app's own older one is replaced
calls_pipeline() {
  { gh api "repos/$REPO/contents/$1" --jq .content 2>/dev/null | base64 -d 2>/dev/null
    [ -n "$CHECKOUT" ] && [ -e "$CHECKOUT/$1" ] && cat "$CHECKOUT/$1"; } | grep -q 'uses: GoApps213/pipeline/'
}
for workflow in agent housekeeping release; do
  path=".github/workflows/$workflow.yml"
  if ! has "$path"; then
    copy "workflows/$workflow.yml" "$path"
  elif ! calls_pipeline "$path"; then
    left "Replace $path with templates/workflows/$workflow.yml: it doesn't call the pipeline"
  fi
done
has .agent/project.json || copy project.json .agent/project.json
has scripts/verify.sh || copy verify.sh scripts/verify.sh
has CLAUDE.md || left "Write CLAUDE.md: the app's layout, conventions, and its test targets with example test names"
if ! gh api "repos/$REPO/contents/.gitignore" --jq .content 2>/dev/null | base64 -d 2>/dev/null | grep -q '^\.agent/run/'; then
  left "Add .agent/run/ and .build-number to .gitignore"
fi

echo
if [ "${#LEFT[@]}" -eq 0 ]; then
  echo "${green}${bold}$REPO is set up.${off} Add it to the app's GitHub token so GoBuild lists it."
else
  echo "${yellow}${bold}Still to do:${off}"
  printf '  - %s\n' "${LEFT[@]}"
  echo "  - Add $REPO to the app's GitHub token (Issues read/write, Pull requests read, Administration read)"
fi
