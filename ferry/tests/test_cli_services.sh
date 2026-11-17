#!/bin/bash
# `ferry status`, `ferry setup`, `ferry uninstall`: launchd and corner-preview handling.
source "$(dirname "$0")/lib.sh"

count_calls() { calls_matching "$1" | wc -l | tr -d ' '; }
running_agent() { printf 'gui/501/%s = {\n\tstate = running\n\tpid = 42\n}\n' "$1" > "$S/launchctl_print_$1"; }
PEEK_PLIST_REL="Library/LaunchAgents/com.anurag.ferry-peek.plist"

# --- status --------------------------------------------------------------------------------------

test_status_everything_down() {
  ferry status
  assert_rc 0 "status"
  assert_contains "$OUT" "hub:             not installed" "hub"
  assert_contains "$OUT" "phone app:       hub not running (ferry setup)" "phone app"
  assert_contains "$OUT" "corner previews: not installed" "peek"
  assert_contains "$OUT" "screenshot sync: unknown (Syncthing -> $SYNC)" "sync"
  assert_contains "$OUT" "adb:             not connected (only needed for ferry app install)" "adb"
}

test_status_everything_up() {
  running_agent com.anurag.ferry
  running_agent com.anurag.ferry-peek
  start_ctl_hub real-connected || return
  start_syncthing '{"connected": true, "state": "idle", "needFiles": 0}'
  printf 'List of devices attached\nPIXEL123\tdevice\n' > "$S/adb_devices"
  ferry status
  assert_rc 0 "status"
  assert_contains "$OUT" "hub:             running" "hub"
  assert_contains "$OUT" "phone app:       connected Pixel 7 Pro" "phone app"
  assert_contains "$OUT" "corner previews: running" "peek"
  assert_contains "$OUT" "screenshot sync: synced" "sync"
  assert_contains "$OUT" "adb:             PIXEL123" "adb"
}

test_status_phone_disconnected() {
  start_ctl_hub real-disconnected || return
  ferry status
  assert_contains "$OUT" "phone app:       disconnected" "phone app"
}

test_status_agent_listed_without_state_line_counts_as_not_installed() {
  printf 'gui/501/com.anurag.ferry = {\n\tpid = 1\n}\n' > "$S/launchctl_print_com.anurag.ferry"
  ferry status
  assert_contains "$OUT" "hub:             not installed" "no state line"
}

test_status_reports_waiting_state() {
  printf 'x = {\n\tstate = spawn scheduled\n}\n' > "$S/launchctl_print_com.anurag.ferry"
  ferry status
  assert_contains "$OUT" "hub:             spawn" "first word of the state"
}

test_status_without_adb_binary_omits_adb_line() {
  rm "$BIN/adb"
  ferry status
  assert_rc 0 "status"
  assert_not_contains "$OUT" "adb:" "no adb line"
}

test_status_queries_only_the_two_agents() {
  ferry status
  local n
  n="$(calls_matching '^launchctl ' | sed 's/^launchctl print gui\/[0-9]*\///' | sort | tr '\n' ' ')"
  assert_eq "com.anurag.ferry com.anurag.ferry-peek " "$n" "launchctl print targets"
}

# --- setup ---------------------------------------------------------------------------------------

test_setup_installs_hub_builds_peek_and_loads_agent() {
  ferry setup
  assert_rc 0 "setup"
  assert_contains "$OUT" "hub: com.anurag.ferry (log $HOMEDIR/Library/Logs/ferry.log)" "hub line"
  assert_contains "$OUT" "corner previews: com.anurag.ferry-peek (log $HOMEDIR/Library/Logs/ferry-peek.log)" "peek line"
  assert_contains "$(calls)" "ferryd install" "hub install"
  assert_contains "$(calls)" "swiftc -O -o $FDIR/.build/ferry-peek $FDIR/peek/peek.swift -framework AppKit" "build command"
  local uid; uid="$(id -u)"
  assert_contains "$(calls)" "launchctl bootout gui/$uid/com.anurag.ferry-peek" "bootout first"
  assert_contains "$(calls)" "launchctl bootstrap gui/$uid $HOMEDIR/$PEEK_PLIST_REL" "bootstrap"
  assert_file "$HOMEDIR/.config/ferry" "config dir"
}

test_setup_plist_is_valid_and_points_at_the_built_binary() {
  ferry setup
  "$PYTHON" - "$HOMEDIR/$PEEK_PLIST_REL" "$FDIR/.build/ferry-peek" "$HOMEDIR" <<'PY' || fail "plist content"
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
assert p["Label"] == "com.anurag.ferry-peek", p
assert p["ProgramArguments"] == [sys.argv[2]], p
assert p["RunAtLoad"] is True and p["KeepAlive"] is True, p
assert p["LimitLoadToSessionType"] == "Aqua", p
assert p["StandardOutPath"] == p["StandardErrorPath"] == sys.argv[3] + "/Library/Logs/ferry-peek.log", p
PY
}

test_setup_does_not_rebuild_an_up_to_date_peek() {
  ferry setup
  ferry setup
  assert_rc 0 "second setup"
  assert_eq "1" "$(count_calls '^swiftc ')" "built once"
  assert_eq "2" "$(count_calls '^ferryd install')" "hub reinstalled each time"
}

test_setup_retries_bootstrap_until_it_works() {
  echo 3 > "$S/bootstrap_failures"
  ferry setup
  assert_rc 0 "setup"
  assert_eq "4" "$(count_calls '^launchctl bootstrap')" "three failures then success"
  assert_eq "3" "$(count_calls '^sleep 0.5')" "half-second pause per failure"
}

test_setup_gives_up_after_ten_bootstrap_failures() {
  echo 99 > "$S/bootstrap_failures"
  ferry setup
  assert_rc 1 "setup"
  assert_contains "$ERR" "launchctl bootstrap failed for com.anurag.ferry-peek" "message"
  assert_eq "10" "$(count_calls '^launchctl bootstrap')" "ten attempts"
}

test_setup_stops_when_peek_build_fails() {
  touch "$S/swiftc_fail"
  ferry setup
  assert_rc 1 "setup"
  assert_no_file "$HOMEDIR/$PEEK_PLIST_REL" "no plist after failed build"
  assert_eq "0" "$(count_calls '^launchctl bootstrap')" "nothing loaded"
}

test_setup_creates_missing_launchagents_dir() {
  rm -rf "$HOMEDIR/Library" "$HOMEDIR/.config"
  ferry setup
  assert_rc 0 "setup"
  assert_file "$HOMEDIR/$PEEK_PLIST_REL" "plist"
}

# --- uninstall -----------------------------------------------------------------------------------

test_uninstall_removes_plist_and_boots_out_peek() {
  ferry setup
  : > "$LOG"
  ferry uninstall
  assert_rc 0 "uninstall"
  assert_eq "removed com.anurag.ferry and com.anurag.ferry-peek" "$OUT" "message"
  assert_no_file "$HOMEDIR/$PEEK_PLIST_REL" "plist removed"
  assert_contains "$(calls)" "ferryd uninstall" "hub uninstalled"
  assert_contains "$(calls)" "launchctl bootout gui/$(id -u)/com.anurag.ferry-peek" "peek booted out"
}

test_uninstall_is_idempotent() {
  ferry uninstall
  assert_rc 0 "uninstall without anything installed"
}

run_tests
