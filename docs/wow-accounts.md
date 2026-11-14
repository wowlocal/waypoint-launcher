# WoW accounts

A Battle.net identity may own several WoW licenses, such as WoW1 and WoW2.
The game's **WoW Account** menu remembers which license to use for that
Battle.net identity, WoW edition and play region. Other editions and identities
keep their own choices. **Ask in WoW** removes the saved choice, so WoW shows
its own account picker at login when there are several licenses.

Playing WoW uses the saved choice without a picker, a lookup or any extra
sign-in. Until Waypoint has looked up an identity's licenses in a region, a
license Battle.net chose for that identity stays in use; after a lookup, no
choice means WoW asks. This feature does not change downloads, installed game
content, subscriptions or entitlement checks.

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
it. **Ask in WoW** clears the choice, and **Find WoW Accounts…** at the end
looks them up again. With one license or none there is nothing to choose, so
the game menu shows only **Find WoW Accounts…**. Unsupported regions and
accounts without a saved WoW sign-in do not show an unusable lookup action.

The library row shows the chosen license next to the version and region, but
only when the account has more than one license and the chosen one is still
listed.

Lookup is currently limited to Americas, the region verified by the original
contributor. In other regions WoW uses the license Battle.net chose, if any,
or asks at login.
Discovery does not establish subscription status or access to any particular
WoW edition. WoW's servers make those decisions.

A refreshed catalog never silently replaces a choice it still lists. While
there are other licenses to pick, a chosen license the latest lookup no longer
lists stays in the menu, checked and marked **(No Longer on Account)**, until
another choice is made. Play is never
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
token and region. Every WoW launch writes or clears that key, with one
exception: when Waypoint has neither a choice nor a lookup for the token's
identity and region, a license left there with a ticket of the same identity
and region (Battle.net's choice) stays. Anything else is cleared, so a previous
identity or region's license never goes out with a launch. Next to it Waypoint
records the Battle.net account id the license was written for, in its own
`dev.waypoint.launch-options` preferences (`WoW/GAME_ACCOUNT_OWNER`) rather
than Battle.net's, and writes or clears it with the license. A license whose
note names another account is never kept. Sign Out clears both when removing
the matching handoff token. Other games retain their existing launch behavior.

`waypoint-cli launch` replays the last native handoff's token, and its license
by the same rule: it stays when the play region matches and the owner note, if
any, names that token's account. The CLI does not read the GUI app's
per-edition preferences.

Account preferences contain license IDs and names only. Login tickets remain
in the existing Keychain vault. Discovery verifies the Battle.net owner at
authentication and for each resolved license, uses ordinary system TLS trust,
and bounds time, frame size and catalog size. Discovery is optional and its
protocol may need updating when Blizzard changes its services.

The protocol reference and original working launch proof came from
[wubsylol's contribution](https://github.com/wowlocal/waypoint-launcher/issues/7)
and its `contrib/wow-licence-selection` branch. This implementation keeps
the lookup off WoW's Play path and isolates the remembered choices from the
catalog cache. Persisting empty lookups, the row label and unavailable
licenses came from wubsylol's follow-up,
[#16](https://github.com/wowlocal/waypoint-launcher/pull/16).

## Validation

Synthetic tests cover preference persistence and isolation, stale launch keys,
protocol framing, owner mismatches, disconnects, cancellation and timeouts.
These do not establish live server compatibility for every build or region.
Real-client acceptance requires switching between two known licenses,
relaunching after restarting Waypoint, checking independent edition/identity
choices, and confirming that Ask in WoW brings up WoW's own
account picker, including when discovery is unavailable.

## Other games and the saved WoW login

Once WoW has a saved sign-in, Play for Hearthstone or Diablo IV in the
Americas may not need a sign-in of its own. Without a saved sign-in for the
game, Waypoint makes one quick game-service sign-in with the saved WoW login
and asks for the game's ticket: up to 5 s to find the live WoW build and 5 s
for the sign-in. It is skipped while WoW runs or WoW accounts are being found,
and the ticket serves that launch only. If anything fails, the normal sign-in
window opens, without a message.

## Sign In with Browser

In the Americas, WoW's sign-in window offers **Sign In with Browser…** for a
password manager or a passkey, which Waypoint's window can't use. Blizzard's
page ends on an address no browser can open (`http://localhost:0/?ST=…`); the
user copies it and pastes it into Waypoint, which never reads the browser or
the pasteboard on its own. Before using the address, Waypoint signs in to the
game service with it, which proves it works and says whose it is. Signing in
to a known account again refuses another account's address. The check is
refused while WoW runs or WoW accounts are being found. Afterwards, whether it
worked or not, the pasteboard is cleared if it still holds a pasted address.
