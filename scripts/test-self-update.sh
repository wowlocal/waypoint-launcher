#!/bin/zsh
# End-to-end check of Waypoint's self-update: builds an "old" and a "new"
# Developer ID-signed copy under a throwaway bundle id, serves a Sparkle
# appcast from localhost, runs the old copy hidden, and checks that Sparkle
# downloads the update silently and installs it when the app quits.
#
# Needs the Developer ID identity and the Sparkle key (account "waypoint").
# Doesn't touch the real Waypoint, its settings, or any game.
set -euo pipefail
cd "${0:A:h}/.."

step() { print -P "%F{cyan}==>%f $*" }
fail() { print -P "%F{red}FAIL:%f $*" >&2; exit 1 }

bundle_id="dev.waypoint.launcher.updatetest"
port=$(( 20000 + RANDOM % 20000 ))
feed="http://127.0.0.1:$port/appcast.xml"
work="$(mktemp -d)"
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | awk 'NR == 1')}"
[[ -n "$identity" ]] || fail "no Developer ID Application identity"
installed="$work/Applications/Waypoint.app"
server_pid=""

cleanup() {
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
    sleep 1 # let the quitting app's last preference writes land before deleting them
    defaults delete "$bundle_id" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Caches/$bundle_id" "$HOME/Library/HTTPStorages/$bundle_id" "$work"
}
trap cleanup EXIT

step "Building old (0.0.1) and new (0.0.2) copies"
for v n in 0.0.1 1 0.0.2 2; do
    APP_PATH="$work/build-$n/Waypoint.app" VERSION="$v" BUILD_NUMBER="$n" BUNDLE_ID="$bundle_id" \
        SPARKLE_FEED="$feed" SIGN_IDENTITY="$identity" scripts/bundle.sh | tail -1
done

step "Publishing 0.0.2 on a local feed"
mkdir -p "$work/feed" "$work/Applications"
hdiutil create -quiet -volname "Waypoint 0.0.2" -srcfolder "$work/build-2" -fs HFS+ -format UDZO "$work/feed/Waypoint-0.0.2.dmg"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --account waypoint --maximum-deltas 0 \
    --download-url-prefix "http://127.0.0.1:$port/" -o "$work/feed/appcast.xml" "$work/feed"
(cd "$work/feed" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
server_pid=$!
for _ in {1..50}; do curl -fs "$feed" >/dev/null && break; sleep 0.1; done
curl -fs "$feed" | grep -q 'sparkle:edSignature' || fail "feed not served"

step "Running 0.0.1 hidden; Sparkle should download the update by itself"
ditto "$work/build-1/Waypoint.app" "$installed"
open -g -j -n "$installed"
# Once the update is downloaded and staged, Sparkle starts its installer and
# it waits for the app to quit.
for i in {1..90}; do
    pgrep -f "$bundle_id.*Autoupdate|Autoupdate.*$bundle_id" >/dev/null && break
    pgrep -fl Autoupdate 2>/dev/null | grep -q "$bundle_id" && break
    [[ -d "$HOME/Library/Caches/$bundle_id/org.sparkle-project.Sparkle/Installation" ]] && break
    sleep 1
done
[[ -d "$HOME/Library/Caches/$bundle_id/org.sparkle-project.Sparkle" ]] || fail "Sparkle never downloaded the update"
sleep 3

step "Quitting; Sparkle installs on quit"
osascript -e "tell application id \"$bundle_id\" to quit"
for i in {1..60}; do
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$installed/Contents/Info.plist" 2>/dev/null)" == "0.0.2" ]] && break
    sleep 1
done
new_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$installed/Contents/Info.plist")"
[[ "$new_version" == "0.0.2" ]] || fail "still $new_version after quitting"
codesign --verify --deep --strict "$installed" || fail "updated app's signature is invalid"
pgrep -f "$installed/Contents/MacOS/Waypoint" >/dev/null && fail "Sparkle relaunched the app; install-on-quit should stay quiet"
print -P "%F{green}PASS:%f 0.0.1 updated itself to 0.0.2 in the background and installed on quit"
