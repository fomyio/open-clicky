#!/bin/bash
#
# Builds OpenClicky.app.
#
# SwiftPM produces a bare executable, but macOS grants Accessibility and Screen
# Recording to *bundles* — a loose binary gets re-prompted on every rebuild and
# cannot carry the usage strings the system shows in those prompts. So the binary
# is wrapped in a real bundle, ad-hoc signed to give TCC a stable identity.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/OpenClicky.app"
BUNDLE_ID="com.openclicky.app"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product OpenClickyApp
swift build -c "$CONFIGURATION" --product openclicky
BINARY_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BINARY_DIR/OpenClickyApp" "$APP/Contents/MacOS/OpenClicky"
# The CLI goes in Helpers/, not MacOS/: on a case-insensitive volume "openclicky"
# and "OpenClicky" are the same path, so putting both in MacOS/ silently leaves
# whichever was copied second and the bundle launches the wrong binary.
cp "$BINARY_DIR/openclicky" "$APP/Contents/Helpers/openclicky"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>OpenClicky</string>
    <key>CFBundleDisplayName</key>       <string>OpenClicky</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>OpenClicky</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>

    <!-- Menu-bar only: no Dock icon, no app-switcher entry. -->
    <key>LSUIElement</key><true/>

    <!-- Only NSAppleEventsUsageDescription is known to be shown: macOS displays it
         in the Automation consent dialog, and shipping apps rely on it. The other two
         are best-effort — Accessibility and Screen Recording prompts do not appear to
         render app-supplied text, so neither the app nor the CLI depends on them:
         both explain what they need before requesting it. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>OpenClicky controls scriptable apps with AppleScript, which is faster and more reliable than clicking.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>OpenClicky reads window contents and clicks and types on your behalf.</string>
    <key>NSSystemAdministrationUsageDescription</key>
    <string>OpenClicky runs shell commands you approve.</string>
</dict>
</plist>
PLIST

echo "==> Verifying"
# The case-insensitivity trap above failed silently once; assert rather than trust.
ACTUAL="$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")"
test -x "$APP/Contents/MacOS/$ACTUAL" || { echo "FAIL: CFBundleExecutable '$ACTUAL' is not in MacOS/"; exit 1; }
cmp -s "$BINARY_DIR/OpenClickyApp" "$APP/Contents/MacOS/OpenClicky" \
    || { echo "FAIL: MacOS/OpenClicky is not the app binary"; exit 1; }
test -x "$APP/Contents/Helpers/openclicky" || { echo "FAIL: CLI missing"; exit 1; }
plutil -lint "$APP/Contents/Info.plist" >/dev/null || exit 1
echo "    executable, CLI and Info.plist all present and correct"

echo "==> Signing (ad-hoc)"
# A stable identity so TCC grants survive rebuilds; ad-hoc is enough for local use.
codesign --force --deep --sign - \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    "$APP" 2>&1 | sed 's/^/    /'

# A real signature check, after signing rather than before it.
codesign --verify --deep --strict "$APP" || { echo "FAIL: signature does not verify"; exit 1; }
echo "    signature verifies"

echo
echo "Built $APP"
echo
echo "Next:"
echo "  open $APP                 # launch (menu bar icon, ⌥space to summon)"
echo "  $APP/Contents/Helpers/openclicky doctor"
echo
echo "Grant Accessibility and Screen Recording to OpenClicky in"
echo "System Settings > Privacy & Security. The first run will ask."
