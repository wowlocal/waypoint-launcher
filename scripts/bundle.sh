#!/bin/zsh
# Builds build/Waypoint.app (arm64).
#
#   APP_PATH       where to put the app (default: build/Waypoint.app)
#   VERSION        marketing version (default: latest v* tag, else 0.1.0)
#   SIGN_IDENTITY  codesign identity (default: ad-hoc "-"). A real identity
#                  also enables the hardened runtime and a secure timestamp,
#                  which notarization requires.
#
# Uses Xcode's toolchain: open-source toolchains may not match the installed SDK.
set -euo pipefail
cd "${0:A:h}/.."

latest_tag="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
version="${VERSION:-${${latest_tag#v}:-0.1.0}}"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
identity="${SIGN_IDENTITY:--}"

nice -n 19 xcrun swift build -c release --arch arm64 --product Waypoint
bin="$(xcrun swift build -c release --arch arm64 --show-bin-path)/Waypoint"

app="${APP_PATH:-build/Waypoint.app}"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Waypoint"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Waypoint</string>
    <key>CFBundleIdentifier</key><string>dev.waypoint.launcher</string>
    <key>CFBundleName</key><string>Waypoint</string>
    <key>CFBundleDisplayName</key><string>Waypoint</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundleVersion</key><string>${build_number}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ "$identity" == "-" ]]; then
    codesign --force --sign - "$app"
else
    codesign --force --sign "$identity" --options runtime --timestamp "$app"
fi
echo "Built $app $version ($build_number, $(lipo -archs "$app/Contents/MacOS/Waypoint"), signed: $identity)"
