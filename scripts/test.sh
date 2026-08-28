#!/bin/sh
# Runs the test suite. Swift Testing needs the `TestingMacros` plugin, which the Command Line
# Tools toolchain lacks; when only the CLT is selected, point DEVELOPER_DIR at an installed Xcode.
set -eu
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
  for app in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -d "$app/Contents/Developer" ]; then
      export DEVELOPER_DIR="$app/Contents/Developer"
      break
    fi
  done
fi
exec swift test "$@"
