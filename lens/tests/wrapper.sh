#!/bin/bash
# Tests for the `lens` bash wrapper. Every run uses a copy of the script in a temp directory,
# HOME set to a temp directory, and fake launchctl, swiftc, codesign, tccutil, open, sleep and
# tail first on PATH, so nothing here can reach the real agent, app bundle or permissions.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LENS_SRC="$HERE/../lens"
REAL_HOME="$HOME"
LABEL=com.anurag.lens
UID_="$(id -u)"

fingerprint() {
  stat -f '%m %z' "$REAL_HOME/Library/LaunchAgents/$LABEL.plist" "$REAL_HOME/.local/bin/lens" \
    "$REAL_HOME/Library/Logs/lens.log" "$REAL_HOME/Library/Logs/lens.log" 2>&1
}
BEFORE="$(fingerprint)"

T="$(mktemp -d "${TMPDIR:-/tmp}/lens-wrapper-tests.XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "    FAIL $1"; [[ -n "${2:-}" ]] && echo "         $2"; }
eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1" "got '$2', want '$3'"; fi; }
ne() { if [[ "$2" != "$3" ]]; then ok; else bad "$1" "got '$2', want anything else"; fi; }
has() { if grep -qF -- "$3" "$2" 2>/dev/null; then ok; else bad "$1" "'$3' not found in $2: $(head -c 300 "$2" 2>/dev/null)"; fi; }
hasnt() { if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1" "'$3' found in $2"; else ok; fi; }
count() { eq "$1" "$(grep -cF -- "$3" "$2" 2>/dev/null || true)" "$4"; }
exists() { if [[ -e "$2" || -L "$2" ]]; then ok; else bad "$1" "$2 does not exist"; fi; }
absent() { if [[ -e "$2" || -L "$2" ]]; then bad "$1" "$2 exists"; else ok; fi; }
section() { echo "== wrapper: $1"; }

write_fakes() {
  local f
  for f in codesign tccutil open sleep; do
    cat > "$FB/$f" <<'EOF'
#!/bin/bash
echo "$(basename "$0") $*" >> "$FAKE_LOG"
exit 0
EOF
  done
  cat > "$FB/tail" <<'EOF'
#!/bin/bash
echo "tail $*" >> "$FAKE_LOG"
case " $* " in *" -f "*) exit 0 ;; esac
exec /usr/bin/tail "$@"
EOF
  cat > "$FB/launchctl" <<'EOF'
#!/bin/bash
echo "launchctl $*" >> "$FAKE_LOG"
case "$1" in
  print)
    [[ "${FAKE_PRINT:-ok}" == ok ]] || exit 113
    printf 'gui/501/com.anurag.lens = {\n\tstate = running\n}\n' ;;
  bootstrap)
    n=$(cat "$FAKE_STATE/bootstrap" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_STATE/bootstrap"
    (( n <= ${FAKE_BOOTSTRAP_FAILS:-0} )) && exit 5 ;;
  bootout) exit "${FAKE_BOOTOUT_RC:-0}" ;;
esac
exit 0
EOF
  cat > "$FB/swiftc" <<'EOF'
#!/bin/bash
echo "swiftc $*" >> "$FAKE_LOG"
if [[ -n "${FAKE_SWIFTC_FAIL:-}" ]]; then echo "error: compile failed" >&2; exit 1; fi
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then out="$2"; shift; fi
  shift
