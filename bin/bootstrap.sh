#!/usr/bin/env bash
# Bootstrap script for gs-ios.
# Installs xcodegen if missing, then generates GSApp.xcodeproj.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen not found. Installing via Homebrew..."
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is required. Install from https://brew.sh and re-run." >&2
        exit 1
    fi
    brew install xcodegen
fi

echo "Generating Xcode project from project.yml..."
xcodegen generate

echo ""
echo "Done. Open GSApp.xcodeproj in Xcode:"
echo "    open GSApp.xcodeproj"
