# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AutoLock is a WoW AddOn for TurtleWoW (Vanilla 1.12 private server) — a Warlock rotation assistant. It iterates a priority-sorted spell list and casts the first spell whose conditions are met, when the player triggers `AutoLock:DoAutoLock()` (typically via an action bar macro).

## Development Workflow

There is no build system, compiler, linter, or test runner. Development cycle:
1. Edit `.lua` or `.xml` files in this directory.
2. In-game: `/reload` to hot-reload, or restart TurtleWoW to pick up `.toc` changes.
3. Observe output in the default chat frame (`AutoLockLog.Info/Warning/Error`).

To test a specific function in-game: `/run AutoLock:FunctionName()`

## File Load Order (from AutoLock.toc)

```
AutoLock.xml        → NewConfig popup frame (XML template)
AutoLockLog.lua     → Logging helpers (must load first)
AutoLock.lua        → Core: SPELL_PRIORITY table, TryAction(), DoAutoLock(), event tracking
Movement.lua        → MovementEvents module (map-position polling)
AutoLockSpellbook.lua → SpellBook button + macro drag support
AutoLockHelper.lua  → Buff checks, mana cost, soul shard management, range checks
AutoLockUI.lua      → Prio-list ScrollFrame UI, minimap button, settings panel
```

Ace2 libs are loaded from `../Cursive/Libs/` — the Cursive AddOn must be present.

## Architecture

### Rotation Engine (AutoLock.lua)
`SPELL_PRIORITY` is a flat Lua table sorted by `priority` (ascending = higher priority). Each entry has:
- `name` — English spell name (always English, even on non-enUS clients)
- `type` — `"cast"` | `"curse"` | `"trinket"` | `"pet"`
- `priority` — numeric; lower fires first
- `enabled` — `true`/`false`; skipped when false
- `condition(unit)` — optional function returning boolean
- `target` — defaults to `"target"`
- `refreshtime` — for curses: seconds before expiry to refresh (0 = only apply if missing)
- `uitext` — optional display name override in the UI

`DoAutoLock()` iterates this table; `TryAction(entry)` applies checks in order:
1. `entry.enabled`
2. DarkHarvestChanneling guard (blocks everything while channeling)
3. `entry.condition(unit)`
4. Range check via `IsActionInRange` on the spell's action bar slot
5. Mana check → auto-Life Tap if mana is insufficient (configurable)
6. Cast by type: `CastSpellByName` / `Cursive:Curse(...)` / `entry.use()` / `CastPetAction(slot)`

### Spell State Tracking (AutoLock.lua)
Module-level locals track cast state across events:
- `WandShooting`, `DrainSoulChanneling`, `DarkHarvestChanneling`, `ShadowTrancePending`
- `ImmolateCastedAt` / `ImmolateTargetGUID` / `DoLock_OnCooldownUntil` — Immolate post-pause logic
- `ShadowTranceCastedAt` — prevents double-firing Shadow Trance proc

### Helper Module (AutoLockHelper.lua)
- `AutoLock:HasAnyBuff(unit, buffName, texturefile)` — dual strategy: `UnitBuff` + SuperWoW `GetPlayerBuffID`/`SpellInfo`
- `AutoLock:GetSpellManaCostByName(name)` — reads tooltip; cached in `AutoLock_ManaCostCache`
- `AutoLock:GetSpellDurationByName(name)` — reads tooltip for channel duration
- `AutoLock:IsOnCooldown(name)` — checks highest-rank spell slot cooldown
- `AutoLock:IsSpellOutOfRange(name)` — scans action slots 1–120 for the spell, then calls `IsActionInRange`
- `AutoLock:DeleteSoulShards()` — removes overflow shards from non-soul bags when a soul bag is full

### Movement Detection (Movement.lua)
`MovementEvents` polls `GetPlayerMapPosition` every 100ms. Fires synthetic `PLAYER_MOVING` / `PLAYER_STOPPED` events to registered listeners. Use `MovementEvents:IsMoving()` for inline checks.

### UI (AutoLockUI.lua)
- `AutoLock:InitUI()` — creates the main 700px-wide ScrollFrame window
- `AutoLock:PrioScrollUpdate()` — re-renders visible rows from `SPELL_PRIORITY`
- Configs stored in `AutoLockDB.configs[]`; active config in `AutoLockDB.activeConfig`
- `AutoLock:InitConfigs()` — loads saved configs into `SPELL_PRIORITY` on `VARIABLES_LOADED`
- Settings: `AutoLockDB.settings.autoDeleteShards`, `AutoLockDB.settings.useLifeTap`, `AutoLockDB.settings.hideNotInSpellbook`

### Saved Variables
`AutoLockDB` (defined in `.toc`) persists across sessions. Structure:
```lua
AutoLockDB = {
  activeConfig = "ConfigName",
  configs = { { name, icon, spells = { {name, enabled, priority, refreshtime, condition?} } } },
  minimapPos = number,  -- angle in degrees
  settings = { autoDeleteShards, useLifeTap, hideNotInSpellbook }
}
```

## Vanilla 1.12 Lua Constraints

- **No `string.match`** — use `strfind(str, pattern)` with captures
- **No `string.format` patterns** for matching — only `strfind`
- Event handlers use globals `event` and `arg1`–`arg9`, not function parameters
- `this` refers to the frame in XML `<Scripts>` blocks, not `self`
- `table.getn(t)` instead of `#t` for table length
- `GetSpellName(slot, BOOKTYPE_SPELL)` for spell lookups — no `C_Spell` API
- Maximum 18 global + 18 character macros
- `GetPlayerBuffID` and `SpellInfo` are SuperWoW extensions — guard with `if GetPlayerBuffID then`

## External Dependencies

| Dependency | Purpose | Guard pattern |
|---|---|---|
| **SuperWoW** | `GetPlayerBuffID`, `SpellInfo`, `CombatLogAdd` | `if GetPlayerBuffID and SpellInfo then` |
| **Cursive** | `Cursive:Curse(name, target, {refreshtime})` for DoTs | `if Cursive then` |
| **Ace2** | `AceAddon-2.0`, `AceEvent-2.0`, `AceConsole-2.0`, `AceHook-2.1`, `AceLocale-2.2` | loaded from `../Cursive/Libs/` |

## Adding a New Spell to the Rotation

Add an entry to `SPELL_PRIORITY` in `AutoLock.lua`. The table is sorted once at load time, so only `priority` determines order:

```lua
{
  name      = "Spell Name",   -- English name, must match GetSpellName()
  type      = "cast",         -- "cast" | "curse" | "pet" | "trinket"
  priority  = 25,             -- lower = higher priority
  target    = "target",
  enabled   = false,          -- start disabled; user enables in UI
  condition = function(unit)
    if MovementEvents and MovementEvents:IsMoving() then return false end
    local onCD = AutoLock:IsOnCooldown("Spell Name")
    return not onCD
  end,
},
```

For curses, use `type = "curse"` and add `refreshtime = N` (seconds before expiry to re-apply; 0 = only cast if missing). Curses are dispatched via Cursive.
