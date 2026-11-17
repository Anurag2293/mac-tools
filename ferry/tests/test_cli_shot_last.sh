#!/bin/bash
# `ferry shot` and `ferry last`: hub control socket, adb fallback, synced folder handling.
source "$(dirname "$0")/lib.sh"

make_png() { printf '\211PNG\r\n\032\nFERRYTESTDATA' > "$1"; }
one_device() { printf 'List of devices attached\nPIXEL123\tdevice\n' > "$S/adb_devices"; }
count_calls() { calls_matching "$1" | wc -l | tr -d ' '; }

# --- shot ----------------------------------------------------------------------------------------

test_shot_via_hub_saves_prints_and_copies() {
  make_png "$T/ref.png"
  start_ctl_hub real-ok "$T/ref.png" || return
  ferry shot
  assert_rc 0 "shot"
  [[ "$OUT" == "$SHOTS"/live_*.png ]] || fail "printed path [$OUT] is not under the shots dir"
  assert_eq "$(cat "$T/ref.png")" "$(cat "$OUT")" "png bytes"
  assert_eq "" "$ERR" "no warnings"
  assert_contains "$(calls)" "set the clipboard to (read (POSIX file \"$OUT\") as «class PNGf»)" "clipboard set"
  assert_eq "0" "$(count_calls '^adb ')" "adb untouched"
}

test_shot_creates_shots_dir() {
  make_png "$T/ref.png"
  start_ctl_hub real-ok "$T/ref.png" || return
  rmdir "$SHOTS"
  ferry shot
  assert_rc 0 "shot"
  assert_file "$OUT" "png written into a fresh dir"
}

test_shot_falls_back_to_adb_when_app_not_connected() {
  start_ctl_hub real-err || return
  one_device
  printf 'ADBPNG' > "$S/screencap"
  ferry shot
  assert_rc 0 "shot"
  assert_contains "$ERR" "ferry: app capture failed (phone app not connected); trying adb" "fallback notice"
  assert_eq "ADBPNG" "$(cat "$OUT")" "screencap bytes"
  assert_contains "$(calls)" "adb -s PIXEL123 exec-out screencap -p" "screencap call"
  assert_eq "1" "$(ls "$SHOTS" | wc -l | tr -d ' ')" "one file left"
}

test_shot_hub_not_running_falls_back() {
  one_device
  printf 'ADBPNG' > "$S/screencap"
  ferry shot
  assert_rc 0 "shot"
  assert_contains "$ERR" "hub not running (ferry setup)" "reason shown"
  assert_eq "ADBPNG" "$(cat "$OUT")" "screencap bytes"
}

test_shot_fails_without_phone_and_leaves_nothing() {
  ferry shot
  assert_rc 1 "shot"
  assert_contains "$ERR" "phone not reachable over adb" "message"
  assert_eq "0" "$(ls "$SHOTS" | wc -l | tr -d ' ')" "no stray file"
}

test_shot_empty_screencap_is_an_error() {
  one_device
  ferry shot
  assert_rc 1 "shot"
  assert_contains "$ERR" "screencap returned no data" "message"
  assert_eq "0" "$(ls "$SHOTS" | wc -l | tr -d ' ')" "empty file removed"
}

test_shot_uses_hub_adb_connect_when_no_device_listed() {
  printf '192.168.1.5:41234\n' > "$S/hub_serial"
  printf 'ADBPNG' > "$S/screencap"
  ferry shot
  assert_rc 0 "shot"
  assert_contains "$(calls)" "ferryd adb-connect" "hub asked to find the phone"
  assert_contains "$(calls)" "adb -s 192.168.1.5:41234 exec-out screencap -p" "serial from hub used"
}

test_shot_ignores_offline_and_unauthorized_devices() {
  printf 'List of devices attached\nAAA\toffline\nBBB\tunauthorized\nCCC\tdevice\nDDD\tdevice\n' > "$S/adb_devices"
  printf 'ADBPNG' > "$S/screencap"
  ferry shot
  assert_rc 0 "shot"
  assert_contains "$(calls)" "adb -s CCC exec-out screencap -p" "first usable device"
}

test_shot_hub_garbage_reply_falls_back() {
  start_ctl_hub garbage || return
  one_device
  printf 'ADBPNG' > "$S/screencap"
  ferry shot
  assert_rc 0 "shot"
  assert_contains "$ERR" "app capture failed (bogus)" "garbage reported"
}

test_shot_hub_reply_without_size_falls_back() {
  start_ctl_hub ok-no-size || return
  one_device
  printf 'ADBPNG' > "$S/screencap"
  ferry shot
  assert_rc 0 "shot"
  assert_contains "$ERR" "app capture failed" "failure reported"
  assert_eq "ADBPNG" "$(cat "$OUT")" "adb used"
}

