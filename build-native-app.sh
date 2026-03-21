#!/bin/zsh
set -euo pipefail

ROOT="/Users/mu/code/bank-refresh"
APP_NAME="RefreshMoneyMoney"
APP_DIR="$ROOT/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_DIR="$ROOT/.build"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR"

cp "$ROOT/native-wrapper/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT/refresh-moneymoney.applescript" "$RESOURCES_DIR/refresh-moneymoney.applescript"

xcrun swiftc \
	-target arm64-apple-macos13.0 \
	-framework AppKit \
	-module-cache-path "$MODULE_CACHE_DIR" \
	-o "$MACOS_DIR/$APP_NAME" \
	"$ROOT/native-wrapper/main.swift"

codesign --force --sign - "$APP_DIR"

echo "Built $APP_DIR"
