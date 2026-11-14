# Account-menu follow-up to feat/wow-account-selection

Base: 167ede2. This proposal builds on the developer’s branch, not the personal
fork. It keeps WoWAccountDiscovery, its endpoint/transport/owner checks,
WoWAccountStore and LaunchOptions. It does not import the personal native
service, BattleTag changes, shared-game sign-in or release/bundle configuration.

## Existing behavior credited to the base

The developer already implements native licence discovery, owner/region-scoped
catalogs, per-owner/edition/region choices, checked licence submenus, duplicate
name disambiguation, explicit refresh and protected launch handoff. Those are
not claimed as new work here.

## Additions

- A first-choice AppKit window establishes a remembered owner/region default.
  Explicit per-edition choices take priority. Defaults use reserved uid * in
  the existing selection schema; no separate personal-store migration is used.
- The prompt follows Add account when that login issued WoW authorization.
  Upstream’s Hearthstone-first fresh-login default is unchanged; if no WoW
  authorization exists yet, setup waits for the first WoW launch.
- Rows show version, effective launch region and selected licence, and observe
  identity/selection changes so the label updates immediately.
- The submenu also exists with an empty list and has a separated one-click
  Refresh list action, instead of requiring another Find Accounts sheet.
- A successful empty catalog is persisted distinctly from never fetched.
  A missing selected licence stays remembered/visible as unavailable; a
  supported-region Play requests an explicit replacement, rather than silently
  selecting another. Explicit reselection replaces any stale edition override.
- Menu actions bind to the owner and region captured when the menu was built.

## Deliberate policy change

The base allows an automatic launch with no saved choice. This proposal requires
a choice on supported-region launches with no valid selection. Existing users
who deliberately selected automatic cannot be distinguished from never-chosen
users in the old format and will also see the prompt. Cancel/error keeps saved
state but stops that pending launch. The automatic/Default menu row is removed;
select(nil) remains available in the store API and reveals an owner default
when present. This is a UX policy decision offered for review.

## Validation and limits

88 targeted WoW discovery/store/account/launch tests passed, including existing
transport regressions and new default/override, empty-cache restart and stale
edition reselection cases. The executable compiles and independent source
review completed. Equivalent menu refresh and row labels were exercised in
personal 1.2.7; this port on the developer’s transport has not had a separate
live UI/game test. Fresh-identity interactive onboarding remains to be accepted
with a real new identity. No credentials or real account preferences were read
or changed while preparing the proposal.

The PR should target feat/wow-account-selection and be retargeted after that
branch merges. It is intentionally a follow-up to that branch, not independent
of it. Closed PR #9 remains closed; unrelated draft PRs are unchanged.
