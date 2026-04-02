-- AutoLockEngine.lua
-- Rotation engine: cast-state tracking, event handling, TryAction/DoAutoLock.
-- Exposes AutoLockEngine with guard functions consumed by AutoLockSpells.lua.
-- Depends on: AutoLockHelper.lua, AutoLockSoulShards.lua

AutoLockEngine = {}

-- ===========================
-- Module-local state
-- ===========================
local WandShooting          = false
local DrainSoulChanneling   = false
local DarkHarvestChanneling = false
local ShadowTrancePending   = false

local ShadowTranceCastedAt   = 0
local SHADOWTRANCE_POST_PAUSE = 2

local ImmolateCastedAt       = 0
local ImmolateTargetGUID     = nil
local DoLock_OnCooldownUntil = 0
local IMMOLATE_POST_PAUSE    = 1

local DrainSoulCastedAt   = 0
local DrainSoulDuration   = 0
local DarkHarvestCastedAt = 0
local DarkHarvestDuration = 0

local SpellStartedName  = nil
local FacingFailedSpell = nil

local SHOOT_NAME        = "Shoot"
local IMMOLATE_NAME     = "Immolate"
local DRAIN_SOUL_NAME   = "Drain Soul"
local DARK_HARVEST_NAME = "Dark Harvest"

local DARK_HARVEST_DEBUFF_NAMES = {
  shadowVuln = "Shadow Vulnerability",
}

-- ===========================
-- Private helpers
-- ===========================

-- Returns the name of the spell currently being channeled, or nil.
-- Uses visualSpellId (index 2) + isChanneling (index 5) from nampower's
-- GetCurrentCastingInfo(). castingSpellId (index 1) is always nil for channels.
-- visualSpellId is stale (holds last-cast ID) when not channeling, so the
-- isChanneling guard is required.
local function GetChannelingSpellName()
  if not GetCurrentCastingInfo then return nil end
  local _, visualSpellId, _, _, isChanneling = GetCurrentCastingInfo()
  if isChanneling ~= 1 or not visualSpellId or visualSpellId == 0 then return nil end
  return SpellInfo and SpellInfo(visualSpellId) or nil
end

local function targetGuid(unit)
  local _, guid = UnitExists(unit or "target")
  return guid
end

local function HasMalediction()
  if not GetNumTalents then return false end
  for i = 1, GetNumTalents(1) do
    local name, _, _, _, currentRank = GetTalentInfo(1, i)
    if name == "Malediction" and currentRank > 0 then return true end
  end
  return false
end

local function GetPetSpellSlot(spellName)
  for slot = 1, 10 do
    local name = GetPetActionInfo(slot)
    if name and name == spellName then return slot end
  end
  return nil
end

-- Returns the config object currently bound to the action bar (combat config).
local function GetActiveCombatConfigObj()
  local combatName = AutoLock._combatConfigName or (AutoLockDB and AutoLockDB.activeConfig)
  if not combatName or not AutoLockDB or not AutoLockDB.configs then return nil end
  for _, c in ipairs(AutoLockDB.configs) do
    if c.name == combatName then return c end
  end
  return nil
end

-- ===========================
-- AutoLockEngine guard API
-- (consumed by spell conditions in AutoLockSpells.lua)
-- ===========================

function AutoLockEngine.IsPlayerMoving()
  if PlayerIsMoving then return PlayerIsMoving() == 1 end
  if MovementEvents then return MovementEvents:IsMoving() end
  return false
end

function AutoLockEngine.IsWandShooting()
  return WandShooting
end

function AutoLockEngine.IsShadowTranceProc()
  local hasBuff = AutoLock:HasAnyBuff("player", "Shadow Trance", "Spell_Shadow_Twilight")
  if hasBuff then
    local recentCast = (GetTime() - ShadowTranceCastedAt) <= SHADOWTRANCE_POST_PAUSE
    return not recentCast
  end
  return hasBuff
end

