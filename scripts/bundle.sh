#!/bin/zsh
# Builds build/Waypoint.app (arm64).
#
#   APP_PATH       where to put the app (default: build/Waypoint.app)
#   VERSION        marketing version (default: latest v* tag, else 0.1.0)
#   BUILD_NUMBER   CFBundleVersion, what Sparkle compares (default: commit count)
#   SIGN_IDENTITY  codesign identity (default: ad-hoc "-"). A real identity
#                  also enables the hardened runtime and a secure timestamp,
#                  which notarization requires.
#   SPARKLE_FEED   appcast URL for self-updates. Defaults to the GitHub
#                  release feed for signed builds; ad-hoc builds get none, so
#                  development copies never replace themselves.
#   BUNDLE_ID      bundle identifier (default: dev.waypoint.launcher)
#
# Uses Xcode's toolchain: open-source toolchains may not match the installed SDK.
set -euo pipefail
cd "${0:A:h}/.."

latest_tag="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
version="${VERSION:-${${latest_tag#v}:-0.1.0}}"
build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
identity="${SIGN_IDENTITY:--}"
bundle_id="${BUNDLE_ID:-dev.waypoint.launcher}"
if [[ -z "${SPARKLE_FEED+set}" && "$identity" != "-" ]]; then
    feed="https://github.com/wowlocal/waypoint-launcher/releases/latest/download/appcast.xml"
else
    feed="${SPARKLE_FEED:-}"
fi
# Public half of the EdDSA key that signs updates; the private half lives in
# the release machine's keychain (generate_keys --account waypoint).
sparkle_public_key="mfL3STHC28BUAVXlUOjMVv0pZ8noAtFWM115ekfpbsg="

nice -n 19 xcrun swift build -c release --arch arm64 --product Waypoint
bin_dir="$(xcrun swift build -c release --arch arm64 --show-bin-path)"

app="${APP_PATH:-build/Waypoint.app}"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin_dir/Waypoint" "$app/Contents/MacOS/Waypoint"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Waypoint"

# Sparkle. Its XPC services exist for sandboxed apps; Waypoint isn't one.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
ditto "$bin_dir/Sparkle.framework" "$sparkle"
rm -rf "$sparkle/Versions/B/XPCServices" "$sparkle/XPCServices"

sparkle_keys="    <key>SUPublicEDKey</key><string>${sparkle_public_key}</string>"
if [[ -n "$feed" ]]; then
    # Check, download and install without asking; Waypoint shows progress
    # inline and installs on quit (see AppUpdater.swift).
    sparkle_keys+="
    <key>SUFeedURL</key><string>${feed}</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
    <key>SUScheduledCheckInterval</key><integer>14400</integer>"
fi

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Waypoint</string>
    <key>CFBundleIdentifier</key><string>${bundle_id}</string>
    <key>CFBundleName</key><string>Waypoint</string>
    <key>CFBundleDisplayName</key><string>Waypoint</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundleVersion</key><string>${build_number}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
${sparkle_keys}
</dict>
</plist>
PLIST
plutil -lint -s "$app/Contents/Info.plist"

# Sign inside out: Sparkle's helpers, the framework, then the app.
sign() {
    if [[ "$identity" == "-" ]]; then
        codesign --force --sign - "$@"
    else
        codesign --force --sign "$identity" --options runtime --timestamp "$@"
    fi
}
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign "$app"
codesign --verify --deep --strict "$app"
echo "Built $app $version ($build_number, $(lipo -archs "$app/Contents/MacOS/Waypoint"), signed: $identity, feed: ${feed:-none})"
