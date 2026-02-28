# AutoLock

> **Priority-based spell rotation addon for Warlocks on [TurtleWoW](https://turtle-wow.org) (Vanilla WoW 1.12)**

<!-- IMAGE: Banner / hero screenshot of the main AutoLock UI open in-game, showing the spell priority list, config strip at the top, and the minimap button in the corner. Suggested size: 900×400 px. -->

---

## Table of Contents

- [What is AutoLock?](#what-is-autolock)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [The Main UI](#the-main-ui)
  - [Config Strip](#config-strip)
  - [Spell Priority List](#spell-priority-list)
  - [Conditions](#conditions)
  - [Settings Panel](#settings-panel)
- [Default Spell Rotation](#default-spell-rotation)
- [Config System](#config-system)
- [Minimap Button](#minimap-button)
- [SpellBook Button](#spellbook-button)
- [Slash Commands](#slash-commands)
- [How the Rotation Works](#how-the-rotation-works)
- [Dependencies & Startup Warnings](#dependencies--startup-warnings)
- [Support](#support)

---

## What is AutoLock?

AutoLock automates your Warlock rotation on TurtleWoW. Instead of manually tracking which dots are active, whether Shadow Trance just procced, or when your cooldowns are ready, you press **one button** (or keybind a macro) and AutoLock fires the highest-priority spell that is ready to go.

Key highlights:

- **Priority-based** — every spell has a number; lowest number fires first.
- **Fully configurable** — enable/disable spells, reorder them, and save multiple named configs (e.g. *AoE*, *Single Target*, *PvP*).
- **Smart conditions** — spells only fire when their condition is met: Shadow Trance proc active, cooldown ready, target in range, player not moving, HP/mana above a threshold, etc.
- **Curse integration** — curses are managed via the [Cursive](https://github.com/) addon and are automatically refreshed only when they fall off.
- **Soul Shard management** — optionally auto-deletes shards sitting outside your Soul Bag when your Soul Bag is full.
- **Life Tap automation** — optionally casts Life Tap when you run low on mana before a cast.

---

## Requirements

| Dependency | Required | Purpose |
|---|---|---|
| **TurtleWoW** (patch 1.12) | Yes | Client version the addon targets |
| **Cursive** | Yes* | Handles curse application and refresh timers |
| **SuperWoW** | Strongly recommended | Enables buff detection (Shadow Trance, etc.) |

> *The Cursive libraries are bundled in the addon's TOC — Cursive must be installed for the addon to load at all. If SuperWoW is absent, buff-based features (Shadow Trance detection, buff tracking) are silently skipped with a warning.

---

## Installation

1. Download or clone this repository into your addons folder:
   ```
   TurtleWoW/Interface/AddOns/AutoLock/
   ```
2. Make sure **Cursive** is also installed in `Interface/AddOns/Cursive/`.
3. Launch the game. AutoLock loads automatically.
4. On the **very first launch** after installing or after a TOC change, do a **full game restart** (not just `/reload`) so WoW picks up any new files.

---

## Quick Start

1. Open the UI: click the **Shadow Bolt icon** on your minimap, or type `/autolock toggle`.
2. Enable the spells you want in your rotation using the checkboxes.
3. Drag the spells into the order you want using **Up / Down**.
4. Make sure your spells are on your action bar (required for range checking).
5. Bind a key or create a macro `/run AutoLock:DoAutoLock()` and spam it.

<!-- IMAGE: Screenshot of the Quick Start flow — minimap button highlighted, then the UI open with a few spells checked. -->

---

## The Main UI

<!-- IMAGE: Annotated screenshot of the full main UI window with callouts: (1) config strip, (2) Show Disabled checkbox, (3) spell row with checkbox/name/prio/refresh/Cond/Up/Down, (4) bottom buttons (Apply / New Config / Settings). -->

Open with `/autolock toggle` or the minimap button.

### Config Strip

The horizontal icon strip at the top of the window shows all your saved configs.

<!-- IMAGE: Close-up of the config strip showing 3–4 config icons, one highlighted in gold as active. -->

| Interaction | Action |
|---|---|
| **Left-click** | Load this config |
| **Shift + drag** | Create a macro for this config and place it on the cursor — drag it to an action bar slot |
| **Right-click** | Edit name and icon |
| **Shift + right-click** | Delete (with confirmation) |

The active config is highlighted in gold. Hovering shows a tooltip with all interactions.

---

### Spell Priority List

Each row in the list represents one spell entry.

<!-- IMAGE: Close-up of 3–4 spell rows, showing the checkbox, spell name, priority number, optional refresh box, Cond button, and Up/Down buttons. -->

| Column | Description |
|---|---|
| **Checkbox** | Enable or disable this spell in the rotation |
| **Name (type)** | Spell name and type (`cast`, `curse`, `trinket`, `pet`) |
| **Prio** | Current priority number — lower fires first |
| **Refresh (s)** | Curse only — minimum remaining duration before re-applying (leave `0` to always let Cursive decide) |
| **Cond** | Opens the per-spell condition editor |
| **Up / Down** | Move the spell up or down in priority |

Use the **Show Disabled** checkbox at the top-left to show or hide disabled spells. Click **Apply** to force-refresh the list after making changes.

---

### Conditions

Click the **Cond** button on any spell row to open the condition editor for that spell.

<!-- IMAGE: Screenshot of the Conditions popup window showing the three sliders/inputs (Player HP, Player Mana, Target HP) and the AND/OR logic dropdown. -->

| Field | Description |
|---|---|
| **Player HP** | Only cast if player HP% is ≤ or ≥ the threshold |
| **Player Mana** | Only cast if player Mana% is ≤ or ≥ the threshold |
| **Target HP** | Only cast if target HP% is ≤ or ≥ the threshold |
| **Combine** | **ALL (AND)** — all conditions must pass; **ANY (OR)** — at least one must pass |

Leave a field empty to ignore that condition.

**Example:** Set *Drain Soul* to Target HP ≤ 20 so it only fires for the soul shard below 20 %.

---

### Settings Panel

Click the **Settings** button (bottom of the main window) to open the settings panel.

<!-- IMAGE: Screenshot of the Settings panel showing the two checkboxes and the coffee button. -->

| Setting | Default | Description |
|---|---|---|
| **Auto-delete Soul Shards when Soul Bag is full** | On | When your Soul Bag fills up, shards sitting in normal bags are automatically deleted on `BAG_UPDATE` |
| **Use Life Tap when low on mana** | On | Automatically casts Life Tap when your mana is too low for the next spell in the rotation |

Settings are saved to `AutoLockDB.settings` and persist between sessions.

---

## Default Spell Rotation

The table below lists every spell entry that ships with AutoLock, sorted by default priority. You can reorder and toggle these freely inside the UI.

| Priority | Spell | Type | Enabled | Notes |
|---|---|---|---|---|
| 1 | Shadow Trance (Shadow Bolt) | cast | ✅ | Only fires when the Shadow Trance proc is active |
| 2 | Firebolt (Pet) | pet | ✅ | Only fires if a living pet exists |
| 3 | Trinket Slot 1 | trinket | ❌ | Enable manually; fires when trinket is off cooldown |
| 4 | Trinket Slot 2 | trinket | ❌ | Enable manually; fires when trinket is off cooldown |
| 6 | Curse of Shadow | curse | ✅ | Via Cursive |
| 7 | Curse of Agony | curse | ✅ | Via Cursive |
| 8 | Corruption | curse | ✅ | Via Cursive |
| 9 | Siphon Life | curse | ✅ | Via Cursive; skipped while Drain Soul is channeling |
| 10 | Curse of Recklessness | curse | ❌ | Situational |
| 11 | Curse of Weakness | curse | ❌ | Situational |
| 12 | Curse of Tongues | curse | ❌ | Situational |
| 13 | Curse of the Elements | curse | ❌ | Situational |
| 15 | Curse of Doom | curse | ❌ | Situational |
| 17 | Soul Fire | cast | ❌ | Skipped while moving; checks cooldown |
| 18 | Immolate | curse | ❌ | Skipped while moving; has post-cast pause to avoid double application |
| 19 | Conflagrate | cast | ❌ | Skipped while moving; checks cooldown |
| 20 | Death Coil | cast | ✅ | Only fires when off cooldown |
| 21 | Shadowburn | cast | ✅ | Only fires when off cooldown |
| 22 | Dark Harvest | cast | ❌ | TurtleWoW custom spell; skipped while moving or channeling |
| 23 | Drain Soul | cast | ✅ | Skipped while moving; waits for previous channel to finish |
| 30 | Shadow Bolt (filler) | cast | ❌ | Skipped while moving |
| 32 | Searing Pain | cast | ❌ | Skipped while moving |
| 99 | Shoot (Wand) | cast | ❌ | Fallback; skipped while already shooting or moving |

> **Tip:** Enable *Shadow Bolt (filler)* at priority 30 as your spammable filler nuke — it sits below your DoTs and finishers so it only fires when everything else is on cooldown or already active.

---

## Config System

Configs let you save and switch between different priority setups instantly.

<!-- IMAGE: Screenshot showing the "New Config" popup with the name field and icon picker grid. -->

### Creating a Config

1. Click **New Config** at the bottom of the main window.
2. Type a name (up to 16 characters).
3. Pick an icon from the grid.
4. Click **OKAY** — the current spell priorities and settings are saved to this config.

### Switching Configs

Left-click any config icon in the strip at the top. The icon turns gold to indicate the active config.

### Action Bar Macros

Shift-drag a config icon onto an action bar slot to create a macro. The macro runs:
```
/run AutoLock:LoadConfigByName("YourConfigName"); AutoLock:DoAutoLock()
```
This lets you switch configs and fire the rotation in one keypress.

### Editing / Deleting

- **Right-click** a config icon → rename and change icon.
- **Shift + right-click** → delete (confirmation required).

---

## Minimap Button

<!-- IMAGE: Close-up of the minimap with the shadow bolt icon button visible in the upper-right area. -->

A draggable **Shadow Bolt icon** appears on your minimap.

- **Click** — opens/closes the main UI.
- **Drag** — reposition the button anywhere around the minimap. Position is saved.

---

## SpellBook Button

AutoLock adds a button to the **General** tab of your spellbook.

<!-- IMAGE: Screenshot of the spellbook General tab with the AutoLock button visible in the spell grid. -->

- **Left-click** — fires `DoAutoLock()` directly.
- **Shift + drag** — picks up the AutoLock macro to place on an action bar.

---

## Slash Commands

```
/autolock toggle    — open or close the main UI
/autolock show      — open the main UI
/autolock hide      — close the main UI
```

---

## How the Rotation Works

When `AutoLock:DoAutoLock()` is called (via keybind macro or the spellbook button), it loops through `SPELL_PRIORITY` from lowest to highest number and fires the **first entry** whose conditions are all satisfied:

```
DoAutoLock()
  └─ for each entry in priority order:
       1. Skip if disabled
       2. Skip if Dark Harvest is still channeling
       3. Skip if the spell's custom condition() returns false
          (Shadow Trance proc, cooldown, movement, HP/mana thresholds…)
       4. Skip if out of range  (requires the spell to be on an action bar slot)
       5. If mana is too low → cast Life Tap (if enabled in Settings)
          → return false so the spell is skipped this tick
       6. Fire the spell / trinket / pet action → return true (stops the loop)
```

Because only **one action fires per call**, spam the macro as fast as your GCD allows.

### Shadow Trance

AutoLock detects the Shadow Trance buff (requires SuperWoW) and puts a special *Shadow Trance (Shadow Bolt)* entry at priority 1. It has a short post-cast grace period so it doesn't fire a second Shadow Bolt immediately after the proc bolt lands.

### Movement Detection

Spells marked as cast-type check the movement poller (`MovementEvents`). If the player is moving, those spells are skipped. Instants (curses, Death Coil, etc.) are not blocked by movement.

### Range Checking

For cast and curse spells, AutoLock searches your action bars for a slot containing that spell and calls `IsActionInRange()`. If the slot is not found, range checking is skipped with a warning. **Keep your rotation spells on your action bars.**

---

## Dependencies & Startup Warnings

At login, AutoLock prints a coloured status line for each potential issue:

| Message | Meaning |
|---|---|
| `[Warning] AutoLock uses English spell names. Non-English clients may have issues…` | Your client locale is not `enUS`. Spell detection may fail. |
| `[Warning] SuperWoW not detected. Buff-based features … will not work.` | SuperWoW is missing — Shadow Trance detection is disabled. |
| `[Warning] Cursive not found. Curse spells in the rotation will be skipped.` | Cursive addon not loaded — all `curse`-type entries are silently skipped. |

Log format: `[AutoLock][Level]: message`
- `[AutoLock]` — warlock purple
- `[Info]` — blue
- `[Warning]` — yellow
- `[Error]` — red

---

## Support

If AutoLock saves you from manually tracking your dots, consider buying the author a coffee! ☕

Click the **"Buy me a Coffee – PayPal"** button inside the Settings panel to print the link to your chat window, then copy it to your browser.

<!-- IMAGE: Screenshot of the Settings panel with the PayPal button highlighted. -->

---

*AutoLock is built for [TurtleWoW](https://turtle-wow.org) — the Vanilla 1.12 progressive realm.*
