#!/bin/bash
# `ferry app build` and `ferry app install` against fake Android build tools and a fake adb.
source "$(dirname "$0")/lib.sh"

count_calls() { calls_matching "$1" | wc -l | tr -d ' '; }
one_device() { printf 'List of devices attached\nPIXEL123\tdevice\n' > "$S/adb_devices"; }
tailnet() { printf 'lo0: flags=8049<UP>\n\tinet 127.0.0.1 netmask 0xff000000\nutun4: flags=8051<UP>\n\tinet %s --> %s netmask 0xffffffff\n' "$1" "$1" > "$S/ifconfig"; }
file_mode() { stat -f '%Lp' "$1"; }

# --- app build -----------------------------------------------------------------------------------

test_build_runs_the_toolchain_in_order_and_prints_the_apk() {
  ferry app build
  assert_rc 0 "build"
  assert_eq "$FDIR/.build/ferry.apk" "$OUT" "apk path"
  assert_file "$FDIR/.build/ferry.apk" "signed apk"
  local order
  order="$(calls_matching '^(aapt2|javac|d8|zipalign|keytool|apksigner) ' | awk '{print $1 " " $2}' | tr '\n' ',')"
  assert_eq "aapt2 compile,aapt2 link,javac -nowarn,d8 --release,zipalign -f,keytool -genkeypair,keytool -list,apksigner sign," "$order" "tool order"
}

test_build_passes_sdk_versions_and_a_numeric_version_code() {
  ferry app build
  local link code
  link="$(calls_matching '^aapt2 link')"
  assert_contains "$link" "--min-sdk-version 30 --target-sdk-version 36" "sdk levels"
  assert_contains "$link" "-I $SDK/platforms/android-36.1/android.jar" "platform jar"
  code="$(sed -n 's/.*--version-code \([0-9]*\) .*/\1/p' <<< "$link")"
  [[ "$code" =~ ^[0-9]+$ && "$code" -gt 0 ]] || fail "version code [$code] is not a positive number"
  assert_contains "$link" "--version-name 1.$code" "version name follows the code"
  assert_contains "$(calls_matching '^javac')" "--release 17 -classpath $SDK/platforms/android-36.1/android.jar" "javac release and classpath"
  assert_contains "$(calls_matching '^d8')" "--release --min-api 30" "d8 flags"
}

test_build_signs_with_the_keystore_alias() {
  ferry app build
  assert_contains "$(calls_matching '^apksigner')" "--ks $HOMEDIR/.config/ferry/release.keystore" "keystore"
  assert_contains "$(calls_matching '^apksigner')" "--ks-key-alias ferry" "alias read from the keystore"
}

test_build_creates_keystore_once_with_private_mode() {
  ferry app build
  assert_eq "600" "$(file_mode "$HOMEDIR/.config/ferry/release.keystore")" "keystore mode"
}

test_build_never_replaces_an_existing_keystore() {
  echo precious > "$HOMEDIR/.config/ferry/release.keystore"
  ferry app build
  assert_rc 0 "build"
  assert_eq "precious" "$(cat "$HOMEDIR/.config/ferry/release.keystore")" "keystore untouched"
  assert_eq "0" "$(count_calls '^keytool -genkeypair')" "no new key"
}

test_build_clears_stale_outputs() {
  mkdir -p "$FDIR/.build/classes" "$FDIR/.build/gen" "$FDIR/.build/dex"
  touch "$FDIR/.build/classes/Stale.class" "$FDIR/.build/gen/Stale.java" "$FDIR/.build/dex/stale.dex"
  ferry app build
  assert_no_file "$FDIR/.build/classes/Stale.class" "stale class"
  assert_no_file "$FDIR/.build/gen/Stale.java" "stale generated source"
  assert_no_file "$FDIR/.build/dex/stale.dex" "stale dex"
}

test_build_needs_the_android_platform_jar() {
  rm "$SDK/platforms/android-36.1/android.jar"
  ferry app build
  assert_rc 1 "build"
  assert_contains "$ERR" "Android SDK missing" "message"
  assert_eq "0" "$(count_calls '^aapt2')" "toolchain not started"
}

test_build_reports_javac_failure() {
  touch "$S/javac_fail"
  ferry app build
  assert_rc 1 "build"
  assert_contains "$ERR" "javac failed" "message"
  assert_eq "0" "$(count_calls '^d8')" "no dexing after a failed compile"
}

test_build_hides_javac_notes_but_not_errors() {
  ferry app build
  assert_not_contains "$OUT$ERR" "Note:" "javac notes filtered"
}

# --- app install ---------------------------------------------------------------------------------

installed_a11y() { sed -n 's/^adb .*settings put secure enabled_accessibility_services \(.*\)/\1/p' "$LOG"; }

test_install_sets_the_phone_up_end_to_end() {
  one_device
  tailnet 100.101.102.103
  ferry app install
  assert_rc 0 "install"
  assert_contains "$OUT" "installed 1.2345" "version read back (CR stripped)"
  assert_contains "$OUT" "configured for 100.101.102.103:47821." "host and port"
  local c; c="$(calls)"
  assert_contains "$c" "adb -s PIXEL123 install -r $FDIR/.build/ferry.apk" "install"
  assert_contains "$c" "shell pm grant com.anurag.ferry android.permission.READ_LOGS" "READ_LOGS"
  assert_contains "$c" "shell pm grant com.anurag.ferry android.permission.POST_NOTIFICATIONS" "POST_NOTIFICATIONS"
  assert_contains "$c" "shell appops set com.anurag.ferry SYSTEM_ALERT_WINDOW allow" "overlay"
  assert_contains "$c" "shell dumpsys deviceidle whitelist +com.anurag.ferry" "doze whitelist"
  assert_contains "$c" "shell cmd netpolicy add restrict-background-whitelist 10234" "data saver whitelist with the app uid"
  assert_contains "$c" "shell settings put secure accessibility_enabled 1" "accessibility on"
  assert_contains "$c" "shell cmd statusbar add-tile com.anurag.ferry/.ClipTile" "tile"
  assert_contains "$c" "shell am start -n com.anurag.ferry/.MainActivity" "app started"
}

