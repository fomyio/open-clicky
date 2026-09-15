#!/bin/bash
#
# Builds OpenClicky.app.
#
# SwiftPM produces a bare executable, but macOS grants Accessibility and Screen
# Recording to *bundles* — a loose binary gets re-prompted on every rebuild and
# cannot carry the usage strings the system shows in those prompts. So the binary
# is wrapped in a real bundle and signed with a *stable* identity.
#
# Stable is the operative word, and this script used to claim it while doing the
# opposite. An ad-hoc signature's cdhash is computed from the binary's contents, and
# TCC keys an ad-hoc app's grants to that cdhash — so every rebuild was a different
# app to macOS and silently dropped both Accessibility and Screen Recording. Three
# separate attempts to verify a fix died on it, each looking like the fix had failed.
# A real certificate gives a designated requirement based on the team, which survives
# a rebuild.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The version has one definition, in Sources/OpenClickyKit/Support/Version.swift, so
# the app bundle and `openclicky --version` cannot disagree about which build this is.
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' \
    Sources/OpenClickyKit/Support/Version.swift)
if [ -z "$VERSION" ]; then
    echo "Could not read the version from Sources/OpenClickyKit/Support/Version.swift" >&2
    exit 1
fi
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
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
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

    <!-- Unlike the three above, this one is not best-effort: an app that touches the
         microphone without declaring a purpose string is *terminated* by macOS, not
         merely denied. So a voice session without this line does not degrade — the
         whole app disappears the first time someone starts one. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>OpenClicky listens so you can speak instructions and interrupt it while it works.</string>
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

# Prefer a real certificate; fall back to ad-hoc and say plainly what that costs.
#
# Developer ID before Apple Development: the second expires yearly and is tied to a
# provisioning profile, and a signing identity that stops working in twelve months
# reintroduces exactly the problem this is here to remove.
IDENTITY="${OPENCLICKY_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
fi

if [ -n "$IDENTITY" ]; then
    echo "==> Signing as $IDENTITY"
else
    IDENTITY="-"
    echo "==> Signing (ad-hoc — no certificate found)"
    echo "    WARNING: TCC keys an ad-hoc app's grants to its cdhash, which changes on"
    echo "    every rebuild. Accessibility and Screen Recording will be dropped each"
    echo "    time you run this, and tier 2 and tier 3 will fail until you re-grant."
    echo "    Set OPENCLICKY_SIGN_IDENTITY, or install a Developer ID certificate."
fi

codesign --force --deep --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    --entitlements "$ROOT/Scripts/OpenClicky.entitlements" \
    "$APP" 2>&1 | sed 's/^/    /'

# A real signature check, after signing rather than before it.
codesign --verify --deep --strict "$APP" || { echo "FAIL: signature does not verify"; exit 1; }
echo "    signature verifies"

# The entitlement is what keeps tier 1 alive under the hardened runtime, and a
# `--entitlements` flag that silently failed to apply looks exactly like success.
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null \
    | grep -q "com.apple.security.automation.apple-events" \
    || { echo "FAIL: the Apple Events entitlement did not apply; app_script would break"; exit 1; }
echo "    Apple Events entitlement present"

# Printed because it is the thing that determines whether grants survive: a team
# identifier means they do, "not set" means this is ad-hoc and they do not.
codesign -dv "$APP" 2>&1 | grep -E "TeamIdentifier|Signature" | sed 's/^/    /'

echo
echo "Built $APP"
echo
echo "Next:"
echo "  open $APP                 # launch (menu bar icon, ⌥space to summon)"
echo "  $APP/Contents/Helpers/openclicky doctor"
echo
echo "Grant Accessibility and Screen Recording to OpenClicky in"
echo "System Settings > Privacy & Security. The first run will ask."
echo
echo "Changing the signing identity changes the app's identity, so the first build"
echo "after that switch drops any existing grants once more. Re-grant, and from then"
echo "on a rebuild keeps them."