test_shot_hub_empty_reply_falls_back() {
  start_ctl_hub empty-reply || return
  one_device
  printf 'ADBPNG' > "$S/screencap"
  ferry shot
  assert_rc 0 "shot"
  assert_eq "ADBPNG" "$(cat "$OUT")" "adb used"
}

test_shot_truncated_hub_data_is_not_accepted() {
  start_ctl_hub truncated || return
  one_device
  printf 'ADBPNG' > "$S/screencap"
  ferry shot
  assert_rc 0 "shot"
  assert_eq "ADBPNG" "$(cat "$OUT")" "a short read must fall back instead of keeping a corrupt PNG"
}

# --- clipboard class and quoting -----------------------------------------------------------------

test_last_copies_jpeg_with_jpeg_class() {
  echo a > "$SYNC/shot.jpg"
  ferry last
  assert_contains "$(calls)" "as JPEG picture)" "jpg uses the JPEG class"
  rm "$SYNC/shot.jpg"; echo a > "$SYNC/shot.jpeg"
  : > "$LOG"
  ferry last
  assert_contains "$(calls)" "as JPEG picture)" "jpeg uses the JPEG class"
}

test_last_copies_png_and_webp_with_png_class() {
  echo a > "$SYNC/shot.webp"
  ferry last
  assert_contains "$(calls)" "as «class PNGf»)" "webp falls to the PNG class"
}

test_clipboard_script_survives_quotes_in_file_names() {
  echo a > "$SYNC/a\"b.png"
  ferry last
  assert_rc 0 "last"
  assert_contains "$(calls)" "POSIX file \"$SYNC/a\\\"b.png\"" "double quote escaped in the AppleScript string"
}

test_clipboard_script_survives_backslashes_in_file_names() {
  echo a > "$SYNC/a\\b.png"
  ferry last
  assert_contains "$(calls)" "POSIX file \"$SYNC/a\\\\b.png\"" "backslash escaped in the AppleScript string"
}

# --- last: argument validation -------------------------------------------------------------------

test_last_rejects_bad_counts() {
  local n
  echo a > "$SYNC/a.png"
  for n in 0 -1 abc 1.5 1e2 "1 2"; do
    ferry last "$n"
    assert_rc 1 "last [$n]"
    assert_contains "$ERR" "N must be a positive number" "message for [$n]"
  done
}

test_last_ignores_extra_arguments() {
  echo a > "$SYNC/a.png"
  ferry last 1 extra
  assert_rc 0 "last 1 extra"
}

# --- last: synced folder -------------------------------------------------------------------------

test_last_lists_newest_first_and_honors_n() {
  local i
  for i in 1 2 3 4; do echo x > "$SYNC/s$i.png"; touch -t 20261101000$i "$SYNC/s$i.png"; done
  ferry last
  assert_eq "$SYNC/s4.png" "$OUT" "default is the newest one"
  ferry last 3
  assert_eq "$SYNC/s4.png
$SYNC/s3.png
$SYNC/s2.png" "$OUT" "three newest in order"
  ferry last 99
  assert_eq "4" "$(wc -l <<< "$OUT" | tr -d ' ')" "all four when N is larger"
}

test_last_filters_non_images_hidden_files_and_directories() {
  echo x > "$SYNC/a.png"; touch -t 202611010001 "$SYNC/a.png"
  echo x > "$SYNC/b.JPG"; touch -t 202611010002 "$SYNC/b.JPG"
  echo x > "$SYNC/c.webp"; touch -t 202611010003 "$SYNC/c.webp"
  echo x > "$SYNC/notes.txt"; touch -t 202611010009 "$SYNC/notes.txt"
  echo x > "$SYNC/.hidden.png"; touch -t 202611010009 "$SYNC/.hidden.png"
  echo x > "$SYNC/shot.heic"; touch -t 202611010009 "$SYNC/shot.heic"
  mkdir "$SYNC/dir.png"; touch -t 202611010009 "$SYNC/dir.png"
  mkdir "$SYNC/sub"; echo x > "$SYNC/sub/deep.png"
  ferry last 10
  assert_eq "$SYNC/c.webp
$SYNC/b.JPG
$SYNC/a.png" "$OUT" "only png/jpg/jpeg/webp files in the top folder"
}

test_last_handles_spaces_in_file_names() {
  echo x > "$SYNC/Screenshot 2026-11-18 at 1.png"
  ferry last
  assert_eq "$SYNC/Screenshot 2026-11-18 at 1.png" "$OUT" "name with spaces"
  assert_contains "$(calls)" "POSIX file \"$SYNC/Screenshot 2026-11-18 at 1.png\"" "clipboard uses the full name"
}