test_install_hands_the_token_and_address_to_the_app() {
  one_device
  tailnet 100.64.0.7
  ferry app install
  local tok; tok="$(cat "$HOMEDIR/.config/ferry/token")"
  [[ "$tok" =~ ^[0-9a-f]{64}$ ]] || fail "token [$tok] is not 64 hex characters"
  assert_eq "600" "$(file_mode "$HOMEDIR/.config/ferry/token")" "token mode"
  assert_contains "$(calls)" "am broadcast -a com.anurag.ferry.CONFIGURE -n com.anurag.ferry/.ConfigReceiver --es host 100.64.0.7 --ei port 47821 --es token $tok" "broadcast"
}

test_install_reuses_the_existing_token() {
  one_device
  tailnet 100.64.0.7
  printf 'abc123\n' > "$HOMEDIR/.config/ferry/token"
  ferry app install
  assert_eq "abc123" "$(cat "$HOMEDIR/.config/ferry/token" | tr -d '\n')" "token kept"
  assert_contains "$(calls)" "--es token abc123" "existing token sent without the newline"
}

test_install_picks_the_first_tailnet_address_only() {
  one_device
  printf '\tinet 10.0.0.5 netmask 0xff\n\tinet 100.63.255.255 netmask 0xff\n\tinet 100.128.0.1 netmask 0xff\n\tinet 100.127.255.254 netmask 0xff\n\tinet 100.80.1.1 netmask 0xff\n' > "$S/ifconfig"
  ferry app install
  assert_contains "$OUT" "configured for 100.127.255.254:47821" "first address inside 100.64.0.0/10"
}

test_install_tailnet_range_edges() {
  local ip
  for ip in 100.64.0.0 100.65.1.1 100.99.9.9 100.100.0.1 100.119.1.1 100.120.0.1 100.127.0.1; do
    printf '\tinet %s netmask 0xff\n' "$ip" > "$S/ifconfig"
    one_device
    ferry app install
    assert_contains "$OUT" "configured for $ip:47821" "accepts $ip"
  done
  for ip in 100.63.0.1 100.128.0.1 101.64.0.1 100.200.1.1 99.64.0.1; do
    printf '\tinet %s netmask 0xff\n' "$ip" > "$S/ifconfig"
    ferry app install
    assert_rc 1 "rejects $ip"
  done
}

test_install_without_tailscale_address_fails_after_app_is_installed() {
  one_device
  ferry app install
  assert_rc 1 "install"
  assert_contains "$ERR" "no Tailscale IP on this Mac" "message"
  assert_eq "0" "$(count_calls 'am broadcast')" "no half configuration sent"
}

test_install_removes_the_old_phonelink_app_once() {
  one_device
  tailnet 100.64.0.7
  touch "$S/old_pkg"
  ferry app install
  assert_contains "$OUT" "removed the old PhoneLink app" "migration message"
  assert_contains "$(calls)" "shell pm uninstall com.anurag.phonelink" "uninstall call"
}

test_install_leaves_phone_alone_when_old_app_is_absent() {
  one_device
  tailnet 100.64.0.7
  ferry app install
  assert_not_contains "$OUT" "PhoneLink" "no migration message"
  assert_eq "0" "$(count_calls 'pm uninstall')" "nothing uninstalled"
}

test_install_accessibility_list_cases() {
  one_device
  tailnet 100.64.0.7
  local svc="com.anurag.ferry/com.anurag.ferry.ShotService" old="com.anurag.phonelink/com.anurag.phonelink.ShotService"
  local cases=(
    "null|$svc"
    "|$svc"
    "other.app/Svc|other.app/Svc:$svc"
    "$old|$svc"
    "$old:other.app/Svc|other.app/Svc:$svc"
    "other.app/Svc:$svc|other.app/Svc:$svc"
    "$svc|$svc"
    "a/A:$old:b/B:$svc:c/C|a/A:b/B:c/C:$svc"
  )
  local c in want
  for c in "${cases[@]}"; do
    in="${c%%|*}"; want="${c#*|}"
    : > "$LOG"
    printf '%s\n' "$in" > "$S/a11y"
    ferry app install
    assert_eq "$want" "$(installed_a11y)" "accessibility list for [$in]"
  done
}

test_install_stops_before_changing_the_phone_when_install_fails() {
  one_device
  tailnet 100.64.0.7
  echo "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]" > "$S/adb_fail_install"
  ferry app install
  assert_rc 1 "install"
  assert_eq "0" "$(count_calls 'pm grant')" "no permissions granted"
  assert_eq "0" "$(count_calls 'am broadcast')" "no configuration sent"
}

test_install_without_phone_builds_but_stops() {
  ferry app install
  assert_rc 1 "install"
  assert_contains "$ERR" "phone not reachable over adb" "message"
  assert_eq "0" "$(count_calls 'adb .*install')" "no install attempt"
}

test_install_aborts_when_the_build_fails() {
  one_device
  touch "$S/javac_fail"
  ferry app install
  assert_rc 1 "install"
  assert_eq "0" "$(count_calls '^adb ')" "adb never reached"
}

run_tests
