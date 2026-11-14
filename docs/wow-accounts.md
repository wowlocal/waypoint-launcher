# WoW accounts

A Battle.net identity may own several WoW licences, such as WoW1 and WoW2.
The game's **WoW Account** menu remembers which licence to use for that
Battle.net identity, WoW edition and play region. Other editions and identities
keep their own choices. **Default** removes the explicit choice.

Play uses the saved choice without opening a picker, checking a catalogue, or
making an additional authentication connection. New and upgraded installations
use Default until a licence is explicitly saved. This feature does not change
downloads, installed game content, subscriptions or entitlement checks.

## Looking up licences

After signing in to WoW once, choose **Find WoW Accounts…** from its game
menu. A small sheet asks you to close WoW on other devices before finding
accounts. It uses the saved WoW authorization, without a second website
sign-in. Local WoW processes are checked even when their installations are
outside the library; clients on other devices cannot be detected.

After a successful lookup the sheet closes. **WoW Account** then lists the
cached licences with a checkmark on the current choice. Click one to use it;
there is no Save dialog. **Default** clears the choice. **Refresh Accounts…**
opens the same lookup sheet when needed. Unsupported regions and accounts
without a saved WoW sign-in do not show an unusable lookup action.

Lookup is currently limited to Americas, the region verified by the original
contributor. Other regions keep the existing Default launch behavior. Discovery
does not establish subscription status or access to any particular WoW edition.
WoW's servers make those decisions. A stale selection can be changed or reset
to Default; refreshed catalogues never silently replace an explicit choice.

Cancelling a pending lookup, timeout and lookup failure preserve the existing
choice and cached accounts. Refresh changes the cache only after the complete
owner-verified lookup succeeds, without choosing a licence automatically.
Only choosing an account in the menu changes the launch choice. Sign Out removes that
identity's selections and cached licence names; other identities remain.

## Launch handoff and compatibility

Native WoW receives the licence name through
`Launch Options/WoW/GAME_ACCOUNT` in `net.battle`, alongside the actual launch
token and region. Every WoW launch explicitly writes or clears that key. This
prevents a previous identity or region's licence from leaking into a Default
launch. Sign Out clears it when removing the matching handoff token. Other
games retain their existing launch behavior.

`waypoint-cli launch` replays the last native handoff's token and validated
licence only when the play region matches. It does not read the GUI app's
per-edition preferences; a different region uses Default.

Account preferences contain licence IDs and names only. Login tickets remain
in the existing Keychain vault. Discovery verifies the Battle.net owner at
authentication and for each resolved licence, uses ordinary system TLS trust,
and bounds time, frame size and catalogue size. Discovery is optional and its
protocol may need updating when Blizzard changes its services.

The protocol reference and original working launch proof came from
[wubsylol's contribution](https://github.com/wowlocal/waypoint-launcher/issues/7)
and its `contrib/wow-licence-selection` branch. This implementation keeps
discovery off the Play path and isolates the remembered choices from the
catalogue cache.

## Validation

Synthetic tests cover preference persistence and isolation, stale launch keys,
protocol framing, owner mismatches, disconnects, cancellation and timeouts.
These do not establish live server compatibility for every build or region.
Real-client acceptance requires switching between two known licences, relaunching
after restarting Waypoint, checking independent edition/identity choices,
and confirming Default still launches when discovery is unavailable.

## External-browser sign-in

No external-browser sign-in is added by this feature. The existing game login
returns to `http://localhost:0`, which cannot be served by a local listener and
does not match AuthenticationServices' custom-scheme or associated-HTTPS
callbacks. Blizzard's supported OAuth examples provide configurable redirects
for API authorization, but that is not proof of a usable game-launch ticket.
An automatic browser return must be established before adding this option;
copying a ticket URL is not part of this launcher's account-selection flow.
See [Apple's callback requirements](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/callback/https(host:path:))
and [Blizzard's OAuth example](https://github.com/Blizzard/oauth-client-sample).
