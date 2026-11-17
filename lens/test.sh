#!/bin/bash
# Runs the lens test suite: the Swift tests for Core.swift and the tests for the bash wrapper.
# Nothing here captures the screen, posts events, starts the app or touches the installed agent.
set -uo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
OUT="$DIR/.build/tests"
BIN="$OUT/lens-tests"
mkdir -p "$OUT"

status=0

if [[ ! -x "$BIN" || -n "$(find "$DIR/Core.swift" "$DIR"/tests/*.swift -newer "$BIN")" ]]; then
  echo "building tests"
  swiftc -O -swift-version 5 -o "$BIN" "$DIR/Core.swift" "$DIR"/tests/*.swift || { echo "test build failed"; exit 1; }
fi

"$BIN" || status=1
"$DIR/tests/wrapper.sh" || status=1

if [[ $status -eq 0 ]]; then echo "lens tests: OK"; else echo "lens tests: FAILED"; fi
exit $status
