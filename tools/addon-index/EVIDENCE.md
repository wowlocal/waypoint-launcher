# Why each index entry is the author's own

An entry in `Sources/WaypointCore/AddOns/AddOnIndex.swift` lets Waypoint
replace that add-on's folders for everyone who has it, so each repository
must be the add-on's own, never a fork or a copy. Each line names the proof.
`check.py` also confirms each one publishes `release.json` and isn't a GitHub
fork (`gh api repos/<repo> --jq .fork`).

Kinds of proof:
- **WoWI link:** the add-on's WoWInterface page links to the repository
  (checked through `api.mmoui.com/v4/game/WOW/filedetails/<id>.json`).
- **Author:** the repository's owner is the add-on's author (its TOC's
  `## Author`).
- **Org:** the repository belongs to the add-on's own GitHub organization.

Checked 2026-11-15.

| Add-on | Repository | Proof |
|---|---|---|
| BigWigs | BigWigsMods/BigWigs | Org (BigWigsMods) |
| LittleWigs | BigWigsMods/LittleWigs | Org (BigWigsMods) |
| BigWigs Voice | BigWigsMods/BigWigs_Voice | Org (BigWigsMods) |
| Capping | BigWigsMods/Capping | Org (BigWigsMods); author Funkeh |
| Deadly Boss Mods | DeadlyBossMods/DeadlyBossMods | Org (DeadlyBossMods) |
| WeakAuras | WeakAuras/WeakAuras2 | Org (WeakAuras) |
| Plater Nameplates | Tercioo/Plater-Nameplates | Author (Tercioo) |
| Mythic Dungeon Tools | Nnoggie/MythicDungeonTools | Author (Nnoggie) |
| Masque | SFX-WoW/Masque | Author (StormFX's org SFX-WoW) |
| All The Things | ATTWoWAddon/AllTheThings | Org (ATTWoWAddon) |
| Bartender4 | Nevcairiel/Bartender4 | Author (Nevcairiel) |
| HandyNotes | Nevcairiel/HandyNotes | WoWI link (15716) |
| Mapster | Nevcairiel/Mapster | WoWI link (8306) |
| Quartz | Nevcairiel/Quartz | WoWI link (7158) |
| Inventorian | Nevcairiel/Inventorian | Author (Nevcairiel) |
| OmniCC | tullamods/OmniCC | Author (Tuller's org tullamods) |
| Dominos | tullamods/Dominos | Author (Tuller's org tullamods) |
| tullaRange | tullamods/tullaRange | Author (Tuller's org tullamods) |
| Cell | enderneko/Cell | Author (enderneko) |
| Questie | Questie/Questie | Org (Questie) |
| Raider.IO | RaiderIO/raiderio-addon | Org (RaiderIO) |
| Decursive | 2072/Decursive | Author (John Wellesz's org 2072) |
| TellMeWhen | ascott18/TellMeWhen | WoWI link (10855) |
| BetterBags | Cidan/BetterBags | Author (Cidan) |
| SexyMap | funkydude/SexyMap | Author (Funkeh, funkydude) |
| BigDebuffs | jordonwow/bigdebuffs | WoWI link (26006) |
| BlizzMove | Kiatra/BlizzMove | WoWI link (23875) |
| SimulationCraft | simulationcraft/simc-addon | Org (simulationcraft) |
| Raid Frame Settings | Slothpala/RaidFrameSettings | Author (Slothpala) |
| Advanced Interface Options | Stanzilla/AdvancedInterfaceOptions | WoWI link (25002) |
| Edit Mode Expanded | teelolws/EditModeExpanded | Author (Teelo, teelolws) |
| Rarity | WowRarity/Rarity | Org (WowRarity) |
| BagSync | Xruptor/BagSync | WoWI link (15351) |

Left out on purpose:
- **Aurora** and **Shadowed Unit Frames:** GitHub forks.
- **Threat Plates**, **Gargul**, **RCLootCouncil** and **Grid2:** no proof found yet (Grid2's repository links to its CurseForge page, but nothing links back).
- **VuhDo** and **NDui:** releases for one unexpected game only.
- **Musician List:** needs Musician, which has no release here.
- **BugSack:** needs BugGrabber, which has no release here.
- **NoobTacoUI:** too new to tell.
- **Hekili** and **SUI:** no release for a current game (their retail releases are for 11.x); add back once they publish one.
- **AtlasLoot Classic**, **AdiBags** and **Kui Nameplates:** no release in the last 12 months.
