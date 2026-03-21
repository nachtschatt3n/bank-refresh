#!/bin/zsh
set -euo pipefail

ROOT="/Users/mu/code/bank-refresh"
APP_PATH="$ROOT/RefreshMoneyMoney.app"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
RESOURCE_PATH="$APP_PATH/Contents/Resources/refresh-moneymoney.applescript"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/RefreshMoneyMoney"

"$ROOT/build-native-app.sh" >/dev/null

test -d "$APP_PATH"
test -f "$INFO_PLIST"
test -f "$RESOURCE_PATH"
test -x "$EXECUTABLE_PATH"

plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST" | grep -qx 'com.mathiasuhl.refreshmoneymoney'
plutil -extract LSUIElement raw -o - "$INFO_PLIST" | grep -qx 'true'

echo "Smoke test passed"
