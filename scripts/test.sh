#!/bin/sh
# Command Line Tools ship the Swift Testing macro plugin outside the default search path.
set -e
cd "$(dirname "$0")/.."
if [ -z "$DEVELOPER_DIR" ] && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  exec swift test "$@"
fi
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
