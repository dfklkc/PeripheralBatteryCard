#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="外设电量卡片.app"
VERSION=1.0.1
BUILD_VERSION=101
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

BINARIES=()
for arch in arm64 x86_64; do
  echo "==> Building PeripheralBatteryCard ($arch)..."
  BUILD_ARGS=(--configuration release --triple "$arch-apple-macosx14.0"
    --scratch-path "$ROOT_DIR/.build/release-$arch"
    -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=.")
  swift build "${BUILD_ARGS[@]}"
  BIN_DIR=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)
  BINARIES+=("$BIN_DIR/PeripheralBatteryCard")
done
lipo -create "${BINARIES[@]}" -output "$MACOS_DIR/PeripheralBatteryCard"
lipo "$MACOS_DIR/PeripheralBatteryCard" -verify_arch arm64 x86_64

# 生成矢量级 1024x1024 应用图标并转换为 AppIcon.icns
ICON_WORK="$ROOT_DIR/.build/icon_tmp"
ICONSET_DIR="$ICON_WORK/AppIcon.iconset"
BASE_PNG="$ICON_WORK/icon_1024.png"
rm -rf "$ICON_WORK"
mkdir -p "$ICONSET_DIR"

swift - "$BASE_PNG" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

let outPath = CommandLine.arguments[1]
let size = 1024
let rect = CGRect(x: 0, y: 0, width: size, height: size)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

// macOS 圆角矩形画布
let iconRect = rect.insetBy(dx: 76, dy: 76)
let bgPath = NSBezierPath(roundedRect: iconRect, xRadius: 196, yRadius: 196)
bgPath.addClip()

let colors = [
    NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.18, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.06, green: 0.19, blue: 0.22, alpha: 1.0).cgColor
] as CFArray
let space = CGColorSpaceCreateDeviceRGB()
let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0.0, 1.0])!
cg.drawLinearGradient(
    grad,
    start: CGPoint(x: iconRect.minX, y: iconRect.maxY),
    end: CGPoint(x: iconRect.maxX, y: iconRect.minY),
    options: []
)

// 内边框高光
NSColor.white.withAlphaComponent(0.16).setStroke()
bgPath.lineWidth = 6
bgPath.stroke()

// 环形电量进度环
let center = CGPoint(x: size / 2, y: size / 2)
let radius: CGFloat = 258
let trackPath = NSBezierPath()
trackPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
trackPath.lineWidth = 54
NSColor.white.withAlphaComponent(0.12).setStroke()
trackPath.stroke()

let arcPath = NSBezierPath()
arcPath.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: -195, clockwise: true)
arcPath.lineCapStyle = .round
arcPath.lineWidth = 54
NSColor(calibratedRed: 0.22, green: 0.87, blue: 0.56, alpha: 1.0).setStroke()
arcPath.stroke()

// 中心闪电/外设符号
if let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 210, weight: .bold)) {
    let tinted = NSImage(size: symbol.size, flipped: false) { drawRect in
        NSColor(calibratedRed: 0.36, green: 0.94, blue: 0.66, alpha: 1.0).set()
        symbol.draw(in: drawRect)
        drawRect.fill(using: .sourceAtop)
        return true
    }
    let s = tinted.size
    tinted.draw(
        in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height),
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
    )
}

NSGraphicsContext.restoreGraphicsState()
let pngData = rep.representation(using: .png, properties: [:])!
try pngData.write(to: URL(fileURLWithPath: outPath))
SWIFT

for sz in 16 32 128 256 512; do
  sips -z "$sz" "$sz" "$BASE_PNG" --out "$ICONSET_DIR/icon_${sz}x${sz}.png" >/dev/null
  double=$((sz * 2))
  sips -z "$double" "$double" "$BASE_PNG" --out "$ICONSET_DIR/icon_${sz}x${sz}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$ICON_WORK"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>外设电量卡片</string>
	<key>CFBundleExecutable</key>
	<string>PeripheralBatteryCard</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.peripheralbattery.card</string>
	<key>CFBundleName</key>
	<string>外设电量卡片</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>用于读取已连接蓝牙低功耗（BLE）外设的标准电量服务（0x180F）。</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing $APP_DIR..."
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

ARCHIVE="PeripheralBatteryCard-v$VERSION-macOS-universal.zip"
rm -f "$DIST_DIR/$ARCHIVE"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP_DIR" "$DIST_DIR/$ARCHIVE"
(cd "$DIST_DIR" && shasum -a 256 "$ARCHIVE" > SHA256SUMS.txt)

echo "==> Built successfully: $APP_DIR and $DIST_DIR/$ARCHIVE"
