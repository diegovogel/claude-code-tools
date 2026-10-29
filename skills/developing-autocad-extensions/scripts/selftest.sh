#!/usr/bin/env bash
# Checks that run-core-console.sh tells a passing run from failing ones.
# Run it after changing the runner. Needs AutoCAD 2026; takes about 10 seconds.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
fails=0

# check <name> <expected runner exit code> <steps lines...>
check() {
  local name=$1 want=$2
  shift 2
  printf '%s\n' "$@" > "$dir/$name.steps"
  bash "$here/run-core-console.sh" "$dir/$name.steps" > "$dir/$name.log" 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "ok     $name (exit $got)"
  else
    echo "WRONG  $name: exit $got, wanted $want"
    sed -n '/^----$/,$p' "$dir/$name.log"
    fails=$((fails + 1))
  fi
}

check pass 0 '(princ (strcat "\nGOT-" "ONE"))(princ)' ';EXPECT GOT-ONE'
check missing-expectation 1 '(princ (strcat "\nGOT-" "ONE"))(princ)' ';EXPECT GOT-TWO'
check unknown-command 1 'NOSUCHCOMMAND'
check lisp-error 1 '(car 1)'
exit $fails
