#!/usr/bin/env bash
# Ticket images live in a separate private repo, because GitHub's API can't attach
# images to issues.
# Usage: attachments.sh download <issue.json> <dir>
#        attachments.sh upload <file> <path-in-repo>   # prints the file's URL
# Env: ATTACHMENTS_TOKEN; optional ATTACHMENTS_REPO (default: <app repo>-attachments)
set -euo pipefail
ATTACH_REPO=${ATTACHMENTS_REPO:-$GITHUB_REPOSITORY-attachments}
export GH_TOKEN="$ATTACHMENTS_TOKEN"
unset GH_REPO

case "$1" in
  download)
    mkdir -p "$3"
    # Any owner: tickets filed before the repos moved to the organization link to the old one
    { jq -r '.body // "", (.comments[]?.body // "")' "$2" \
        | grep -oE "github.com/[^/]+/${ATTACH_REPO#*/}/blob/main/[^) ?]+" || true; } \
      | sed 's#.*/blob/main/##' | sort -u \
      | while read -r p; do
          gh api "repos/$ATTACH_REPO/contents/$p" \
            -H "Accept: application/vnd.github.raw" > "$3/$(basename "$p")"
          echo "Downloaded $(basename "$p")"
        done ;;
  upload)
    gh api -X PUT "repos/$ATTACH_REPO/contents/$3" \
      -f message="Add $3" -f content="$(base64 -i "$2")" --jq .content.html_url ;;
  *)
    echo "Usage: attachments.sh download <issue.json> <dir> | upload <file> <path-in-repo>" >&2; exit 2 ;;
esac
