#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/app"
OUTPUT_DIR="${1:-$PROJECT_DIR/dist}"
APP_DIR="$OUTPUT_DIR/BTC Price.app"
mkdir -p "$BUILD_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

for ARCH in arm64 x86_64; do
    ARCH_DIR="$BUILD_DIR/$ARCH"
    mkdir -p "$ARCH_DIR"
    xcrun swiftc -parse-as-library -O -whole-module-optimization -target "$ARCH-apple-macosx13.0" \
        -module-cache-path "$BUILD_DIR/ModuleCache" \
        -emit-library -static -emit-module -module-name BTCPriceCore \
        -emit-module-path "$ARCH_DIR/BTCPriceCore.swiftmodule" \
        "$PROJECT_DIR"/Sources/BTCPriceCore/*.swift \
        -o "$ARCH_DIR/libBTCPriceCore.a"
    xcrun swiftc -parse-as-library -O -whole-module-optimization -target "$ARCH-apple-macosx13.0" \
        -module-cache-path "$BUILD_DIR/ModuleCache" \
        -I "$ARCH_DIR" -L "$ARCH_DIR" -lBTCPriceCore \
        -framework AppKit \
        "$PROJECT_DIR"/Sources/BTCPrice/*.swift \
        -o "$ARCH_DIR/BTCPrice"
done

xcrun lipo -create "$BUILD_DIR/arm64/BTCPrice" "$BUILD_DIR/x86_64/BTCPrice" -output "$APP_DIR/Contents/MacOS/BTCPrice"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
codesign --force --sign - --identifier local.BTCPrice "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "Built: $APP_DIR"