test_last_copies_the_newest_to_the_clipboard() {
  echo x > "$SYNC/old.png"; touch -t 202601010000 "$SYNC/old.png"
  echo x > "$SYNC/new.png"; touch -t 202611010000 "$SYNC/new.png"
  ferry last 2
  assert_eq "1" "$(count_calls '^osascript ')" "one clipboard call"
  assert_contains "$(calls)" "POSIX file \"$SYNC/new.png\"" "the newest"
}

test_last_warns_when_syncthing_is_unreachable() {
  echo x > "$SYNC/a.png"
  ferry last
  assert_eq "$SYNC/a.png" "$OUT" "still lists"
  assert_contains "$ERR" "Syncthing not reachable" "unknown state warning"
  assert_eq "0" "$(count_calls '^sleep ')" "does not wait when unknown"
}

test_last_synced_state_is_silent() {
  start_syncthing '{"connected": true, "state": "idle", "needFiles": 0}'
  echo x > "$SYNC/a.png"
  ferry last
  assert_rc 0 "last"
  assert_eq "" "$ERR" "no warning when synced"
}

test_last_offline_state_warns() {
  start_syncthing '{"connected": false, "state": "idle", "needFiles": 0}'
  echo x > "$SYNC/a.png"
  ferry last
  assert_contains "$ERR" "phone not connected to Syncthing" "offline warning"
  assert_eq "$SYNC/a.png" "$OUT" "lists what is there"
}

test_last_waits_while_syncing_then_gives_up() {
  start_syncthing '{"connected": true, "state": "scanning", "needFiles": 3}'
  echo x > "$SYNC/a.png"
  ferry last
  assert_contains "$ERR" "still syncing" "syncing warning"
  assert_eq "20" "$(count_calls '^sleep 0.5')" "polls 20 times"
}

test_last_stops_waiting_as_soon_as_synced() {
  start_syncthing '{"connected": true, "state": "scanning", "needFiles": 3}'
  printf '#!/bin/bash\nn=$(cat "$FERRY_TEST_STATE/n" 2>/dev/null || echo 0); echo $((n+1)) > "$FERRY_TEST_STATE/n"\n[ $((n+1)) -ge 3 ] && echo "{\\"connected\\": true, \\"state\\": \\"idle\\", \\"needFiles\\": 0}" > "$FERRY_TEST_STATE/syncthing_state.json"\n' > "$S/on_sleep"
  chmod +x "$S/on_sleep"
  echo x > "$SYNC/a.png"
  ferry last
  assert_eq "" "$ERR" "no warning once synced"
  assert_eq "3" "$(count_calls '^sleep 0.5')" "waited three rounds"
}

test_last_syncthing_rejects_wrong_api_key() {
  start_syncthing '{"connected": true, "state": "idle", "needFiles": 0}'
  sed -i '' 's/KEY123/WRONG/' "$HOMEDIR/Library/Application Support/Syncthing/config.xml"
  echo x > "$SYNC/a.png"
  ferry last
  assert_contains "$ERR" "Syncthing not reachable" "403 becomes unknown"
}

# --- last: adb fallback --------------------------------------------------------------------------

phone_shots() {  # dir name...
  local d="$1" f i=0; shift
  mkdir -p "$S/sdcard$d"
  for f in "$@"; do
    i=$((i + 1)); echo "data-$f" > "$S/sdcard$d/$f"; touch -t 20261101000$i "$S/sdcard$d/$f"
  done
}

test_last_pulls_from_phone_when_no_synced_files() {
  one_device
  phone_shots /Pictures/Screenshots a.png b.png c.png
  ferry last 2
  assert_rc 0 "last"
  assert_eq "$SHOTS/c.png
$SHOTS/b.png" "$OUT" "newest two, newest first"
  assert_eq "data-c.png" "$(cat "$SHOTS/c.png")" "pulled content"
  assert_not_contains "$(calls)" "a.png" "older one not pulled"
  assert_contains "$(calls)" "POSIX file \"$SHOTS/c.png\"" "newest copied"
}

test_last_does_not_repull_existing_files() {
  one_device
  phone_shots /Pictures/Screenshots a.png
  echo cached > "$SHOTS/a.png"
  ferry last
  assert_eq "cached" "$(cat "$SHOTS/a.png")" "kept"
  assert_eq "0" "$(count_calls '^adb .*pull')" "no pull"
}

test_last_falls_back_to_dcim_directory() {
  one_device
  phone_shots /DCIM/Screenshots z.png
  ferry last
  assert_eq "$SHOTS/z.png" "$OUT" "found in DCIM"
}

test_last_fails_when_phone_has_no_screenshots() {
  one_device
  ferry last
  assert_rc 1 "last"
  assert_contains "$ERR" "no screenshots found on the phone" "message"
}

test_last_fails_without_phone_or_synced_files() {
  ferry last
  assert_rc 1 "last"
  assert_contains "$ERR" "phone not reachable over adb" "message"
}

run_tests