done
n=$(cat "$FAKE_STATE/swiftc" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_STATE/swiftc"
[[ -n "${FAKE_SWIFTC_SAME:-}" ]] && n=1
printf '#!/bin/bash\necho "Lens $*" >> "$FAKE_LOG"\n# build %s\n' "$n" > "$out"
chmod +x "$out"
EOF
  chmod +x "$FB"/*
}

CASE=0
EXTRA=()

newcase() {
  CASE=$((CASE + 1))
  C="$T/case$CASE"
  H="$C/home"; FB="$C/fakebin"; ST="$C/state"; CALLS="$C/calls.log"
  TOOL="$C/${1:-tool}"
  mkdir -p "$H" "$FB" "$ST" "$TOOL"
  : > "$CALLS"
  cp "$LENS_SRC" "$TOOL/lens"
  : > "$TOOL/Core.swift"; : > "$TOOL/main.swift"
  touch -t 202001010000 "$TOOL/Core.swift" "$TOOL/main.swift"
  write_fakes
  EXTRA=()
  TOOLP="$(cd "$TOOL" && pwd -P)"
  APP="$TOOLP/.build/Lens.app"
  BIN="$APP/Contents/MacOS/Lens"
  PLIST="$H/Library/LaunchAgents/$LABEL.plist"
  LOG="$H/Library/Logs/lens.log"
}

run() {
  OUT="$C/out"; ERR="$C/err"
  env -i HOME="$H" PATH="$FB:/usr/bin:/bin" FAKE_LOG="$CALLS" FAKE_STATE="$ST" "${EXTRA[@]+"${EXTRA[@]}"}" \
    "$TOOL/lens" "$@" > "$OUT" 2> "$ERR"
  RC=$?
}

runvia() {
  local exe="$1"; shift
  OUT="$C/out"; ERR="$C/err"
  env -i HOME="$H" PATH="$FB:/usr/bin:/bin" FAKE_LOG="$CALLS" FAKE_STATE="$ST" "${EXTRA[@]+"${EXTRA[@]}"}" \
    "$exe" "$@" > "$OUT" 2> "$ERR"
  RC=$?
}

section "the fakes shadow the real system tools"
newcase
for tool in launchctl tccutil swiftc codesign open sleep tail; do
  found="$(env -i PATH="$FB:/usr/bin:/bin" /bin/bash -c "command -v $tool")"
  eq "$tool resolves to the fake" "$found" "$FB/$tool"
done
if [[ $FAIL -ne 0 ]]; then
  echo "wrapper tests: refusing to continue, the real tools are not shadowed"
  exit 1
fi

section "help and unknown commands"
for arg in help -h --help; do
  newcase
  run "$arg"
  eq "$arg exits 0" "$RC" 0
  has "$arg lists setup" "$OUT" "lens setup [force]"
  has "$arg lists file" "$OUT" "lens file IMG [--out PNG]"
  has "$arg mentions the settings" "$OUT" "LENS_HOTKEY=double:rcmd"
  eq "$arg calls nothing" "$(cat "$CALLS")" ""
done
newcase
run frobnicate
eq "unknown command exits 1" "$RC" 1
eq "unknown command message" "$(cat "$ERR")" "lens: unknown command 'frobnicate' (lens help)"
eq "unknown command calls nothing" "$(cat "$CALLS")" ""
run -x
eq "unknown flag exits 1" "$RC" 1
run Setup
eq "commands are case sensitive" "$RC" 1
absent "unknown commands create nothing" "$H/Library"

section "toggle"
newcase
run
ne "toggle before any build fails" "$RC" 0
eq "toggle before a build calls nothing" "$(cat "$CALLS")" ""
run toggle
ne "explicit toggle before any build fails" "$RC" 0
run ""
ne "empty argument is a toggle" "$RC" 0
run build
run
eq "toggle exits 0" "$RC" 0
eq "toggle runs the app with --toggle" "$(grep -c '^Lens --toggle$' "$CALLS")" 1
run toggle
eq "explicit toggle" "$(grep -c '^Lens --toggle$' "$CALLS")" 2
run ""
eq "empty argument toggles" "$(grep -c '^Lens --toggle$' "$CALLS")" 3
count "toggle never touches launchd" "$CALLS" launchctl 0

section "build"
newcase
run build
eq "build exits 0" "$RC" 0
eq "build says where" "$(cat "$OUT")" "built $APP"
has "swiftc flags and sources" "$CALLS" "swiftc -O -swift-version 5 -o $BIN $TOOLP/Core.swift $TOOLP/main.swift"
has "codesign" "$CALLS" "codesign --force --sign - --identifier $LABEL $APP"
exists "binary" "$BIN"
exists "Info.plist" "$APP/Contents/Info.plist"
has "bundle id" "$APP/Contents/Info.plist" "<key>CFBundleIdentifier</key><string>$LABEL</string>"
has "executable name" "$APP/Contents/Info.plist" "<key>CFBundleExecutable</key><string>Lens</string>"
has "agent app" "$APP/Contents/Info.plist" "<key>LSUIElement</key><true/>"
has "screen capture reason" "$APP/Contents/Info.plist" "NSScreenCaptureUsageDescription"
eq "Info.plist is valid" "$(plutil -lint "$APP/Contents/Info.plist" | sed 's/^.*: //')" "OK"
run build
count "build always rebuilds" "$CALLS" "swiftc " 2

newcase
run build
count "an unchanged tree is not rebuilt by file" "$CALLS" "swiftc " 1
run file shot.png --out out.png
eq "file exits 0" "$RC" 0
count "file does not rebuild a fresh binary" "$CALLS" "swiftc " 1
has "file passes its arguments through" "$CALLS" "Lens --file shot.png --out out.png"
touch -t 201901010000 "$BIN"
touch -t 202101010000 "$TOOL/Core.swift"
run file a.png
count "file rebuilds when Core.swift is newer" "$CALLS" "swiftc " 2
run file a.png
count "and then not again" "$CALLS" "swiftc " 2
touch -t 201901010000 "$BIN"
touch -t 202101010000 "$TOOL/main.swift"
run file a.png
count "file rebuilds when main.swift is newer" "$CALLS" "swiftc " 3

newcase
run file shot.png
eq "file builds when there is no binary" "$RC" 0
count "built once" "$CALLS" "swiftc " 1
has "then ran" "$CALLS" "Lens --file shot.png"
run file
eq "file without arguments passes nothing" "$(grep -c '^Lens --file$' "$CALLS")" 1

newcase
EXTRA=(FAKE_SWIFTC_FAIL=1)
run build
ne "a failing compile fails the build" "$RC" 0
hasnt "no success message" "$OUT" "built"
count "no codesign after a failed compile" "$CALLS" codesign 0
run file a.png
ne "file fails when the build fails" "$RC" 0
count "the app is not started after a failed build" "$CALLS" "Lens --file" 0

newcase "dir with space"
run build
eq "build works in a directory with a space" "$RC" 0
has "sources are quoted" "$CALLS" "$TOOLP/Core.swift $TOOLP/main.swift"
exists "binary in the spaced directory" "$BIN"

section "setup"
newcase
run setup
eq "setup exits 0" "$RC" 0
exists "plist" "$PLIST"
exists "symlink" "$H/.local/bin/lens"
eq "symlink target" "$(readlink "$H/.local/bin/lens")" "$TOOLP/lens"
eq "plist is valid" "$(plutil -lint "$PLIST" | sed 's/^.*: //')" "OK"
has "plist label" "$PLIST" "<key>Label</key><string>$LABEL</string>"
has "plist program" "$PLIST" "<array><string>$BIN</string></array>"
has "plist keeps it alive" "$PLIST" "<key>KeepAlive</key><true/>"
has "plist log path" "$PLIST" "<key>StandardOutPath</key><string>$LOG</string>"
has "plist is for the GUI session" "$PLIST" "<key>LimitLoadToSessionType</key><string>Aqua</string>"
hasnt "no LENS variables by default" "$PLIST" "LENS_"
has "bootout" "$CALLS" "launchctl bootout gui/$UID_/$LABEL"
has "bootstrap" "$CALLS" "launchctl bootstrap gui/$UID_ $PLIST"
has "print" "$CALLS" "launchctl print gui/$UID_/$LABEL"
count "no permission reset on a first build" "$CALLS" tccutil 0
has "output names the agent" "$OUT" "agent: $LABEL (log $LOG)"
hasnt "no rebuild notice" "$OUT" "rebuilt:"
eq "order: compile, sign, bootout, bootstrap, print" \
  "$(grep -n -E '^(swiftc|codesign|launchctl bootout|launchctl bootstrap|launchctl print)' "$CALLS" | sed -E 's/^[0-9]+://; s/ .*//' | tr '\n' ' ')" \
  "swiftc codesign launchctl launchctl launchctl "
eq "bootout precedes bootstrap" "$(grep -n -E 'bootout|bootstrap' "$CALLS" | sed -E 's/^[0-9]+:launchctl ([a-z]+) .*/\1/' | tr '\n' ' ')" "bootout bootstrap "
count "no other file was opened" "$CALLS" "open " 0

newcase
EXTRA=(LENS_ENGINE=apple LENS_HOTKEY=double:rshift LENS_FROM= LENS_TO=de)
run setup
eq "setup with settings exits 0" "$RC" 0
has "engine reaches the plist" "$PLIST" "<key>LENS_ENGINE</key><string>apple</string>"
has "hotkey reaches the plist" "$PLIST" "<key>LENS_HOTKEY</key><string>double:rshift</string>"
has "target reaches the plist" "$PLIST" "<key>LENS_TO</key><string>de</string>"
hasnt "an empty variable is left out" "$PLIST" "LENS_FROM"
eq "plist with settings is valid" "$(plutil -lint "$PLIST" | sed 's/^.*: //')" "OK"

newcase
EXTRA=(LENS_HOTKEY=ctrl+opt+t)
run setup
has "chord hotkey in the plist" "$PLIST" "<key>LENS_HOTKEY</key><string>ctrl+opt+t</string>"
EXTRA=()
run setup
hasnt "a later setup without the variable drops it" "$PLIST" "LENS_HOTKEY"

newcase
run setup
run setup
count "a second setup does not rebuild" "$CALLS" "swiftc " 1
count "and does not reset permissions" "$CALLS" tccutil 0
hasnt "and prints no rebuild notice" "$OUT" "rebuilt:"
count "but reloads the agent" "$CALLS" "launchctl bootstrap" 2
run setup force
count "setup force rebuilds" "$CALLS" "swiftc " 2
has "a changed binary resets Screen Recording" "$CALLS" "tccutil reset ScreenCapture $LABEL"
has "a changed binary resets Input Monitoring" "$CALLS" "tccutil reset ListenEvent $LABEL"
has "and says so" "$OUT" "rebuilt: macOS will ask again for Screen Recording and Input Monitoring"

newcase
EXTRA=(FAKE_SWIFTC_SAME=1)
run setup
run setup force
count "an identical rebuild does not reset permissions" "$CALLS" tccutil 0
hasnt "and says nothing about it" "$OUT" "rebuilt:"

newcase
run build
touch -t 201901010000 "$BIN"
run setup
count "setup rebuilds a stale binary" "$CALLS" "swiftc " 2
has "so permissions are reset" "$CALLS" "tccutil reset ScreenCapture"

newcase
EXTRA=(FAKE_BOOTSTRAP_FAILS=3)
run setup
eq "bootstrap is retried until it works" "$RC" 0
count "four bootstrap attempts" "$CALLS" "launchctl bootstrap" 4

newcase
EXTRA=(FAKE_BOOTSTRAP_FAILS=99 FAKE_PRINT=fail)
run setup
eq "setup fails when the agent never loads" "$RC" 1
eq "with this message" "$(cat "$ERR")" "lens: launchctl bootstrap failed"
count "after ten attempts" "$CALLS" "launchctl bootstrap" 10
hasnt "and prints no success line" "$OUT" "agent:"

newcase
EXTRA=(FAKE_BOOTSTRAP_FAILS=99)
run setup
eq "pinned: success is judged by launchctl print, not by bootstrap" "$RC" 0

newcase
EXTRA=(FAKE_BOOTOUT_RC=3)
run setup
eq "a failing bootout is ignored" "$RC" 0

newcase
EXTRA=(FAKE_SWIFTC_FAIL=1)
run setup
ne "setup fails when the compile fails" "$RC" 0
count "and never touches launchd" "$CALLS" launchctl 0
absent "and writes no plist" "$PLIST"
absent "and no symlink" "$H/.local/bin/lens"

newcase
mkdir -p "$H/Library/Logs"
echo "2026-01-01 00:00:00 hotkey double:rcmd (double-tap), ja→en via google" > "$LOG"
run setup
has "setup shows the last log line" "$CALLS" "tail -n 1 $LOG"

newcase
run setup
runvia "$H/.local/bin/lens" status
eq "the installed symlink works" "$RC" 0
has "status through the symlink" "$OUT" "agent: running"
runvia "$H/.local/bin/lens" build
eq "building through the symlink" "$RC" 0
exists "the build lands next to the real script" "$APP/Contents/Info.plist"
absent "and not next to the symlink" "$H/.local/bin/.build"

section "status, logs, uninstall"
newcase
run status
eq "status exits 0" "$RC" 0
eq "a running agent" "$(cat "$OUT")" "agent: running"
has "status asks launchd about this label" "$CALLS" "launchctl print gui/$UID_/$LABEL"
EXTRA=(FAKE_PRINT=fail)
run status
eq "status exits 0 when not installed" "$RC" 0
eq "agent not installed" "$(cat "$OUT")" "agent: not installed"
EXTRA=()
mkdir -p "$H/Library/Logs"
printf '%s\n' "a hotkey one" "something else" "b hotkey two" "tail line" > "$LOG"
run status
eq "status shows the last hotkey line" "$(cat "$OUT")" "$(printf 'agent: running\nb hotkey two')"
count "status changes nothing" "$CALLS" "launchctl print" 3
count "status never boots anything" "$CALLS" "launchctl boot" 0

newcase
run logs
eq "logs exits 0" "$RC" 0
has "logs follow the log file" "$CALLS" "tail -n 50 -f $LOG"

newcase
mkdir -p "$H/Library/LaunchAgents" "$H/.local/bin"
echo plist > "$PLIST"; ln -s "$TOOLP/lens" "$H/.local/bin/lens"
echo keep > "$H/.local/bin/other"
run uninstall
eq "uninstall exits 0" "$RC" 0
eq "uninstall message" "$(cat "$OUT")" "removed $LABEL"
has "uninstall boots the agent out" "$CALLS" "launchctl bootout gui/$UID_/$LABEL"
absent "plist removed" "$PLIST"
absent "symlink removed" "$H/.local/bin/lens"
exists "other files are kept" "$H/.local/bin/other"
run uninstall
eq "uninstall twice is fine" "$RC" 0
EXTRA=(FAKE_BOOTOUT_RC=1)
run uninstall
eq "a failing bootout does not fail uninstall" "$RC" 0

newcase
run setup
run uninstall
absent "setup then uninstall leaves no plist" "$PLIST"
absent "and no symlink" "$H/.local/bin/lens"
exists "the build stays" "$BIN"

section "nothing outside the temp directories was touched"
hasnt_real=0
for f in "$T"/case*/calls.log; do
  if grep -qF -- "$REAL_HOME/Library" "$f" || grep -qF -- "$REAL_HOME/.local" "$f"; then
    case "$T" in "$REAL_HOME"/*) ;; *) hasnt_real=1 ;; esac
  fi
done
eq "no fake call mentions the real HOME" "$hasnt_real" 0
eq "the real agent files are unchanged" "$(fingerprint)" "$BEFORE"

echo ""
echo "wrapper tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
