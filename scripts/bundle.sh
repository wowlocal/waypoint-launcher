#!/bin/zsh
# Builds build/Waypoint.app (arm64).
#
#   APP_PATH       where to put the app (default: build/Waypoint.app)
#   VERSION        marketing version (default: latest v* tag, else 0.1.0)
#   BUILD_NUMBER   CFBundleVersion, what Sparkle compares (default: commit count)
#   SIGN_IDENTITY  codesign identity (default: ad-hoc "-"). A real identity
#                  also enables the hardened runtime and a secure timestamp,
#                  which notarization requires.
#   SPARKLE_FEED   appcast URL for self-updates. Defaults to the release feed
#                  on S3 for signed builds (see release.sh); ad-hoc builds get
#                  none, so development copies never replace themselves.
#   BUNDLE_ID      bundle identifier (default: dev.waypoint.launcher)
#   WINDOWS_RUNTIME signed download descriptor directory (default:
#                  build/windows-runtime-release/distribution if present).
#                  A staged full runtime remains supported for local builds.
#                  Set to "none" to omit Windows HotS support.
#   WINDOWS_EXPERIMENTAL=1 isolates a development build with a separate
#                  bundle identifier and no public update feed. Public Windows
#                  Overwatch and Diablo profiles retain Preview labels.
#
# Uses Xcode's toolchain: open-source toolchains may not match the installed SDK.
set -euo pipefail
cd "${0:A:h}/.."

latest_tag="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
version="${VERSION:-${${latest_tag#v}:-0.1.0}}"
build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
identity="${SIGN_IDENTITY:--}"
if [[ "${WINDOWS_EXPERIMENTAL:-0}" == "1" ]]; then
    bundle_id="${BUNDLE_ID:-dev.waypoint.windows-preview}"
else
    bundle_id="${BUNDLE_ID:-dev.waypoint.launcher}"
fi
if [[ -z "${SPARKLE_FEED+set}" && "$identity" != "-" && "${WINDOWS_EXPERIMENTAL:-0}" != "1" ]]; then
    feed="https://storage.yandexcloud.net/macos-releases/waypoint/appcast.xml"
else
    feed="${SPARKLE_FEED:-}"
fi
if [[ "${WINDOWS_EXPERIMENTAL:-0}" == "1" && "$feed" == "https://storage.yandexcloud.net/macos-releases/waypoint/appcast.xml" ]]; then
    print -u2 "Experimental builds cannot use the production Sparkle feed"
    exit 1
fi
# Public half of the EdDSA key that signs updates; the private half lives in
# the release machine's keychain (generate_keys --account waypoint).
sparkle_public_key="mfL3STHC28BUAVXlUOjMVv0pZ8noAtFWM115ekfpbsg="

swift_flags=()
[[ "${WINDOWS_EXPERIMENTAL:-0}" != "1" ]] || swift_flags=(-Xswiftc -DWAYPOINT_WINDOWS_EXPERIMENTAL)
nice -n 19 xcrun swift build -c release --arch arm64 --product Waypoint "${swift_flags[@]}"
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
windows_experimental=""
if [[ "${WINDOWS_EXPERIMENTAL:-0}" == "1" ]]; then
    windows_experimental="    <key>WaypointWindowsExperimental</key><true/>"
fi
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
    <key>NSMicrophoneUsageDescription</key><string>Windows games use the microphone for in-game voice chat.</string>
    <!-- Installs and updates allocate big buffers; malloc's large cache would
         keep them dirty after they're freed (80 MB vs 6 MB idle afterwards). -->
    <key>LSEnvironment</key><dict><key>MallocLargeCache</key><string>0</string></dict>
${windows_experimental}
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
windows_runtime="${WINDOWS_RUNTIME:-build/windows-runtime-release/distribution}"
if [[ "$windows_runtime" != "none" && -f "$windows_runtime/distribution.json" ]]; then
    mkdir -p "$app/Contents/Resources/WindowsRuntime"
    cp "$windows_runtime/distribution.json" "$app/Contents/Resources/WindowsRuntime/distribution.json"
    [[ ! -f "$windows_runtime/Credits.html" ]] || cp "$windows_runtime/Credits.html" "$app/Contents/Resources/Credits.html"
elif [[ "$windows_runtime" != "none" && -d "$windows_runtime" ]]; then
    mkdir -p "$app/Contents/SharedSupport"
    ditto "$windows_runtime" "$app/Contents/SharedSupport/Windows"
    python3 scripts/sign-wine-runtime.py "$app/Contents/SharedSupport/Windows" --identity "$identity"
elif [[ -n "${WINDOWS_RUNTIME:-}" && "$windows_runtime" != "none" ]]; then
    print -u2 "Windows runtime not found: $windows_runtime"
    exit 1
fi
if [[ -d "$app/Contents/SharedSupport/Windows" || -d "$app/Contents/Resources/WindowsRuntime" ]]; then
    # The per-title bridge is small and independent of the cached Wine engine.
    scripts/build-windows-helper.sh build/windows-bridge --titles
    mkdir -p "$app/Contents/Resources/WindowsBridge"
    cp build/windows-bridge/waypoint-launch-options.exe "$app/Contents/Resources/WindowsBridge/"
    python3 - "$app/Contents/Resources/WindowsBridge" <<'PYBRIDGE'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);h=hashlib.sha256((p/"waypoint-launch-options.exe").read_bytes()).hexdigest()
(p/"manifest.json").write_text(json.dumps({"schema":2,"sha256":h},indent=2)+"\n")
PYBRIDGE
    python3 - <<'PYGRAPHICS'
import hashlib,json,pathlib
p=pathlib.Path("Resources/WindowsGraphics")
assert {x.name for x in p.iterdir()}=={"manifest.json","License.rtf"}, "Unexpected graphics resources; do not bundle third-party binaries"
m=json.loads((p/"manifest.json").read_text())
assert hashlib.sha256((p/"License.rtf").read_bytes()).hexdigest()==m["files"]["License.rtf"], "Graphics license differs from the pinned component"
PYGRAPHICS
    mkdir -p "$app/Contents/Resources/WindowsGraphics"
    cp Resources/WindowsGraphics/manifest.json Resources/WindowsGraphics/License.rtf "$app/Contents/Resources/WindowsGraphics/"
    sign --entitlements tools/wine-runtime/waypoint.entitlements "$app"
else
    sign "$app"
fi
codesign --verify --deep --strict "$app"
echo "Built $app $version ($build_number, $(lipo -archs "$app/Contents/MacOS/Waypoint"), signed: $identity, feed: ${feed:-none})"