function AutoLockEngine.DrainSoulFinished()
  -- Primary: direct query via nampower (self-healing, no event desync).
  -- Fallback: event flag for when nampower is absent.
  local channelingName = GetChannelingSpellName()
  if channelingName ~= nil then
    return channelingName ~= DRAIN_SOUL_NAME
  end
  if not DrainSoulChanneling then return true end
  return (DrainSoulCastedAt + DrainSoulDuration) - GetTime() <= 0.04
end

function AutoLockEngine.DarkHarvestFinished()
  local channelingName = GetChannelingSpellName()
  if channelingName ~= nil then
    return channelingName ~= DARK_HARVEST_NAME
  end
  if not DarkHarvestChanneling then return true end
  return (DarkHarvestCastedAt + DarkHarvestDuration) - GetTime() <= 0.04
end

function AutoLockEngine.IsBlockedByDrainSoul(key)
  -- Primary: direct query.
  local channelingName = GetChannelingSpellName()
  local isDSChanneling = (channelingName == DRAIN_SOUL_NAME)
    or (channelingName == nil and DrainSoulChanneling)
  if not isDSChanneling then return false end
  if DrainSoulDuration > 0 and (GetTime() - DrainSoulCastedAt) >= (DrainSoulDuration - 0.04) then
    return false
  end
  local cfg = GetActiveCombatConfigObj()
  if not cfg then return true end
  if not cfg.drainSoulDots then return false end
  return cfg.drainSoulDots[key] ~= true
end

-- Returns true if the Immolate post-cast pause is still active on current target.
function AutoLockEngine.IsImmolatePostPauseActive()
  local tgtGuid = targetGuid("target")
  return DoLock_OnCooldownUntil > 0
    and tgtGuid == ImmolateTargetGUID
    and GetTime() < DoLock_OnCooldownUntil
end

function AutoLockEngine.IsDHInterruptDSEnabled()
  local cfg = GetActiveCombatConfigObj()
  if not cfg then return true end
  if cfg.darkHarvestInterruptsDS == nil then return true end
  return cfg.darkHarvestInterruptsDS == true
end

local function isDHNightfallAllowed(entry)
  if not (entry.priority == 1 and entry.name == "Shadow Bolt") then return false end
  local cfg = GetActiveCombatConfigObj()
  if not cfg then return false end
  return cfg.darkHarvestAllowNightfall == true
end

function AutoLockEngine.DarkHarvestDotsReady()
  local cfg = GetActiveCombatConfigObj()
  local _, tgtGuid = UnitExists("target")

  if cfg and cfg.darkHarvestRequireFullDotTime and Cursive then
    local dhDuration = AutoLock:GetSpellDurationByName("Dark Harvest")
    if dhDuration then
      local required = dhDuration * 1.3
      local guids = Cursive.curses.guids
      local function rem(name)
        local d = guids[tgtGuid] and guids[tgtGuid][name]
        return d and Cursive.curses:TimeRemaining(d) or 0
      end
      local dotSel = cfg.darkHarvestFullDotTimeDots or {}
      if dotSel.agony      ~= false and rem("curse of agony") < required then return false end
      if dotSel.corruption ~= false and rem("corruption")     < required then return false end
      if dotSel.siphonLife ~= false and rem("siphon life")    < required then return false end
    end
  end

  local req = cfg and cfg.darkHarvestDots
  if req and req.shadowVuln then
    if not AutoLock:HasDebuffByName("target", DARK_HARVEST_DEBUFF_NAMES.shadowVuln) then
      return false
    end
  end
  return true
end

-- ===========================
-- Test hooks (consumed by AutoLockTest.lua)
-- ===========================
function AutoLock:_testSetFacingFailedSpell(v)   FacingFailedSpell = v   end
function AutoLock:_testSetDrainSoulChanneling(v)  DrainSoulChanneling = v  end
function AutoLock:_testIsBlockedByDrainSoul(key)  return AutoLockEngine.IsBlockedByDrainSoul(key) end
function AutoLock:_testSetDrainSoulTiming(castedAt, duration)
  DrainSoulCastedAt = castedAt
  DrainSoulDuration = duration
