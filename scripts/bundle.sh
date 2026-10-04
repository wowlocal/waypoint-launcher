#!/bin/zsh
# Builds build/Waypoint.app (arm64, ad-hoc signed).
# Uses Xcode's toolchain: open-source toolchains may not match the installed SDK.
set -euo pipefail
cd "${0:A:h}/.."

nice -n 19 xcrun swift build -c release --arch arm64 --product Waypoint
bin="$(xcrun swift build -c release --arch arm64 --show-bin-path)/Waypoint"

app=build/Waypoint.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Waypoint"
version="$(git describe --tags --always 2>/dev/null || echo 0.1.0)"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Waypoint</string>
    <key>CFBundleIdentifier</key><string>dev.waypoint.launcher</string>
    <key>CFBundleName</key><string>Waypoint</string>
    <key>CFBundleDisplayName</key><string>Waypoint</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>${version}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "Built $app ($(lipo -archs "$app/Contents/MacOS/Waypoint"))"
