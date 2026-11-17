#!/bin/bash
# Compiles the pure-logic app classes (Frame, LogLine) with the tests and a stand-in org.json, then
# runs them on a plain JDK. Ends with a RESULT line for test.sh.
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../android/src/com/anurag/ferry"

if ! command -v javac > /dev/null || ! command -v java > /dev/null; then
  echo "no JDK on PATH: skipping Java tests" >&2
  echo "RESULT passed=0 failed=0 skipped=1"
  exit 0
fi

OUT="$(mktemp -d /tmp/ferry-java.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
find "$HERE/java" -name '*.java' > "$OUT/sources"
echo "$SRC/Frame.java" >> "$OUT/sources"
echo "$SRC/LogLine.java" >> "$OUT/sources"
javac -Xlint:-options --release 17 -d "$OUT/classes" @"$OUT/sources" >&2 || { echo "RESULT passed=0 failed=1 skipped=0"; exit 1; }
java -cp "$OUT/classes" com.anurag.ferry.Main
