# WoW accounts

A Battle.net identity may own several WoW licenses, such as WoW1 and WoW2.
The game's **WoW Account** menu remembers which license to use for that
Battle.net identity, WoW edition and play region. Other editions and identities
keep their own choices. **Choose When WoW Starts** removes the saved choice,
so WoW shows its own account picker at login when there are several licenses.

Play uses the saved choice without opening a picker, a network lookup, or an
additional authentication connection. New and upgraded installations
use Choose When WoW Starts until a license is saved. This feature does not
change downloads, installed game content, subscriptions or entitlement checks.

## Looking up licenses

After signing in to WoW once, choose **Find WoW Accounts…** from its game
menu. A small sheet asks you to close WoW on other devices before finding
accounts. It uses the saved WoW authorization, without a second website
sign-in. Local WoW processes are checked even when their installations are
outside the library; clients on other devices cannot be detected.

With exactly one license, that license becomes the edition's choice and the
sheet closes. With several, the sheet lists them in a pop-up, already on the
current choice if there is one: **Use Account** saves it, and **Cancel** leaves
the choice as it was (WoW asks at login). Afterward **WoW Account** lists the
cached licenses with a checkmark on the current choice; click one to change
it. **Choose When WoW Starts** clears the choice. **Refresh Accounts…** opens
the same lookup sheet when needed. Unsupported regions and accounts without a
saved WoW sign-in do not show an unusable lookup action.

The library row shows the chosen license next to the version and region, but
only when the account has more than one license and the chosen one is still
listed.

Lookup is currently limited to Americas, the region verified by the original
contributor. Other regions keep the existing behavior: WoW chooses at login.
Discovery does not establish subscription status or access to any particular
WoW edition. WoW's servers make those decisions.

A refreshed catalog never silently replaces a choice it still lists. A chosen
license the latest lookup no longer lists stays in the menu, checked and
marked **(No Longer on Account)**, until another choice is made. Play is never
blocked by it: that launch goes out without `GAME_ACCOUNT`, so WoW chooses. A
license listed under the same ID with a new name launches under the new name.
A lookup that finds no licenses is remembered across restarts too, so "none
found" is not mistaken for "never looked up". The single-license rule above is
the only automatic choice.

Canceling a pending lookup, timeout and lookup failure preserve the existing
choice and cached accounts. Refresh changes the cache only after the complete
owner-verified lookup succeeds. A menu or sheet choice applies to the
identity and region it was shown for; if either changed in the meantime, the
choice is refused. Sign Out removes that identity's selections and cached
license names; other identities remain.

## Launch handoff and compatibility

Native WoW receives the license name through
`Launch Options/WoW/GAME_ACCOUNT` in `net.battle`, alongside the actual launch
token and region. Every WoW launch explicitly writes or clears that key. This
prevents a previous identity or region's license from leaking into a launch
that lets WoW choose. Next to it Waypoint records the Battle.net account id the
license was written for, in its own `dev.waypoint.launch-options` preferences
(`WoW/GAME_ACCOUNT_OWNER`) rather than Battle.net's, and writes or clears it
with the license. Sign Out
clears both when removing the matching handoff token. Other games retain their
existing launch behavior.

`waypoint-cli launch` replays the last native handoff's token and validated
license only when the play region matches and Waypoint's owner note names that
token's own account. Without a matching note (another account's license, or
one only Battle.net or an earlier Waypoint build wrote) the license is dropped
and WoW chooses; after upgrading, the note appears once the app launches WoW
with a chosen license. The CLI does not read the GUI app's per-edition
preferences.

Account preferences contain license IDs and names only. Login tickets remain
in the existing Keychain vault. Discovery verifies the Battle.net owner at
authentication and for each resolved license, uses ordinary system TLS trust,
and bounds time, frame size and catalog size. Discovery is optional and its
protocol may need updating when Blizzard changes its services.

The protocol reference and original working launch proof came from
[wubsylol's contribution](https://github.com/wowlocal/waypoint-launcher/issues/7)
and its `contrib/wow-licence-selection` branch. This implementation keeps
discovery off the Play path and isolates the remembered choices from the
catalog cache. Persisting empty lookups, the row label and unavailable
licenses came from wubsylol's follow-up,
[#16](https://github.com/wowlocal/waypoint-launcher/pull/16).

## Validation

Synthetic tests cover preference persistence and isolation, stale launch keys,
protocol framing, owner mismatches, disconnects, cancellation and timeouts.
These do not establish live server compatibility for every build or region.
Real-client acceptance requires switching between two known licenses,
relaunching after restarting Waypoint, checking independent edition/identity
choices, and confirming that Choose When WoW Starts brings up WoW's own
account picker, including when discovery is unavailable.

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