end
function AutoLock:_testSetDarkHarvestChanneling(v) DarkHarvestChanneling = v end
function AutoLock:_testSetDarkHarvestTiming(castedAt, duration)
  DarkHarvestCastedAt = castedAt
  DarkHarvestDuration = duration
end

-- ===========================
-- Event handler
-- ===========================
local ef = CreateFrame("Frame")
ef:RegisterEvent("SPELLCAST_START")
ef:RegisterEvent("SPELLCAST_STOP")
ef:RegisterEvent("SPELLCAST_FAILED")
ef:RegisterEvent("SPELLCAST_INTERRUPTED")
ef:RegisterEvent("SPELLCAST_CHANNEL_START")
ef:RegisterEvent("SPELLCAST_CHANNEL_STOP")
ef:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
ef:RegisterEvent("START_AUTOREPEAT_SPELL")
ef:RegisterEvent("STOP_AUTOREPEAT_SPELL")
ef:RegisterEvent("BAG_UPDATE")
ef:RegisterEvent("SPELLS_CHANGED")
ef:RegisterEvent("UI_ERROR_MESSAGE")

ef:SetScript("OnEvent", function()
  local E = event

  if E == "SPELLCAST_START" then
    if SpellStartedName == DRAIN_SOUL_NAME then
      DrainSoulChanneling = true
      DrainSoulCastedAt   = GetTime()
      DrainSoulDuration   = AutoLock:GetSpellDurationByName("Drain Soul")
    elseif SpellStartedName == DARK_HARVEST_NAME then
      DarkHarvestChanneling = true
      DarkHarvestCastedAt   = GetTime()
      DarkHarvestDuration   = AutoLock:GetSpellDurationByName("Dark Harvest")
    elseif SpellStartedName == IMMOLATE_NAME then
      ImmolateTargetGUID = targetGuid("target")
    end

  elseif E == "SPELLCAST_STOP" then
    if SpellStartedName == IMMOLATE_NAME then
      ImmolateCastedAt       = GetTime()
      DoLock_OnCooldownUntil = ImmolateCastedAt + IMMOLATE_POST_PAUSE
    elseif SpellStartedName == "Shadow Bolt" and ShadowTrancePending then
      ShadowTranceCastedAt = GetTime()
    end
    DrainSoulChanneling        = false
    DarkHarvestChanneling      = false
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999

  elseif E == "SPELLCAST_FAILED" or E == "SPELLCAST_INTERRUPTED" then
    DarkHarvestChanneling      = false
    DrainSoulChanneling        = false
    WandShooting               = false
    DoLock_OnCooldownUntil     = 0
    ImmolateTargetGUID         = nil
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999

  elseif E == "SPELLCAST_CHANNEL_START" then
    if SpellStartedName == DRAIN_SOUL_NAME then
      DrainSoulChanneling = true
      DrainSoulCastedAt   = GetTime()
      DrainSoulDuration   = AutoLock:GetSpellDurationByName("Drain Soul")
    elseif SpellStartedName == DARK_HARVEST_NAME then
      DarkHarvestChanneling = true
      DarkHarvestCastedAt   = GetTime()
      DarkHarvestDuration   = AutoLock:GetSpellDurationByName("Dark Harvest")
    elseif SpellStartedName == SHOOT_NAME then
      WandShooting = true
    end

  elseif E == "SPELLCAST_CHANNEL_STOP" or E == "UNIT_SPELLCAST_CHANNEL_STOP" then
    DrainSoulChanneling        = false
    DarkHarvestChanneling      = false
    WandShooting               = false
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999

  elseif E == "START_AUTOREPEAT_SPELL" then
    WandShooting = true

  elseif E == "STOP_AUTOREPEAT_SPELL" then
    WandShooting = false

  elseif E == "BAG_UPDATE" then
    if not AutoLockDB or not AutoLockDB.settings or AutoLockDB.settings.autoDeleteShards ~= false then
      AutoLock:DeleteSoulShards()
    end

  elseif E == "SPELLS_CHANGED" then
    AutoLock:BuildKnownSpellSet()
    AutoLock:PrioScrollUpdate()

  elseif E == "UI_ERROR_MESSAGE" then
    if arg1 == "Target needs to be in front of you" or arg1 == SPELL_FAILED_UNIT_NOT_INFRONT then
      FacingFailedSpell = SpellStartedName
    end
  end
end)

