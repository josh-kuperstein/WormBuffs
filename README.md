# Worm Buffs

A World of Warcraft addon that puts a big, pulsing, clickable icon on screen when you're missing one of your own buffs. It's built for warlocks first, to catch a dropped **Soul Link** or **Demon Armor**, and has starter lists for a few other classes.

Click an icon to cast the missing buff. A raid-warning sound plays when a buff first goes missing.

## Installing

1. Download the latest `WormBuffs-vX.Y.Z.zip` from the [Releases](../../releases) page.
2. Extract it into your client's AddOns folder, so you end up with `World of Warcraft/<client folder>/Interface/AddOns/WormBuffs/`.
3. Restart the game or type `/reload`.

## What it watches

Each character gets its class defaults the first time it logs in. An entry counts as covered if *any* of its spells is on you, and entries for spells you don't know yet are skipped.

| Class | Buffs |
|---|---|
| Warlock | Demon Armor or Demon Skin; Soul Link (needs a pet) |
| Mage | Arcane Intellect or Arcane Brilliance; Mage, Ice or Frost Armor |
| Priest | Power Word: Fortitude or Prayer of Fortitude; Inner Fire |
| Druid | Mark of the Wild or Gift of the Wild |
| Warrior | Battle Shout |

If Soul Link is missing because your demon isn't out, the icon turns gray and says "(no pet)" instead of trying to cast.

## Commands

| Command | What it does |
|---|---|
| `/wbuffs list` | Show what's being watched |
| `/wbuffs add Demon Armor, Demon Skin` | Watch a buff (separate names with commas when either one counts) |
| `/wbuffs remove <#>` | Stop watching entry # |
| `/wbuffs pet <#>` | Toggle "needs a pet" on entry # |
| `/wbuffs unlock` / `/wbuffs lock` | Drag the icons somewhere else (shows a preview while unlocked) |
| `/wbuffs scale <n>` | Icon size, from 0.5 to 3 |
| `/wbuffs sound` | Turn the warning sound on or off |
| `/wbuffs reset` | Restore your class defaults |
| `/wbuffs debug` | Show why each buff is or isn't flagged |

`/wormbuffs` works as well as `/wbuffs`.

## In combat

The game hides auras from addons during combat and won't let them change clickable buttons. So Worm Buffs checks out of combat only: the icons stay as they were when the fight started and refresh as soon as it ends. Icons also hide while you're dead, on a flight path or in a vehicle.

## Compatibility

Worm Buffs is built for the Forever client (versions 1.60.x), which uses the modern 12.x addon API. The interface numbers in `WormBuffs.toc` follow the client version. To check yours, type:

```
/dump select(4, GetBuildInfo())
```

## Releasing

Changes reach `main` through pull requests. Every merge to `main` runs the release workflow, which reads `## Version:` from `WormBuffs.toc`. If there's no tag for that version yet, it tags the merge, zips the addon and publishes a GitHub release with notes generated from the merged PRs. If the tag already exists, nothing happens.

So to ship a change, bump the version in the same PR: the minor number for new features and the patch number for fixes. Changes that shouldn't ship yet, or don't touch the addon (like README edits), leave the version alone.
