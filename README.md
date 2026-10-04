<div align="center">

<img src="Resources/AppIcon.png" width="128" alt="Waypoint icon">

# Waypoint

**A bloat-free version of Battle.net for Apple Silicon Macs.**<br>
Install, update and launch Blizzard games without the Battle.net app. No Rosetta. Just press Play.

[![Latest release](https://img.shields.io/github/v/release/wowlocal/waypoint-launcher?color=2ea44f)](https://github.com/wowlocal/waypoint-launcher/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?logo=apple&logoColor=white)](#build)
[![Apple Silicon native](https://img.shields.io/badge/Apple%20Silicon-native-2ea44f)](#why)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](#build)
[![Unofficial](https://img.shields.io/badge/Blizzard-unofficial-8a8a8a)](#disclaimer)

<img src="docs/screenshot.png" width="600" alt="Waypoint window listing Hearthstone and Warcraft III">

**English** · [Русский](README.ru.md)

</div>

---

## Why

The Battle.net app for Mac is still Intel-only. Every Apple Silicon Mac needs Rosetta just to open it, even though Hearthstone and World of Warcraft themselves run natively.

That is about to become a real problem: **macOS 27 is the last release with full Rosetta**. From macOS 28 on, Apple keeps only a limited subset for older games.

A launcher only has to do three things: install the game, keep it up to date, and log it in. Waypoint does just that, natively, and nothing else.

|  | Battle.net | Waypoint |
|---|---|---|
| Architecture | Intel (Rosetta) | Apple Silicon |
| Size on disk | ~1.5 GB | **6 MB** |
| Runs in the background | App + Agent + browser helpers | Nothing |

## Features

- **Native.** Written in Swift, built only for arm64.
- **One sign-in per account.** Uses the official Battle.net web login once. After that every launch is one click.
- **Several accounts.** Each one keeps its own Battle.net session, so switching between them is one click, with no login.
- **Installs games.** Click **+** in the toolbar and pick a game. Waypoint downloads it straight from Blizzard's servers and lays it out exactly the way Battle.net does, so the game takes it as its own. Interrupted installs pick up where they stopped. Every Blizzard game with a Mac version is on the list; [Supported games](#supported-games) shows what has been tested.
- **Updates games itself**, including ones Battle.net installed. It checks Blizzard's servers, downloads only the files that changed, verifies every one of them, and puts them in place: loose files are swapped in, and new data goes into the game's CASC storage the way Battle.net adds it.
- **Light.** About 27 MB of memory while it sits there. Installs and updates read Blizzard's manifests and indexes straight from disk instead of loading them, so even planning a 130 GB World of Warcraft install stays under 100 MB.
- **Updates itself** in the background with [Sparkle](https://sparkle-project.org). New versions download silently and install when you quit. There are no update dialogs; a small "Restart to Update" appears at the bottom of the window (and in the menu bar menu, if you turned it on).
- **Finds your games.** Reads Battle.net's install list and falls back to scanning the game folders, so it keeps working after you delete Battle.net.
- **Changes nothing in the game.** No patches and no injected code: the login is handed over exactly the way Battle.net does it.
- **Menu bar** quick launch, off by default. Turn it on in Settings (⌘,).

## Supported games

| Game | Install | Launch | Updates |
|---|---|---|---|
| Hearthstone | ✅ Through Waypoint | ✅ Tested natively, with the Battle.net app and its Agent fully quit | ✅ Through Waypoint |
| Warcraft III: Reforged | ✅ Tested: the same files as Battle.net's own install | ✅ Tested. The game itself is Intel-only, so it runs under Rosetta | 🧪 Through Waypoint. Tested by repairing Waypoint's and Battle.net's installs; no new build has shipped yet |
| World of Warcraft: Retail, Classic, Classic Era, Anniversary | 🧪 Implemented, not yet tested | 🧪 Implemented, not yet tested | 🧪 Implemented, not yet tested |
| StarCraft II, StarCraft: Remastered, Diablo III, Heroes of the Storm | 🧪 Implemented, not yet tested | 🧪 Implemented, not yet tested | 🧪 Implemented, not yet tested |

## Download

Get **Waypoint-x.y.z.dmg** from [Releases](https://github.com/wowlocal/waypoint-launcher/releases/latest), open it, and drag Waypoint to Applications. Releases are signed with a Developer ID and notarized by Apple, so the app opens without warnings.

Requires an Apple Silicon Mac with macOS 14 or later.

## Build

Requires macOS 14+ and Xcode with Swift 6.

```sh
git clone https://github.com/wowlocal/waypoint-launcher.git
cd waypoint-launcher
./scripts/bundle.sh          # → build/Waypoint.app
open build/Waypoint.app
```

Move `Waypoint.app` to `/Applications` if you want to keep it.

<details>
<summary><b>Making a release</b></summary>

`scripts/release.sh` runs the tests, then builds the app and signs it with your Developer ID (hardened runtime). It notarizes and staples the app, then packs it into a DMG and signs, notarizes and staples that too. It checks the result with Gatekeeper, then writes the Sparkle `appcast.xml` and verifies its EdDSA signature.

With `--publish` it does what snippets does: the DMG and `appcast.xml` go to S3 (`storage.yandexcloud.net/macos-releases/waypoint/`), which is the update feed installed copies read, and the DMG is mirrored as a GitHub release. S3 credentials come from `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` or a gitignored `scripts/release.env`.

```sh
# once: store notary credentials in the keychain (use an app-specific password)
xcrun notarytool store-credentials NotaryProfile --apple-id <apple id> --team-id <team id>
# …or use an App Store Connect API key instead: NOTARY_KEY=<.p8> NOTARY_KEY_ID=<id> NOTARY_ISSUER=<uuid>

scripts/release.sh 0.1.0             # → dist/Waypoint-0.1.0.dmg + .sha256
scripts/release.sh 0.1.0 --publish   # also tags v0.1.0 and creates the GitHub release

scripts/test-self-update.sh          # end-to-end: an old build updates itself from a local feed
```

Updates are signed with an EdDSA key kept in the keychain under the account `waypoint`. Its public half is in `scripts/bundle.sh`. Back it up somewhere safe: without it, installed copies can't be updated.

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account waypoint -x waypoint-sparkle.key   # export
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account waypoint -f waypoint-sparkle.key   # import on another Mac
```

</details>

## Usage

1. Open Waypoint and press **Play**.
2. The first time, sign in to Battle.net in the window that appears. Two-factor auth works.
3. That's it. Later launches skip the login.

The window's subtitle shows the account games launch as. To switch, click the person button in the toolbar and pick another account. **Add Account…** signs in to one more, and **Sign Out** forgets the current one. The same menu is in the menu bar item.

To install a game, click **+** in the toolbar and pick it. Choose where it goes (`/Applications` by default), the language and the region; the sheet shows the real download size. Progress shows in the game's row.

When a new version is out, **Play** turns into **Update**, with a progress bar while it downloads.

Right-click the button for more:

- **Sign In Again and Play**: use this if a game ever rejects the login.
- **Verify Files**: re-checks every file and repairs broken ones.
- **Play Without Updating**: shown only when an update is waiting.


## How it works

On macOS, Battle.net doesn't pass the login to a game on the command line. It writes an encrypted token into the `net.battle` preferences domain and starts the game, and the game reads the token on startup. Waypoint does the same.

```mermaid
sequenceDiagram
    actor You
    participant W as Waypoint
    participant L as Battle.net web login
    participant P as net.battle prefs
    participant G as Hearthstone
    participant S as Blizzard servers

    You->>W: Play
    W->>L: /login?app=WTCG (hidden, saved session)
    L-->>W: redirect to localhost:0/?ST=US-…
    Note over W,L: no session → reuse last token<br/>none at all → show login window
    W->>P: Launch Options/WTCG/WEB_TOKEN (encrypted)<br/>REGION, LOCALE
    W->>G: Hearthstone -launch -uid hs_beta
    G->>P: read token
    G->>S: log in
```

<details>
<summary><b>The details</b></summary>

**Preferences** (`~/Library/Preferences/net.battle.plist`)

| Key | Value |
|---|---|
| `Launch Options/<CODE>/WEB_TOKEN` | encrypted token (data) |
| `Launch Options/<CODE>/REGION` | `EU`, `US`, `KR`, `CN` |
| `Launch Options/<CODE>/LOCALE` | `enUS`, `ruRU`, … |

`<CODE>` is `WTCG` for Hearthstone and `WoW` for every WoW flavor.

**Encryption.** AES-128-CBC with a zero IV and PKCS#7 padding. The key is PBKDF2-HMAC-SHA1 (1000 rounds, salt `someSalt`) over a fixed 16-byte entropy XORed with the macOS user name. This mirrors `RegistryDarwin` in the game's Battle.net SDK. It was checked against tokens written by the real Battle.net app (`waypoint-cli check-tokens`).

**Token.** The Battle.net web login at `https://<region>.battle.net/login/en/?externalChallenge=login&app=<CODE>` finishes with a redirect to `http://localhost:0/?ST=<token>`. The token looks like `US-<32 hex>-<account id>`.

**Accounts.** Each account has its own persistent WebKit data store (`WKWebsiteDataStore(forIdentifier:)`), so their Battle.net sessions sit side by side and switching needs no login. The last token per account and game is kept in the login keychain, for when a session has expired. The BattleTag and email come from the JSON API behind Blizzard's account page (`account.battle.net/api/details`), read with that account's session.

**Launch commands**

| Game | Command | Working directory |
|---|---|---|
| Hearthstone | `Hearthstone.app/…/Hearthstone -launch -uid hs_beta` | install folder |
| WoW | `World of Warcraft.app/…/World of Warcraft -launcherlogin -uid wow` | flavor folder (`_retail_`, `_classic_`, …) |
| Other games | `<Game>.app/…/<Game> -launch -uid <uid>` | install folder (Warcraft III: `_retail_`) |

Games are started with `posix_spawn` and disclaim the launcher as their responsible process, like apps started by Battle.net. So privacy prompts, such as the microphone for WoW voice chat, belong to the game.

**Updates** use Blizzard's content delivery protocol (TACT):

1. Ask `https://<region>.version.battle.net/v2/products/hsb/versions` which build is live.
2. Fetch that build's config and *install manifest* from the CDN. The manifest lists every file with its MD5 and tags (platform, region, language, content).
3. Select files with the tags Battle.net recorded for your install. For Hearthstone that's exactly the 5398 files in its folder.
4. Diff against the installed build's manifest. Only files whose hash changed are downloaded. Without the old manifest, local files are hashed instead (this is what **Verify Files** does).
5. Look up each file's encoded key in the *encoding* table and its location in the CDN archive indexes, then download it with an HTTP range request, decode the BLTE container chunk by chunk, and check the MD5.
6. Once every file is downloaded and verified, swap them in, then delete the files the new build no longer has.

Downloads are staged in `.waypoint-staging` inside the game folder, so an interrupted update resumes where it stopped. Updating refuses to run while the game is open.

**Installs.** Hearthstone keeps its files loose, so installing it is an update into an empty folder. Every other game keeps its data in local CASC storage (`Data/data`), which the game reads itself. Waypoint downloads the files the build's download manifest lists for your platform and language, and writes the `data.###` archives, the 16 `.idx` index files and `shmem` byte for byte the way the Battle.net Agent does. The app and the other files from the install manifest go loose into the game folder, next to `.build.info`, `Data/config` and `Data/indices`. A Warcraft III install made by Waypoint holds exactly the same 73,972 files as Battle.net's own install of that build, and the game launches from it.

**Updates of these games** add the new build's files to the same storage, whoever wrote it. Nothing already there is moved or rewritten: new files go after the end of the last archive, then into new ones; the 16 index files are written as their next version, then `shmem`, and only then are the old index files removed, so the game always finds a complete set. An interrupted update resumes from its journal. Loose files are updated like Hearthstone's.

**Finding games.** The list comes from `/Users/Shared/Battle.net/Agent/product.db` (protobuf), or from the `.product.db` inside each game folder, plus the games Waypoint installed itself.

</details>

## Command line

```sh
xcrun swift run waypoint-cli list            # installed games and whether they run natively
xcrun swift run waypoint-cli plan hs_beta    # dry run: how a game would be launched
xcrun swift run waypoint-cli check-tokens    # verify the cipher on tokens Battle.net wrote
xcrun swift run waypoint-cli check-updates   # installed vs. live version
xcrun swift run waypoint-cli update hs_beta --dry-run           # what an update would download
xcrun swift run waypoint-cli update w3 --dry-run                # the same for a game stored in CASC
xcrun swift run waypoint-cli update hs_beta --verify --dry-run  # hash-check the whole install
xcrun swift run waypoint-cli fetch hs_beta '^Strings/' /tmp/hs  # download files into another folder
xcrun swift run waypoint-cli install w3 /Applications/Warcraft\ III --dry-run  # what installing a game would download
xcrun swift run waypoint-cli launch w3        # start an installed game
xcrun swift test
WAYPOINT_NETWORK_TESTS=1 xcrun swift test --filter liveUpdate  # real update, 36.6.0 → live, in a temp folder
```

## Roadmap

- [x] Hearthstone
- [x] Sign in once, launch with one click
- [x] Several accounts, switched without signing in again
- [x] Hearthstone updates without Battle.net
- [x] Install games from scratch, for every Blizzard game with a Mac version
- [x] Warcraft III installed and launched without Battle.net
- [ ] World of Warcraft tested on macOS
- [x] Updates for games stored in CASC (World of Warcraft, StarCraft, Diablo III, Warcraft III, Heroes of the Storm)
- [ ] A CASC game's update tested on a real new build
- [x] Prebuilt, notarized releases
- [x] Self-updates (Sparkle)
- [x] App icon
- [x] Native AppKit interface (no SwiftUI)

## Disclaimer

Waypoint is an unofficial fan project. It is not affiliated with or endorsed by Blizzard Entertainment. Blizzard, Battle.net, Hearthstone, World of Warcraft, Warcraft, StarCraft, Diablo and Heroes of the Storm are trademarks of Blizzard Entertainment, Inc.

Blizzard doesn't officially support launching games outside the Battle.net app. The approach has been used for years (see Credits), but there are no guarantees, and Blizzard can change the login hand-off at any time. Use at your own risk.

## Credits

- [hearthstone-linux](https://github.com/0xf4b1/hearthstone-linux): token encryption and the web login flow
- [BnetTokenator](https://github.com/InvoxiPlayGames/BnetTokenator): the `Launch Options` layout
- [TACTLib](https://github.com/overtools/TACTLib): the `product.db` schema
