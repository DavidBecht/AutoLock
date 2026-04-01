-- AutoLockSpells.lua
-- SPELL_PRIORITY rotation table.
-- Conditions use AutoLockEngine guards (defined in AutoLockEngine.lua).

-- Lower priority number = higher priority (fires first).
SPELL_PRIORITY = {

  -- ── Procs ──────────────────────────────────────────────────────────────────
  {
    name     = "Shadow Bolt",
    type     = "cast",
    priority = 1,
    target   = "target",
    uitext   = "Shadow Trance (Shadow Bolt)",
    enabled  = true,
    condition = function(unit)
      return AutoLockEngine.IsShadowTranceProc()
    end,
  },

  -- ── Pet ────────────────────────────────────────────────────────────────────
  {
    name     = "Firebolt",
    type     = "pet",
    priority = 2,
    target   = "target",
    enabled  = true,
    condition = function()
      return UnitExists("target")
         and not UnitIsDead("pet")
         and UnitExists("pet")
    end,
  },

  -- ── Trinkets ───────────────────────────────────────────────────────────────
  {
    name     = "Trinket Slot 1",
    type     = "trinket",
    priority = 3,
    target   = "target",
    enabled  = false,
    condition = function()
      return AutoLock:IsTrinketReady(13) and UnitExists("target")
    end,
    use = function() UseInventoryItem(13); return true end,
  },
  {
    name     = "Trinket Slot 2",
    type     = "trinket",
    priority = 4,
    target   = "target",
    enabled  = false,
    condition = function()
      return AutoLock:IsTrinketReady(14) and UnitExists("target")
    end,
    use = function() UseInventoryItem(14); return true end,
  },

  -- ── Curses ─────────────────────────────────────────────────────────────────
  {
    name        = "Curse of Shadow",
    type        = "curse",
    priority    = 6,
    refreshtime = 0,
    target      = "target",
    enabled     = true,
    condition = function(unit, entry)
      if AutoLockEngine.IsBlockedByDrainSoul("agony") then return false end
      -- Skip if CoS is already on the target (refreshtime determines the refresh window).
      -- Without this guard, Cursive returns a truthy "handled" value instead of false,
      -- which sticks _npQueuedThisCast and freezes the rotation.
      if Cursive and Cursive.curses then
        local _, tGuid = UnitExists("target")
        local rt = entry and entry.refreshtime or 0
        if tGuid and Cursive.curses:HasCurse("curse of shadow", tGuid, rt) then
          return false
        end
      end
      return true
    end,
  },
  {
    name        = "Curse of Agony",
    type        = "curse",
    priority    = 7,
    refreshtime = 0,
    target      = "target",
    enabled     = true,
    condition = function()
      return not AutoLockEngine.IsBlockedByDrainSoul("agony")
    end,
  },
  {
    name        = "Corruption",
    type        = "curse",
    priority    = 8,
    refreshtime = 0,
    target      = "target",
    enabled     = true,
    condition = function()
      return not AutoLockEngine.IsBlockedByDrainSoul("corruption")
    end,
  },
  {
    name        = "Siphon Life",
    type        = "curse",
    priority    = 9,
    refreshtime = 0,
    target      = "target",
    enabled     = true,
    condition = function()
      return not AutoLockEngine.IsBlockedByDrainSoul("siphonLife")
    end,
  },

  -- ── Situative curses (disabled by default) ─────────────────────────────────
  { name = "Curse of Recklessness", type = "curse", priority = 10, refreshtime = 0, target = "target", enabled = false },
  { name = "Curse of Weakness",     type = "curse", priority = 11, refreshtime = 0, target = "target", enabled = false },
  { name = "Curse of Tongues",      type = "curse", priority = 12, refreshtime = 0, target = "target", enabled = false },
  { name = "Curse of the Elements", type = "curse", priority = 13, refreshtime = 0, target = "target", enabled = false },
  { name = "Curse of Doom",         type = "curse", priority = 15, refreshtime = 0, target = "target", enabled = false },

  -- ── Fire spells ────────────────────────────────────────────────────────────
  {
    name     = "Soul Fire",
    type     = "cast",
    priority = 17,
    target   = "target",
    enabled  = false,
    condition = function()
      if AutoLockEngine.IsPlayerMoving() then return false end
      local onCD = AutoLock:IsOnCooldown("Soul Fire")
      return not onCD
    end,
  },
  {
    name        = "Immolate",
    type        = "curse",
    priority    = 18,
    refreshtime = 1,
    target      = "target",
    enabled     = false,
    condition = function()
      if AutoLockEngine.IsImmolatePostPauseActive() then return false end
      if AutoLockEngine.IsPlayerMoving() then return false end
      return true
    end,
  },
  {
    name     = "Conflagrate",
    type     = "cast",
    priority = 19,
    target   = "target",
    enabled  = false,
    condition = function()
      if AutoLockEngine.IsPlayerMoving() then return false end
      return not AutoLock:IsOnCooldown("Conflagrate")
    end,
  },

  -- ── Cooldown spells ────────────────────────────────────────────────────────
  {
    name     = "Death Coil",
    type     = "cast",
    priority = 20,
    target   = "target",
    enabled  = true,
    condition = function()
      return AutoLock:IsOnCooldown("Death Coil") == false
    end,
  },
  {
    name     = "Shadowburn",
    type     = "cast",
    priority = 21,
    target   = "target",
    enabled  = true,
    condition = function()
      return AutoLock:IsOnCooldown("Shadowburn") == false
    end,
  },

  -- ── Dark Harvest ───────────────────────────────────────────────────────────
  {
    name     = "Dark Harvest",
    type     = "cast",
    priority = 22,
    target   = "target",
    enabled  = false,
    condition = function()
      if AutoLockEngine.IsPlayerMoving() then
        return false
      end
      if AutoLock:IsOnCooldown("Dark Harvest") then
        return false
      end
      if not AutoLockEngine.DarkHarvestDotsReady() then
        return false
      end
      if not AutoLockEngine.DrainSoulFinished() and not AutoLockEngine.IsDHInterruptDSEnabled() then
        return false
      end
      local fin = AutoLockEngine.DarkHarvestFinished()
      return fin
    end,
  },

  -- ── Drain Soul ─────────────────────────────────────────────────────────────
  {
    name     = "Drain Soul",
    type     = "cast",
    priority = 23,
    target   = "target",
    enabled  = true,
    condition = function()
      if AutoLockEngine.IsPlayerMoving() then
        return false
      end
      local fin = AutoLockEngine.DrainSoulFinished()
      return fin
    end,
  },

  -- ── Filler nukes ──────────────────────────────────────────────────────────
  {
    name     = "Shadow Bolt",
    type     = "cast",
    priority = 30,
    target   = "target",
    enabled  = false,
    condition = function()
      return not AutoLockEngine.IsPlayerMoving()
    end,
  },
  {
    name     = "Searing Pain",
    type     = "cast",
    priority = 32,
    target   = "target",
    enabled  = false,
    condition = function()
      return not AutoLockEngine.IsPlayerMoving()
    end,
  },

  -- ── Wand fallback ─────────────────────────────────────────────────────────
  {
    name     = "Shoot",
    type     = "cast",
    priority = 99,
    target   = "target",
    uitext   = "Shoot (Wand)",
    enabled  = false,
    condition = function()
      if AutoLockEngine.IsWandShooting() then return false end
      if AutoLockEngine.IsPlayerMoving() then return false end
      return true
    end,
  },
}

-- Sort once at load time (ascending priority = higher priority fires first).
table.sort(SPELL_PRIORITY, function(a, b)
  return (a.priority or 99) < (b.priority or 99)
end)
