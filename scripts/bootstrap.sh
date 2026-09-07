#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in xcodegen cmake xcrun curl python3; do
    command -v "$tool" >/dev/null || { echo "Missing $tool. Install Xcode and run: brew install xcodegen cmake"; exit 1; }
done
bash scripts/prepare-llama.sh
xcodegen generate
printf '%s\n' 'Ready: open Souchastnik.xcodeproj'
