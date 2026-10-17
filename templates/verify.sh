#!/usr/bin/env bash
# Builds the app and runs its tests on the simulator. The pipeline runs it with no arguments to
# verify a change; its agent runs it with test names to check its work as it goes.
#
# Usage: scripts/verify.sh [test ...]
#   With no names, every test. Each name is one of:
#       <unit target>                         all unit tests
#       <unit target>/<Suite>                 one unit-test suite
#       <UI target>                           all UI tests
#       <UI target>/<Class>                   one UI-test class
#       <UI target>/<Class>/<testMethod>      one UI test
#   The targets are unit_tests and ui_tests in .agent/project.json. Anything else is refused,
#   because the agent may pass arguments and nothing but test names may reach xcodebuild.
# VERIFY_UNIT_ONLY=1 with no names runs only the unit tests.
# VERIFY_DESTINATION overrides the simulator (default iPhone 17, iOS 26.5).
set -euo pipefail

usage() {
  sed -n '5,13p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

CONFIG=.agent/project.json
setting() { jq -r --arg key "$1" '.[$key] // ""' "$CONFIG"; }
PROJECT=$(setting xcodeproj); SCHEME=$(setting scheme)
UNIT=$(setting unit_tests); UI=$(setting ui_tests)
NAME='[A-Za-z0-9_]+'
for target in "$UNIT" "$UI"; do
  [ -z "$target" ] || [[ $target =~ ^$NAME$ ]] || { echo "$CONFIG: \"$target\" is not a test target name" >&2; exit 2; }
done

DESTINATION=${VERIFY_DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=26.5}

# Parallel testing is off so xcodebuild doesn't clone simulators
XCODEBUILD=(xcodebuild test -project "$PROJECT" -scheme "$SCHEME"
  -destination "$DESTINATION" -parallel-testing-enabled NO -quiet)

for test in "$@"; do
  if [ -n "$UNIT" ] && [[ $test =~ ^$UNIT(/$NAME)?$ ]]; then
    :
  elif [ -n "$UI" ] && [[ $test =~ ^$UI(/$NAME(/$NAME)?)?$ ]]; then
    :
  else
    echo "Not a test this script can run: $test" >&2
    usage
  fi
  XCODEBUILD+=("-only-testing:$test")
done

if [ $# -eq 0 ] && [ -n "${VERIFY_UNIT_ONLY:-}" ] && [ -n "$UI" ]; then
  XCODEBUILD+=("-skip-testing:$UI")
fi

exec "${XCODEBUILD[@]}"