-- ===========================
-- Combat snapshot (action-bar config, separate from SPELL_PRIORITY)
-- ===========================
COMBAT_SPELL_PRIORITY = {}

function AutoLock:_loadCombatSnapshot(configName)
  if not AutoLockDB or not AutoLockDB.configs then
    COMBAT_SPELL_PRIORITY = {}
    self._combatConfigName = nil
    return
  end
  for _, cfg in ipairs(AutoLockDB.configs) do
    if cfg.name == configName then
      COMBAT_SPELL_PRIORITY = {}
      local deletedKeys   = cfg.deletedSpells or {}
      local spellSettings = cfg.spells or {}
      for _, e in ipairs(SPELL_PRIORITY) do
        local key = (e.uitext or e.name or "?") .. "|" .. (e.type or "?")
        if not deletedKeys[key] then
          local entry = {}
          for k, v in pairs(e) do
            if k ~= "_deleted" then entry[k] = v end
          end
          local s = spellSettings[key]
          if s then
            entry.enabled = s.enabled
            if s.priority    ~= nil then entry.priority    = s.priority    end
            if s.refreshtime ~= nil then entry.refreshtime = s.refreshtime end
          end
          table.insert(COMBAT_SPELL_PRIORITY, entry)
        end
      end
      table.sort(COMBAT_SPELL_PRIORITY, function(a, b)
        return (a.priority or 99) < (b.priority or 99)
      end)
      self._combatConfigName = configName
      return
    end
  end
  COMBAT_SPELL_PRIORITY = {}
  self._combatConfigName = nil
end

