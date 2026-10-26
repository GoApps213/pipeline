#!/usr/bin/env bash
# Chooses which AI model the pipeline's agent runs with. The choice is kept on this
# Mac, outside the repo, and every agent run that starts afterwards uses it.
# Usage: model.sh             # show the current model and pick from a menu
#        model.sh <id>        # set it without the menu
#        model.sh --show      # print the current model's name
#        model.sh --resolve   # print the current entry as JSON; agent-run.sh reads this
#        model.sh --resolve-id <id>  # print that entry as JSON, or fail if it isn't in the list;
#                                    # agent-run.sh and plan-run.sh read this for an issue's ai-model:<id> label
# Optional env: MODELS_FILE (default agent/models.json in this repo),
#               PIPELINE_MODEL_FILE (default ~/.config/agent-pipeline/model).
# A choice made before the pipeline had its own repo, in ~/.config/gotask-pipeline/model,
# is used until a new one is made.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MODELS_FILE=${MODELS_FILE:-$HERE/../agent/models.json}
CHOICE_FILE=${PIPELINE_MODEL_FILE:-$HOME/.config/agent-pipeline/model}
OLD_CHOICE_FILE=$HOME/.config/gotask-pipeline/model

# The adapter name becomes a script path in agent-run.sh, so its characters are checked here
if ! jq -e '(.models | type == "array" and length > 0)
            and all(.models[]; (.id | type == "string" and test("^[a-z0-9.-]+$"))
                               and (.name | type == "string" and length > 0)
                               and (.adapter | type == "string" and test("^[a-z0-9-]+$"))
                               and (.model | type == "string"))
            and (.default as $d | any(.models[]; .id == $d))' "$MODELS_FILE" >/dev/null 2>&1; then
  echo "$MODELS_FILE is missing or not a valid model list." >&2
  exit 1
fi

entry() { jq -ce --arg id "$1" 'first(.models[] | select(.id == $id))' "$MODELS_FILE"; }

# The saved id, or the list's default when nothing has been chosen
current_id() {
  local id=""
  if [ -f "$CHOICE_FILE" ]; then id=$(head -1 "$CHOICE_FILE" | tr -d '[:space:]')
  elif [ -z "${PIPELINE_MODEL_FILE:-}" ] && [ -f "$OLD_CHOICE_FILE" ]; then
    id=$(head -1 "$OLD_CHOICE_FILE" | tr -d '[:space:]')
  fi
  if [ -n "$id" ]; then echo "$id"; else jq -r .default "$MODELS_FILE"; fi
}

current_entry() {
  local id; id=$(current_id)
  entry "$id" || { echo "The chosen model \"$id\" is not in $MODELS_FILE." >&2; return 1; }
}

save() {
  local chosen
  chosen=$(entry "$1") || { echo "\"$1\" is not in the model list. Nothing was changed." >&2; exit 1; }
  mkdir -p "$(dirname "$CHOICE_FILE")"
  printf '%s\n' "$1" > "$CHOICE_FILE"
  echo "The pipeline now uses $(jq -r .name <<<"$chosen"). Runs already under way keep their model."
}

case "${1:-}" in
  --resolve) current_entry ;;
  --show)    current_entry | jq -r .name ;;
  --resolve-id) entry "${2:?"Usage: model.sh --resolve-id <id>"}" ;;
  -*)        sed -n '2,13s/^# \{0,1\}//p' "$0"; exit 2 ;;
  "")
    CURRENT=$(current_id)
    COUNT=$(jq '.models | length' "$MODELS_FILE")
    entry "$CURRENT" >/dev/null || echo "The saved model \"$CURRENT\" is no longer in the list; choose another."
    jq -r --arg c "$CURRENT" '.models | to_entries[]
      | "\(if .value.id == $c then "*" else " " end) \(.key + 1). \(.value.name)  [\(.value.id)]"' "$MODELS_FILE"
    read -r -p "Number (Enter leaves it as it is): " pick || { echo; exit 0; }
    [ -n "$pick" ] || exit 0
    if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "$COUNT" ]; then
      echo "\"$pick\" is not a number from 1 to $COUNT. Nothing was changed." >&2
      exit 1
    fi
    save "$(jq -r --argjson i "$pick" '.models[$i - 1].id' "$MODELS_FILE")" ;;
  *) save "$1" ;;
esac
