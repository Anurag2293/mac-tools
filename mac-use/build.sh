#!/bin/sh
# Builds mac-use with swiftc directly (SwiftPM's manifest step fails with some Command Line Tools installs).
set -e
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 Sources/mac-use/*.swift -o bin/mac-use
echo "built $(pwd)/bin/mac-use"
