#!/bin/zsh
# Runs the test suite. With only the Command Line Tools installed (no Xcode), swift-testing's
# macro plugin is not always found on its own, so its folder is passed explicitly when present.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "$PLUGINS" ]]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  swift test "$@"
fi