-- ===========================
-- TryAction (private)
-- ===========================
local function TryAction(entry)
  local t = entry.target or "target"

  if entry.enabled == nil or entry.enabled == false then return false end

  -- Skip spell that just failed due to facing; clear flag so next press retries.
  if FacingFailedSpell and entry.name == FacingFailedSpell then
    FacingFailedSpell = nil
    return false
  end

  -- Nampower queue guard: prevent lower-priority spell from overwriting a
  -- higher-priority spell already queued in nampower's single-slot queue.
  if AutoLock._npQueuedThisCast then
    local chanName = GetChannelingSpellName()
    local isChanneling = (chanName == DRAIN_SOUL_NAME or chanName == DARK_HARVEST_NAME)
      or (chanName == nil and (DrainSoulChanneling or DarkHarvestChanneling))
    if not isChanneling then
      local queuedPrio = AutoLock._npQueuedPriority or 99999
      if (entry.priority or 99999) > queuedPrio then
        return false
      end
    end
  end

  -- Block everything while Dark Harvest is channeling (unless Nightfall override).
  if not AutoLockEngine.DarkHarvestFinished() then
    if not isDHNightfallAllowed(entry) then
      return false
    end
  end

  -- Spell-specific condition check.
  if entry.condition and not entry.condition(t, entry) then
    return false
  end

  if entry.type ~= "trinket" and entry.type ~= "pet" then
    local outOfRange = AutoLock:IsSpellOutOfRange(entry.name)
    if outOfRange == true then
      return false
    end

    local manaCost   = AutoLock:GetSpellManaCostByName(entry.name)
    local playerMana = UnitMana("player")
    if manaCost and AutoLockEngine.DrainSoulFinished() and playerMana < manaCost then
      if not AutoLockDB or not AutoLockDB.settings or AutoLockDB.settings.useLifeTap ~= false then
        -- Return true so the rotation loop stops here: Life Tap holds the
        -- nampower queue slot and DS cannot overwrite it on this same press.
        CastSpellByName("Life Tap", t)
        return true
      end
      return false
    end
  end

  local ok = false
  local activeChannel = GetChannelingSpellName()
    or (DrainSoulChanneling and DRAIN_SOUL_NAME)
    or (DarkHarvestChanneling and DARK_HARVEST_NAME)
  if entry.type == "cast" then
    if activeChannel and ChannelStopCastingNextTick then
      ChannelStopCastingNextTick()
    end
    CastSpellByName(entry.name, t)
    if entry.name == "Shadow Bolt" and AutoLock:HasAnyBuff("player", "Shadow Trance", "Spell_Shadow_Twilight") then
      ShadowTrancePending = true
    else
      ShadowTrancePending = false
    end
    ok = true

  elseif entry.type == "curse" then
    if Cursive then
      if activeChannel and ChannelStopCastingNextTick then
        if Cursive.curses then
          local _, tGuid = UnitExists(t)
          local rt = entry.refreshtime or 1
          if not Cursive.curses:HasCurse(string.lower(entry.name), tGuid, rt, HasMalediction() and 1 or 0) then
            ChannelStopCastingNextTick()
          end
        end
      end
      ok = Cursive:Curse(entry.name, t, { refreshtime = entry.refreshtime or 1 })
    end

  elseif entry.type == "trinket" then
    ok = entry.use()

  elseif entry.type == "pet" then
    local slot = GetPetSpellSlot(entry.name)
    if slot then CastPetAction(slot); ok = true end
  end

  if ok then
    SpellStartedName = entry.name
    if entry.type ~= "curse" then
      -- Non-curse cast queued in nampower: block lower-priority (higher-number)
      -- spells from overwriting this slot before SPELLCAST_STOP clears the flag.
      AutoLock._npQueuedThisCast = true
      AutoLock._npQueuedPriority = entry.priority or 99999
    else
      -- Curse fired: clear any stale cast-type NP flag so DS/DH are not
      -- blocked after all curses are applied.
      -- Background: a cast-type spell (Death Coil prio=20, Shadowburn prio=21)
      -- may have set the flag on a previous press.  Curses (prio 6-9) pass the
      -- NP guard unblocked, but once all curses are up, DS (prio=23>20) and
      -- DH (prio=22>20) would be blocked until SPELLCAST_STOP fires (~1 GCD
      -- later), causing a visible rotation hang.  Clearing here is safe: by
      -- the time all curses are applied the previously queued cast will have
      -- executed, and DO NOT set the flag for curses (see note below).
      -- NOTE: setting the flag for curses would cause a different permanent
      -- freeze: curse already-on-target → condition returns false → NP guard
      -- blocks everything → no SPELLCAST_STOP ever arrives for a curse.
      AutoLock._npQueuedThisCast = false
      AutoLock._npQueuedPriority = 99999
    end
  end
  return ok
end

-- ===========================
-- Public rotation entry points
-- ===========================

-- Used by unit tests to run TryAction on an arbitrary list.
function AutoLock:_testRunList(list)
  for _, entry in ipairs(list) do
    if TryAction(entry) then return entry.name end
  end
  return nil
end

-- Main entry point called from action-bar macros.
-- configName: when provided, executes that config's isolated snapshot.
function AutoLock:DoAutoLock(configName)
  if configName then
    if self._combatConfigName ~= configName then
      self:_loadCombatSnapshot(configName)
    end
    for _, entry in ipairs(COMBAT_SPELL_PRIORITY) do
      if TryAction(entry) then return end
    end
  else
    -- Fallback (no config name): restore combat config if UI is previewing another.
    if AutoLockDB and AutoLockDB.activeConfig
       and AutoLock._loadedConfigName ~= AutoLockDB.activeConfig
       and AutoLock._reloadActiveCombatConfig then
      AutoLock:_reloadActiveCombatConfig()
    end
    for _, entry in ipairs(SPELL_PRIORITY) do
      if TryAction(entry) then return end
    end
  end
end

