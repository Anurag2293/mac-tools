#!/bin/bash
# Runs every ferry test group against fakes and a temporary HOME; never touches the real hub, launchd,
# adb, the phone or ~/.config/ferry. Exits non-zero if any group fails.
HERE="$(cd "$(dirname "$0")" && pwd)"
TESTS="$HERE/tests"
PY="${FERRY_TEST_PYTHON:-$(command -v python3)}"

names=()
passed=()
failed=()
skipped=()
codes=()

run_group() {  # NAME CMD...
  local name="$1" out
  shift
  echo "== $name"
  out="$(mktemp /tmp/ferry-group.XXXXXX)"
  "$@" 2>&1 | tee "$out"
  local rc="${PIPESTATUS[0]}" line
  line="$(grep '^RESULT ' "$out" | tail -n 1)"
  rm -f "$out"
  local p=0 f=0 s=0
  if [[ -n "$line" ]]; then
    p="$(sed -E 's/.*passed=([0-9]+).*/\1/' <<< "$line")"
    f="$(sed -E 's/.*failed=([0-9]+).*/\1/' <<< "$line")"
    s="$(sed -E 's/.*skipped=([0-9]+).*/\1/' <<< "$line")"
  fi
  if [[ "$rc" -ne 0 && "$f" -eq 0 ]]; then f=1; fi
  names+=("$name"); passed+=("$p"); failed+=("$f"); skipped+=("$s"); codes+=("$rc")
}

for t in "$TESTS"/test_cli_*.sh; do
  run_group "cli/$(basename "$t" .sh | sed 's/^test_cli_//')" /bin/bash "$t"
done
run_group "hub" "$PY" "$TESTS/run_py.py"
run_group "java" /bin/bash "$TESTS/run_java.sh"

echo
printf '%-22s %7s %7s %7s\n' group passed failed skipped
tp=0; tf=0; ts=0
for i in "${!names[@]}"; do
  printf '%-22s %7s %7s %7s\n' "${names[$i]}" "${passed[$i]}" "${failed[$i]}" "${skipped[$i]}"
  tp=$((tp + passed[i])); tf=$((tf + failed[i])); ts=$((ts + skipped[i]))
done
printf '%-22s %7s %7s %7s\n' total "$tp" "$tf" "$ts"
echo "not covered: peek/peek.swift (AppKit views), Android classes that need the Android SDK, the phone and the real hub"

[[ "$tf" -eq 0 ]]
