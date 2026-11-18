# Shared helpers for the bash tests (sourced). Runs under macOS bash 3.2.
#
# Every test gets a fresh sandbox under /tmp/ferry-test.XXXXXX holding a copy of the `ferry` script
# with a fake hub, fake adb/launchctl/osascript/... first on PATH, and HOME pointed inside it.
# Nothing in a test can reach the real hub, launchd, adb or ~/.config/ferry.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FERRY_SRC="$(cd "$TESTS_DIR/.." && pwd)/ferry"
PYTHON="${FERRY_TEST_PYTHON:-$(command -v python3)}"

sandbox_new() {
  T="$(cd "$(mktemp -d /tmp/ferry-test.XXXXXX)" && pwd -P)"
  HOMEDIR="$T/home"
  BIN="$T/bin"
  S="$T/state"
  LOG="$T/calls.log"
  FDIR="$T/ferry-dir"
  SDK="$T/sdk"
  JDK="$T/jdk"
  SHOTS="$T/shots"
  SYNC="$T/sync"
  mkdir -p "$HOMEDIR/.config/ferry" "$HOMEDIR/Library/LaunchAgents" "$BIN" "$S" "$FDIR/hub" \
    "$SDK/build-tools/36.1.0" "$SDK/platforms/android-36.1" "$JDK/bin" "$SHOTS" "$SYNC"
  : > "$LOG"
  cp "$FERRY_SRC" "$FDIR/ferry"
  cp "$TESTS_DIR/fake_ferryd" "$FDIR/hub/ferryd"
  mkdir -p "$FDIR/peek" "$FDIR/android/res" "$FDIR/android/src"
  echo "// peek" > "$FDIR/peek/peek.swift"
  echo "<manifest/>" > "$FDIR/android/AndroidManifest.xml"
  echo "class MainActivity {}" > "$FDIR/android/src/MainActivity.java"
  local f
  for f in adb osascript launchctl swiftc sleep tail route ifconfig; do
    cp "$TESTS_DIR/fakebin/$f" "$BIN/$f"
  done
  for f in aapt2 d8 zipalign apksigner; do cp "$TESTS_DIR/fakebin/$f" "$SDK/build-tools/36.1.0/$f"; done
  for f in javac keytool; do cp "$TESTS_DIR/fakebin/$f" "$JDK/bin/$f"; done
  : > "$SDK/platforms/android-36.1/android.jar"
  ln -s "$PYTHON" "$BIN/python3"
  chmod -R u+rwx "$BIN" "$SDK" "$JDK" "$FDIR"
  CHILD_PIDS_FILE="$T/pids"
  : > "$CHILD_PIDS_FILE"
  sandbox_probe
}

sandbox_clean() {
  local p
  while read -r p; do
    [[ -n "$p" ]] || continue
    pkill -P "$p" 2>/dev/null
    kill "$p" 2>/dev/null
  done < "$CHILD_PIDS_FILE"
  rm -rf "$T"
}

