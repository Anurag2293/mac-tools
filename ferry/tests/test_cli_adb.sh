#!/bin/bash
# `ferry adb connect|pair|tcpip|status`.
source "$(dirname "$0")/lib.sh"

count_calls() { calls_matching "$1" | wc -l | tr -d ' '; }
one_device() { printf 'List of devices attached\nPIXEL123\tdevice\n' > "$S/adb_devices"; }

test_adb_defaults_to_status() {
  one_device
  printf 'List of discovered mdns services\nadb-X\t_adb-tls-connect._tcp\t10.0.0.2:4444\n' > "$S/adb_mdns"
  ferry adb
  assert_rc 0 "adb"
  assert_contains "$(calls)" "adb devices -l" "device list"
  assert_contains "$OUT" "mDNS:" "mdns header"
  assert_contains "$OUT" "adb-X" "service listed"
  assert_not_contains "$OUT" "List of discovered mdns services" "mdns header line dropped"
}

test_adb_connect_prints_serial_and_model() {
  one_device
  ferry adb connect
  assert_rc 0 "connect"
  assert_eq "connected: PIXEL123 (Pixel 7 Pro)" "$OUT" "carriage return stripped from the model"
}

test_adb_connect_without_phone_fails_with_hint() {
  ferry adb connect
  assert_rc 1 "connect"
  assert_contains "$ERR" "phone not reachable over adb" "message"
  assert_contains "$ERR" "ferry adb pair HOST:PORT CODE" "hint"
}

test_adb_connect_asks_hub_when_nothing_listed() {
  printf '10.1.1.1:5555\n' > "$S/hub_serial"
  ferry adb connect
  assert_rc 0 "connect"
  assert_contains "$OUT" "connected: 10.1.1.1:5555" "serial from the hub"
}

# --- pair ----------------------------------------------------------------------------------------

test_adb_pair_with_address_and_code() {
  one_device
  ferry adb pair 192.168.1.7:37099 123456
  assert_rc 0 "pair"
  assert_contains "$(calls)" "adb pair 192.168.1.7:37099 123456" "pair call"
  assert_contains "$OUT" "connected: PIXEL123" "connects afterwards"
}

test_adb_pair_with_code_only_uses_mdns_address() {
  one_device
  printf 'List of discovered mdns services\nadb-A\t_adb-tls-connect._tcp\t10.0.0.9:1111\nadb-B\t_adb-tls-pairing._tcp\t10.0.0.8:2222\nadb-C\t_adb-tls-pairing._tcp\t10.0.0.7:3333\n' > "$S/adb_mdns"
  ferry adb pair 654321
  assert_rc 0 "pair"
  assert_contains "$(calls)" "adb pair 10.0.0.7:3333 654321" "last advertised pairing address"
}

test_adb_pair_code_only_gives_up_after_five_tries() {
  ferry adb pair 654321
  assert_rc 1 "pair"
  assert_contains "$ERR" "no phone advertising pairing" "message"
  assert_eq "5" "$(count_calls '^adb mdns')" "five mdns polls"
  assert_eq "5" "$(count_calls '^sleep 1')" "one second apart"
  assert_eq "0" "$(count_calls '^adb pair')" "never pairs"
}

test_adb_pair_finds_address_on_a_later_poll() {
  one_device
  printf '#!/bin/bash\nn=$(cat "$FERRY_TEST_STATE/n" 2>/dev/null || echo 0); echo $((n+1)) > "$FERRY_TEST_STATE/n"\n[ $((n+1)) -ge 2 ] && printf "x\\t_adb-tls-pairing._tcp\\t10.0.0.5:7777\\n" > "$FERRY_TEST_STATE/adb_mdns"\nexit 0\n' > "$S/on_sleep"
  chmod +x "$S/on_sleep"
  ferry adb pair 111111
  assert_rc 0 "pair"
  assert_contains "$(calls)" "adb pair 10.0.0.5:7777 111111" "address found on the second poll"
}

test_adb_pair_usage_errors() {
  ferry adb pair
  assert_rc 1 "no args"
  assert_contains "$ERR" "usage: ferry adb pair [HOST:PORT] CODE" "usage"
  ferry adb pair a b c
  assert_rc 1 "three args"
  assert_eq "0" "$(count_calls '^adb pair')" "nothing paired"
}

test_adb_pair_failure_stops_before_connect() {
  echo "Failed: wrong pairing code" > "$S/adb_fail_pair"
  ferry adb pair 1.2.3.4:5 000000
  assert_rc 1 "pair"
  assert_eq "0" "$(count_calls '^adb devices')" "no connect attempt"
}

# --- tcpip ---------------------------------------------------------------------------------------

test_adb_tcpip_switches_usb_phone_to_wifi() {
  printf 'List of devices attached\n192.168.1.5:5555\tdevice\nUSB999\tdevice\n' > "$S/adb_devices"
  printf '   route to: default\n    gateway: 192.168.43.1\n  interface: en0\n' > "$S/route"
  ferry adb tcpip
  assert_rc 0 "tcpip"
  assert_contains "$(calls)" "adb -s USB999 tcpip 5555" "USB serial used, wifi one skipped"
  assert_contains "$(calls)" "sleep 2" "waits for adbd"
  assert_contains "$(calls)" "adb connect 192.168.43.1:5555" "hotspot gateway"
  assert_eq "192.168.43.1:5555" "$(cat "$HOMEDIR/.config/ferry/adb_addr")" "address remembered"
  assert_contains "$OUT" "You can unplug the cable now." "message"
}

test_adb_tcpip_needs_a_usb_phone() {
  printf 'List of devices attached\n192.168.1.5:5555\tdevice\nOFF1\toffline\n' > "$S/adb_devices"
  ferry adb tcpip
  assert_rc 1 "tcpip"
  assert_contains "$ERR" "no USB phone found" "message"
  assert_eq "0" "$(count_calls 'tcpip 5555')" "nothing switched"
}

test_adb_tcpip_without_default_gateway_explains_itself() {
  printf 'List of devices attached\nUSB999\tdevice\n' > "$S/adb_devices"
  ferry adb tcpip
  assert_rc 1 "tcpip"
  assert_contains "$ERR" "no default gateway; is the Mac on the phone's hotspot?" "message instead of a silent exit"
  assert_no_file "$HOMEDIR/.config/ferry/adb_addr" "nothing remembered"
}

test_adb_tcpip_gateway_line_without_address() {
  printf 'List of devices attached\nUSB999\tdevice\n' > "$S/adb_devices"
  printf '   route to: default\n  interface: en0\n' > "$S/route"
  ferry adb tcpip
  assert_rc 1 "tcpip"
  assert_contains "$ERR" "no default gateway" "message"
}

run_tests
