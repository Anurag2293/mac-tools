#!/bin/bash
# Subcommand dispatch, help text and usage errors of the `ferry` CLI.
source "$(dirname "$0")/lib.sh"

test_sandbox_resolves_inside_tmp() {
  # The probe in sandbox_new already refused anything else; show the resolved paths once more.
  local p
  p="$(sbx_env /bin/bash -c 'command -v adb launchctl osascript python3')"
  assert_contains "$p" "$BIN/adb" "adb is the fake"
  assert_contains "$p" "$BIN/launchctl" "launchctl is the fake"
  assert_not_contains "$p" "/opt/homebrew" "no homebrew on PATH"
  assert_eq "$HOMEDIR" "$(sbx_env printenv HOME)" "HOME"
}

test_help_variants_print_header_comment() {
  local a first
  for a in "" help -h --help; do
    if [[ -z "$a" ]]; then ferry; else ferry "$a"; fi
    assert_rc 0 "help [$a]"
    first="$(head -n 1 <<< "$OUT")"
    assert_eq "ferry: clipboard, files and screenshots between this Mac and the Pixel (Ferry Android app)." "$first" "help header [$a]"
    assert_contains "$OUT" "ferry shot              live screenshot of the phone" "help lists shot [$a]"
    assert_contains "$OUT" "ferry adb connect|pair" "help lists adb [$a]"
    assert_not_contains "$OUT" "set -euo pipefail" "help stops before code [$a]"
  done
  assert_eq "" "$(calls)" "help runs nothing external"
}

test_unknown_command_fails() {
  ferry frobnicate
  assert_rc 1 "unknown command"
  assert_eq "ferry: unknown command: frobnicate (try ferry help)" "$ERR" "message"
  ferry --version
  assert_rc 1 "--version is not a command"
}

test_app_usage() {
  ferry app
  assert_rc 1 "app without subcommand"
  assert_contains "$ERR" "usage: ferry app build|install" "app usage"
  ferry app frob
  assert_rc 1 "app bad subcommand"
}

test_logs_usage_and_targets() {
  ferry logs bogus
  assert_rc 1 "logs bogus"
  assert_contains "$ERR" "usage: ferry logs [hub|peek|app]" "logs usage"
  ferry logs
  assert_contains "$(calls)" "tail -n 30 -f $HOMEDIR/Library/Logs/ferry.log" "default log is the hub"
  ferry logs peek
  assert_contains "$(calls)" "tail -n 30 -f $HOMEDIR/Library/Logs/ferry-peek.log" "peek log"
}

test_logs_app_follows_logcat_of_the_phone() {
  printf 'List of devices attached\nPIXEL123\tdevice\n' > "$S/adb_devices"
  ferry logs app
  assert_rc 0 "logs app"
  assert_contains "$(calls)" "adb -s PIXEL123 logcat -v time Ferry:V ClipboardService:V AndroidRuntime:E *:S" "logcat filter"
}

test_adb_usage_and_missing_adb() {
  ferry adb bogus
  assert_rc 1 "adb bogus"
  assert_contains "$ERR" "usage: ferry adb connect|pair|tcpip|status" "adb usage"
  rm "$BIN/adb"
  ferry adb status
  assert_rc 1 "adb missing"
  assert_contains "$ERR" "adb not found" "adb missing message"
}

test_peek_without_file_fails() {
  ferry peek
  assert_rc 1 "peek without any screenshot"
  assert_contains "$ERR" "no file to preview" "message"
  ferry peek "$T/nonexistent.png"
  assert_rc 1 "peek with a missing file"
}

test_peek_builds_once_and_shows_file() {
  echo png > "$T/a.png"
  ferry peek "$T/a.png"
  assert_rc 0 "peek"
  assert_eq "1" "$(calls_matching '^swiftc ' | wc -l | tr -d ' ')" "built once"
  assert_contains "$(calls)" "peek --show $T/a.png" "peek --show FILE"
  ferry peek "$T/a.png"
  assert_eq "1" "$(calls_matching '^swiftc ' | wc -l | tr -d ' ')" "not rebuilt while the binary is newer"
  touch -t 203001010000 "$FDIR/peek/peek.swift"
  ferry peek "$T/a.png"
  assert_eq "2" "$(calls_matching '^swiftc ' | wc -l | tr -d ' ')" "rebuilt when the source is newer"
}

test_peek_defaults_to_newest_synced_screenshot() {
  echo a > "$SYNC/old.png"; touch -t 202601010000 "$SYNC/old.png"
  echo b > "$SYNC/new.png"; touch -t 202611010000 "$SYNC/new.png"
  ferry peek
  assert_rc 0 "peek default"
  assert_contains "$(calls)" "peek --show $SYNC/new.png" "newest file"
}

run_tests
