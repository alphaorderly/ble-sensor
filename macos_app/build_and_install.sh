#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="EnvSensorWidget"
EXT_NAME="EnvSensorWidgetExtension"
INSTALL_APP="/Applications/${APP_NAME}.app"
INSTALL_EXT="${INSTALL_APP}/Contents/PlugIns/${EXT_NAME}.appex"
DERIVED_DATA="/tmp/EnvSensorWidgetDerivedData"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

cd "$SCRIPT_DIR"

echo "[1/6] Generating native AppIcon.icns..."
ICONSET_DIR="/tmp/EnvSensorWidgetAppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

swift - "$ICONSET_DIR" <<'SWIFT'
import AppKit
import Foundation

let outDir = CommandLine.arguments[1]
let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(px),
        pixelsHigh: Int(px),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let inset = px * 0.08
    let cardRect = rect.insetBy(dx: inset, dy: inset)
    let radius = px * 0.22
    let bgPath = NSBezierPath(roundedRect: cardRect, xRadius: radius, yRadius: radius)

    let grad = NSGradient(
        starting: NSColor(calibratedRed: 0.11, green: 0.16, blue: 0.24, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.14, alpha: 1.0)
    )!
    grad.draw(in: bgPath, angle: -90)

    NSColor(calibratedWhite: 1.0, alpha: 0.16).setStroke()
    bgPath.lineWidth = max(1, px * 0.015)
    bgPath.stroke()

    if let sym = NSImage(systemSymbolName: "aqi.medium", accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: px * 0.44, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [
                NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.58, alpha: 1.0)
            ]))
        if let styled = sym.withSymbolConfiguration(cfg) {
            let s = styled.size
            let drawRect = NSRect(
                x: (px - s.width) / 2.0,
                y: (px - s.height) / 2.0,
                width: s.width,
                height: s.height
            )
            styled.draw(in: drawRect)
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: "\(outDir)/\(filename)"))
}
SWIFT

iconutil -c icns "$ICONSET_DIR" -o "$SCRIPT_DIR/EnvSensorHostApp/AppIcon.icns"
rm -rf "$ICONSET_DIR"

echo "[2/6] Generating Xcode project via XcodeGen..."
xcodegen generate

echo "[3/6] Building Release app & WidgetKit extension in temporary DerivedData..."
rm -rf "$DERIVED_DATA"
xcodebuild \
  -project "$SCRIPT_DIR/${APP_NAME}.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "ERROR: Built app not found at $BUILT_APP" >&2
  exit 1
fi

echo "[4/6] Installing exclusively to $INSTALL_APP and removing temporary build products..."
killall "$APP_NAME" 2>/dev/null || true
rm -rf "$INSTALL_APP"
cp -R "$BUILT_APP" "$INSTALL_APP"
rm -rf "$DERIVED_DATA"

echo "[5/6] Signing extension and host app inside-out ($SIGN_IDENTITY)..."
codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements "$SCRIPT_DIR/EnvSensorWidgetExtension/EnvSensorWidgetExtension.entitlements" \
  "$INSTALL_EXT"

codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements "$SCRIPT_DIR/EnvSensorHostApp/EnvSensorHostApp.entitlements" \
  "$INSTALL_APP"

xattr -cr "$INSTALL_APP" 2>/dev/null || true

echo "[6/6] Registering app and WidgetKit extension with LaunchServices, PlugInKit & chronod..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_APP"
pluginkit -a "$INSTALL_EXT"
pluginkit -e use -i "io.github.alphaorderly.EnvSensorWidget.Widget"
open "$INSTALL_APP"
sleep 2
killall chronod 2>/dev/null || true

echo "Done! Installed exclusively at: $INSTALL_APP"