# Refuse to continue unless every external tool resolves inside the sandbox.
sandbox_probe() {
  local tool path
  for tool in adb osascript launchctl swiftc sleep tail route ifconfig python3; do
    path="$(sbx_env /bin/bash -c 'command -v "$1"' _ "$tool" 2>/dev/null)" || path=""
    case "$path" in
      "$BIN"/*) ;;
      *) echo "SAFETY: $tool resolves to '$path', not the sandbox; aborting" >&2; exit 99 ;;
    esac
  done
  [[ "$(sbx_env printenv HOME)" == "$HOMEDIR" ]] || { echo "SAFETY: HOME not sandboxed" >&2; exit 99; }
  [[ "$HOMEDIR" == /private/tmp/ferry-test.* ]] || { echo "SAFETY: sandbox not under /private/tmp/ferry-test." >&2; exit 99; }
}

# Run a command in a scrubbed environment. Extra KEY=VALUE pairs go in SBX_EXTRA (array).
sbx_env() {
  env -i HOME="$HOMEDIR" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    FERRY_TEST_LOG="$LOG" FERRY_TEST_STATE="$S" \
    FERRY_SHOTS_DIR="$SHOTS" FERRY_SYNC_DIR="$SYNC" FERRY_SYNCTHING_URL=http://127.0.0.1:9 \
    ANDROID_HOME="$SDK" FERRY_JDK="$JDK" LANG=en_US.UTF-8 \
    ${SBX_EXTRA[@]+"${SBX_EXTRA[@]}"} "$@"
}

# ferry ARGS...: sets OUT, ERR, RC.
ferry() {
  local o="$T/out" e="$T/err"
  sbx_env /bin/bash "$FDIR/ferry" "$@" > "$o" 2> "$e"
  RC=$?
  OUT="$(cat "$o")"
  ERR="$(cat "$e")"
  return 0
}

start_ctl_hub() {  # MODE [PNG]
  sbx_env "$PYTHON" "$TESTS_DIR/fake_ctl_hub.py" "$@" > "$T/hub.out" 2>&1 &
  echo $! >> "$CHILD_PIDS_FILE"; disown
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -S "$HOMEDIR/.config/ferry/ctl.sock" ]] && return 0
    sleep 0.1
  done
  echo "control hub did not start: $(cat "$T/hub.out")" >&2
  return 1
}

# start_syncthing STATE_JSON: fake Syncthing REST on 127.0.0.1 plus an API key in its config.xml.
start_syncthing() {
  local cfg="$HOMEDIR/Library/Application Support/Syncthing"
  mkdir -p "$cfg"
  printf '<configuration><gui><apikey>KEY123</apikey></gui></configuration>\n' > "$cfg/config.xml"
  echo "$1" > "$S/syncthing_state.json"
  "$PYTHON" "$TESTS_DIR/fake_syncthing.py" "$T/st.port" "$S/syncthing_state.json" KEY123 &
  echo $! >> "$CHILD_PIDS_FILE"; disown
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -s "$T/st.port" ]] && break
    sleep 0.1
  done
  SBX_EXTRA=("FERRY_SYNCTHING_URL=http://127.0.0.1:$(cat "$T/st.port")")
}

calls() { cat "$LOG"; }
calls_matching() { grep -E -- "$1" "$LOG" || true; }

# --- assertions ----------------------------------------------------------------------------------

FAILED_FLAG=""
fail() { echo "  FAIL: $*" >&2; FAILED_FLAG=1; }

assert_eq() {  # EXPECTED ACTUAL MESSAGE
  [[ "$1" == "$2" ]] || fail "$3: expected [$1] got [$2]"
}
assert_contains() {  # HAYSTACK NEEDLE MESSAGE
  [[ "$1" == *"$2"* ]] || fail "$3: [$1] does not contain [$2]"
}
assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "$3: [$1] unexpectedly contains [$2]"
}
assert_rc() {  # EXPECTED MESSAGE
  [[ "$RC" == "$1" ]] || fail "$2: exit status expected $1 got $RC (stderr: $ERR)"
}
assert_file() { [[ -e "$1" ]] || fail "${2:-file missing}: $1"; }
assert_no_file() { [[ ! -e "$1" ]] || fail "${2:-file exists}: $1"; }

# Run every function named test_* in the sourcing script, each in its own sandbox subshell.
run_tests() {
  local fn passed=0 failed=0 names rc
  names="$(declare -F | awk '{print $3}' | grep '^test_' || true)"
  for fn in $names; do
    if (
      FAILED_FLAG=""
      sandbox_new
      trap 'sandbox_clean' EXIT
      fn_rc=0
      "$fn" || fn_rc=$?
      [[ "$fn_rc" -eq 0 && -z "$FAILED_FLAG" ]]
    ); then
      passed=$((passed + 1))
    else
      rc=$?
      [[ "$rc" -eq 99 ]] && { echo "RESULT passed=$passed failed=1 skipped=0"; exit 99; }
      failed=$((failed + 1))
      echo "FAILED: $fn" >&2
    fi
  done
  echo "RESULT passed=$passed failed=$failed skipped=0"
  [[ "$failed" -eq 0 ]]
}
