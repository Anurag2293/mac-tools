#!/bin/sh
# Builds and runs the mac-use tests. State, logs and config are redirected to a scratch directory (MAC_USE_HOME).
set -e
cd "$(dirname "$0")"
root="$PWD"
build="$root/.build-tests"
mkdir -p "$build"

stale() {
    [ ! -e "$1" ] || [ -n "$(find Sources Tests build.sh test.sh -type f -newer "$1" 2>/dev/null | head -n 1)" ]
}

fail() {
    echo "$1 failed to build:" >&2
    cat "$2" >&2
    exit 1
}

product=""
tests=""
if stale "$build/mac-use"; then
    ./build.sh "$build/mac-use" -D MAC_USE_TESTING > "$build/product.log" 2>&1 &
    product=$!
fi
if stale "$build/mac-use-tests"; then
    swiftc -D MAC_USE_TESTING -swift-version 5 -target arm64-apple-macosx14.0 \
        $(ls Sources/mac-use/*.swift | grep -v '/main\.swift$') Tests/*.swift -o "$build/mac-use-tests" > "$build/tests.log" 2>&1 &
    tests=$!
fi
[ -z "$product" ] || wait "$product" || fail "mac-use" "$build/product.log"
[ -z "$tests" ] || wait "$tests" || fail "the test runner" "$build/tests.log"

home="$(mktemp -d "${TMPDIR:-/tmp}/mac-use-tests.XXXXXX")"
trap 'rm -rf "$home"' EXIT
MAC_USE_HOME="$home" MAC_USE_BIN="$build/mac-use" MAC_USE_DIR="$root" "$build/mac-use-tests" "$@"
