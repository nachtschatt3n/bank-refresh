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

echo "Bundle smoke test passed"

# ── Metrics endpoint test ────────────────────────────────────────────────────

"$EXECUTABLE_PATH" &
APP_PID=$!

cleanup() {
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for the app and metrics server to start
sleep 3

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 http://localhost:9100/health)
if [ "$HTTP_CODE" != "200" ]; then
    echo "FAIL: /health returned $HTTP_CODE, expected 200"
    exit 1
fi

METRICS=$(curl -s --connect-timeout 5 http://localhost:9100/metrics)

echo "$METRICS" | grep -q 'bank_refresh_up 1' || { echo "FAIL: missing bank_refresh_up"; exit 1; }
echo "$METRICS" | grep -q '# TYPE bank_refresh_state gauge' || { echo "FAIL: missing state TYPE"; exit 1; }
echo "$METRICS" | grep -q 'bank_refresh_state{state="idle"} 1' || { echo "FAIL: missing idle state"; exit 1; }

echo "Metrics endpoint test passed"
echo "All tests passed"
