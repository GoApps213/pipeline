#!/usr/bin/env bash
# Retrying for calls to GitHub, which now and then answers a good request with a 502.
# Sourced by the scripts that need it.
#
# Use it only for a call that is safe to make twice: a failed attempt may still have
# gone through.
#
# Optional env: RETRY_ATTEMPTS (4), RETRY_DELAY (5): seconds before the second attempt,
#               doubled before each one after.

# Runs a command until it succeeds, RETRY_ATTEMPTS times at most. Returns the last
# attempt's exit code.
retry() {
  local attempt=1 delay=${RETRY_DELAY:-5} rc
  while true; do
    rc=0
    "$@" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$attempt" -ge "${RETRY_ATTEMPTS:-4}" ] && return "$rc"
    echo "Attempt $attempt of '$1 ${2:-} ${3:-}' failed; trying again in $delay seconds." >&2
    sleep "$delay"
    attempt=$((attempt + 1)); delay=$((delay * 2))
  done
}
