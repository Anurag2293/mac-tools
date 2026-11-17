#!/bin/sh
# Builds mac-use with swiftc directly (SwiftPM's manifest step fails with some Command Line Tools installs).
set -e
cd "$(dirname "$0")"
out="${1:-bin/mac-use}"
mkdir -p "$(dirname "$out")"
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 Sources/mac-use/*.swift -o "$out"
echo "built $(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