-- Debug: print all GetCurrentCastingInfo() return values + current channel flags.
-- Usage: /run AutoLock:DebugCastingInfo()
-- Run this while idle, while casting, and while channeling DS/DH.
function AutoLock:DebugCastingInfo()
  if not GetCurrentCastingInfo then
    AutoLockLog.Warning("DebugCastingInfo: GetCurrentCastingInfo not available (nampower missing?)")
    return
  end
  local castingSpellId, visualSpellId, autoRepeatSpellId, isCasting, isChanneling, pendingOnSwing, isAutoAttacking
    = GetCurrentCastingInfo()

  local function res(id)
    if not id or id == 0 then return "nil" end
    local name = nil
    if SpellInfo then name = SpellInfo(id) end
    if not name and GetSpellNameAndRankForId then name = GetSpellNameAndRankForId(id) end
    if name then return id .. " (" .. name .. ")" end
    return tostring(id)
  end

  AutoLockLog.Info("=== DebugCastingInfo ===")
  AutoLockLog.Info("  castingSpellId   = " .. res(castingSpellId))
  AutoLockLog.Info("  visualSpellId    = " .. res(visualSpellId))
  AutoLockLog.Info("  autoRepeatSpellId= " .. res(autoRepeatSpellId))
  AutoLockLog.Info("  isCasting        = " .. tostring(isCasting))
  AutoLockLog.Info("  isChanneling     = " .. tostring(isChanneling))
  AutoLockLog.Info("  pendingOnSwing   = " .. tostring(pendingOnSwing))
  AutoLockLog.Info("  isAutoAttacking  = " .. tostring(isAutoAttacking))
  AutoLockLog.Info("  [flags] DS=" .. tostring(DrainSoulChanneling)
    .. " DH=" .. tostring(DarkHarvestChanneling)
    .. " Wand=" .. tostring(WandShooting))
end

-- Debug: print remaining DoT timers for Dark Harvest.
-- Usage: /run AutoLock:PrintDotTimers()
function AutoLock:PrintDotTimers()
  if not Cursive then AutoLockLog.Warning("PrintDotTimers: Cursive not loaded"); return end
  local _, guid = UnitExists("target")
  if not guid then AutoLockLog.Warning("PrintDotTimers: no target"); return end

  local dhDuration = AutoLock:GetSpellDurationByName("Dark Harvest")
  local required   = dhDuration and (dhDuration * 1.3) or nil

  local dots = {
    { key = "curse of agony", label = "Curse of Agony" },
    { key = "corruption",     label = "Corruption"     },
    { key = "siphon life",    label = "Siphon Life"    },
  }

  AutoLockLog.Info("=== Dot Timers (target) ===")
  for _, dot in ipairs(dots) do
    local curseData = Cursive.curses.guids[guid] and Cursive.curses.guids[guid][dot.key]
    if curseData then
      local remaining = Cursive.curses:TimeRemaining(curseData)
      local suffix = ""
      if required then
        if remaining >= required then
          suffix = " |cff00cc00OK|r (>= " .. string.format("%.1f", required) .. "s needed)"
        else
          suffix = " |cffff4444LOW|r (need " .. string.format("%.1f", required) .. "s)"
        end
      end
      AutoLockLog.Info(dot.label .. ": " .. string.format("%.1f", remaining) .. "s" .. suffix)
    else
      AutoLockLog.Info(dot.label .. ": |cffaaaaaamissing|r")
    end
  end

  if dhDuration then
    local rawMs = GetSpellSlotTypeIdForName and GetSpellDuration and (function()
      local _, _, spellId = GetSpellSlotTypeIdForName("Dark Harvest")
      return spellId and GetSpellDuration(spellId)
    end)() or nil
    local rawInfo = rawMs and ("  [raw: " .. rawMs .. "ms]") or ""
    AutoLockLog.Info("DH duration: " .. string.format("%.2f", dhDuration) .. "s" .. rawInfo
      .. "  |  Required: " .. string.format("%.2f", required) .. "s")
  else
    AutoLockLog.Warning("DH duration: unknown (spell not found)")
  end
end
