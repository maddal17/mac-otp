#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
MODULES_DIR="$BUILD_DIR/modules"
BIN_DIR="$BUILD_DIR/bin"
DIST_APP="$ROOT_DIR/dist/MacOTP.app"

SWIFTC="$(xcrun --find swiftc)"
SDK_PATH="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
COMMON_FLAGS=(-O -whole-module-optimization -swift-version 6 -target "${ARCH}-apple-macosx14.0" -sdk "$SDK_PATH")

mkdir -p "$MODULES_DIR" "$BIN_DIR" "$ROOT_DIR/dist"

echo "[1/5] Building MacOTPCore static library & module..."
"$SWIFTC" "${COMMON_FLAGS[@]}" \
    -emit-library -static \
    -emit-module \
    -module-name MacOTPCore \
    -emit-module-path "$MODULES_DIR/MacOTPCore.swiftmodule" \
    -o "$BUILD_DIR/libMacOTPCore.a" \
    "$ROOT_DIR"/Sources/MacOTPCore/*.swift

echo "[2/5] Building MacOTPApp (Menu Bar GUI + Core Daemon)..."
"$SWIFTC" "${COMMON_FLAGS[@]}" \
    -I "$MODULES_DIR" \
    "$BUILD_DIR/libMacOTPCore.a" \
    "$ROOT_DIR"/Sources/MacOTPApp/*.swift \
    -o "$BIN_DIR/MacOTPApp"

echo "[3/5] Building mac-otp-mcp (MCP Stdio Bridge)..."
"$SWIFTC" "${COMMON_FLAGS[@]}" \
    -I "$MODULES_DIR" \
    "$BUILD_DIR/libMacOTPCore.a" \
    "$ROOT_DIR"/Sources/MacOTPMCP/*.swift \
    -o "$BIN_DIR/mac-otp-mcp"

echo "[4/5] Packaging & ad-hoc signing dist/MacOTP.app..."
rm -rf "$DIST_APP"
mkdir -p "$DIST_APP/Contents/MacOS" "$DIST_APP/Contents/Resources"
cp "$ROOT_DIR/Resources/Info.plist" "$DIST_APP/Contents/Info.plist"
cp "$BIN_DIR/MacOTPApp" "$DIST_APP/Contents/MacOS/MacOTPApp"
cp "$BIN_DIR/mac-otp-mcp" "$DIST_APP/Contents/MacOS/mac-otp-mcp"
chmod +x "$DIST_APP/Contents/MacOS/MacOTPApp" "$DIST_APP/Contents/MacOS/mac-otp-mcp"

codesign --force --sign - "$DIST_APP/Contents/MacOS/mac-otp-mcp"
codesign --force --deep --sign - "$DIST_APP"

echo "[5/5] Building & running automated verification suite..."
"$SWIFTC" "${COMMON_FLAGS[@]}" \
    -parse-as-library \
    -I "$MODULES_DIR" \
    "$BUILD_DIR/libMacOTPCore.a" \
    "$ROOT_DIR"/Tests/MacOTPCoreTests/*.swift \
    -o "$BIN_DIR/mac-otp-tests"

"$BIN_DIR/mac-otp-tests"

echo ""
echo "Build complete:"
echo "  App Bundle : $DIST_APP"
echo "  MCP Binary : $DIST_APP/Contents/MacOS/mac-otp-mcp"
