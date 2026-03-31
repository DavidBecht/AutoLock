local L = AceLibrary("AceLocale-2.2"):new("AutoLock")

AutoLock = AceLibrary("AceAddon-2.0"):new(
  "AceEvent-2.0",
  "AceConsole-2.0",
	"AceHook-2.1"
)

function AutoLock:OnInitialize()
  self:RegisterChatCommand({"/autolock"}, {
    handler = self,
    type = "group",
    args = {
      show = {
        name = "show",
        desc = "Show the UI",
        type = "execute",
        func = function() AutoLock:ShowUI() end
      },
      hide = {
        name = "hide",
        desc = "Hide the UI",
        type = "execute",
        func = function() AutoLock:HideUI() end
      },
      toggle = {
        name = "toggle",
        desc = "Toggle the UI",
        type = "execute",
        func = function() AutoLock:ToggleUI() end
      },
      debug = {
        name = "debug",
        desc = "Print diagnostic info to chat",
        type = "execute",
        func = function()
          AutoLockLog.Info("=== AutoLock Debug ===")
          AutoLockLog.Info("SPELL_PRIORITY entries: " .. table.getn(SPELL_PRIORITY))

          -- Count how many would pass the current filter
          local visibleCount = 0
          local hiddenDisabled = 0
          local hiddenUnknown  = 0
          local ks = AutoLock.KnownSpells
          for _, e in ipairs(SPELL_PRIORITY) do
            if not AutoLockUI_ShowDisabled and e.enabled == false then
              hiddenDisabled = hiddenDisabled + 1
            else
              local passKnown = true
              local s2 = AutoLockDB and AutoLockDB.settings
              if s2 and s2.hideUnknownSpells and ks and next(ks) ~= nil and not ks[e.name] then
                passKnown = false
                hiddenUnknown = hiddenUnknown + 1
              end
              if passKnown then visibleCount = visibleCount + 1 end
            end
          end
          AutoLockLog.Info("Would show: " .. visibleCount .. " | hidden disabled: " .. hiddenDisabled .. " | hidden unknown: " .. hiddenUnknown)

          -- KnownSpells
          local ksCount = 0
          if AutoLock.KnownSpells then
            for _ in pairs(AutoLock.KnownSpells) do ksCount = ksCount + 1 end
          end
          AutoLockLog.Info("KnownSpells count: " .. ksCount)

          -- Settings
          local s = AutoLockDB and AutoLockDB.settings
          AutoLockLog.Info("hideUnknownSpells: " .. tostring(s and s.hideUnknownSpells))
          AutoLockLog.Info("ShowDisabled: " .. tostring(AutoLockUI_ShowDisabled))
          AutoLockLog.Info("TypeFilter: " .. tostring(AutoLockTypeFilter))
          AutoLockLog.Info("SearchText: '" .. tostring(AutoLockSearchText) .. "'")
          AutoLockLog.Info("activeConfig: " .. tostring(AutoLockDB and AutoLockDB.activeConfig))

          -- Print first 5 SPELL_PRIORITY entries
          AutoLockLog.Info("First 5 SPELL_PRIORITY entries:")
          for i = 1, math.min(5, table.getn(SPELL_PRIORITY)) do
            local e = SPELL_PRIORITY[i]
            AutoLockLog.Info("  [" .. i .. "] prio=" .. tostring(e.priority) .. " name=" .. tostring(e.name) .. " enabled=" .. tostring(e.enabled))
          end
        end
      },
    }
  })
end

function AutoLock:BuildKnownSpellSet()
  local known = {}
  for i = 1, 1024 do
    local name = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    known[name] = true
  end
  if BOOKTYPE_PET then
    for i = 1, 200 do
      local name = GetSpellName(i, BOOKTYPE_PET)
      if not name then break end
      known[name] = true
    end
  end
  for i = 1, 10 do
    local name = GetPetActionInfo(i)
    if type(name) == "string" and name ~= "" then known[name] = true end
  end
  self.KnownSpells = known
end

function AutoLock:OnEnable()
  AutoLockLog.Info("Loaded. SPELL_PRIORITY has " .. table.getn(SPELL_PRIORITY) .. " entries. Use /autolock toggle")

  if GetLocale and GetLocale() ~= "enUS" then
    AutoLockLog.Warning("AutoLock uses English spell names. Non-English clients may have issues with spell detection.")
  end

  if not GetPlayerBuffID or not SpellInfo then
    AutoLockLog.Warning("SuperWoW not detected. Buff-based features (Shadow Trance, buff tracking) will not work.")
  end

  if not Cursive then
    AutoLockLog.Warning("Cursive not found. Curse spells in the rotation will be skipped.")
  end

  if not GetCurrentCastingInfo then
    AutoLockLog.Warning("Nampower not detected. Spell queueing conflicts possible when spam-casting.")
  end

	self:InitUI()
	self:BuildKnownSpellSet()
end

function SpellNameToId(buff)
  for i=1,1000 do
    local name, rank, id = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    if name == buff then
      local nextName = GetSpellName(i+1, BOOKTYPE_SPELL)  -- only the first return (name) is assigned
      if nextName ~= buff then
        if id then return id end                           -- some clients provide id here
        return i, rank                                           -- fallback: return slot index
      end
    end
  end
end

function SpellIdToName(id)
  for i=1,1000 do
    local name, rank, spellId = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    if spellId == id then
      return name
    end
  end
end

local function GetPetSpellSlot(spellName)
    for slot = 1, 10 do
        local name = GetPetActionInfo(slot)
        if name and name == spellName then
            return slot
        end
    end
    return nil
end

local function targetGuid(unit)
  local _, guid = UnitExists(unit or "target")
  return guid
end

local function HasMalediction()
  if not GetNumTalents then return false end
  for i = 1, GetNumTalents(1) do  -- Tab 1 = Affliction
    local name, _, _, _, currentRank = GetTalentInfo(1, i)
    if name == "Malediction" and currentRank > 0 then
      return true
    end
  end
  return false
end

local ShadowTranceCastedAt = 0
local SHADOWTRANCE_POST_PAUSE = 2
local ImmolateCastedAt = 0
local ImmolateTargetGUID = nil
local DoLock_OnCooldownUntil = 0  
local IMMOLATE_POST_PAUSE = 1  
local SHOOT_NAME   = "Shoot"
local IMMOLATE_NAME = "Immolate"
local DRAIN_SOUL_NAME = "Drain Soul"
local DARK_HARVEST_NAME = "Dark Harvest"
local SpellStartedName = nil
local FacingFailedSpell = nil

local WandShooting = false
local DrainSoulChanneling = false
local DarkHarvestChanneling = false
local ShadowTrancePending = false

local DrainSoulCastedAt = 0
local DrainSoulDuration = 0

local DarkHarvestCastedAt = 0
local DarkHarvestDuration = 0

-- Cursive-tracked curses (use Cursive.curses:HasCurse)
local DARK_HARVEST_CURSE_NAMES = {
  agony      = "curse of agony",
  corruption = "corruption",
  siphonLife = "siphon life",
}
-- Curse-slot alternatives: CoS and CoA are mutually exclusive (share one debuff slot).
-- If the primary curse is absent but the alternative is active, the requirement is met.
local DARK_HARVEST_CURSE_ALTERNATIVES = {
  agony = "curse of shadow",
}
-- Non-Cursive debuffs (use UnitDebuff + SpellInfo via SuperWoW)
local DARK_HARVEST_DEBUFF_NAMES = {
  shadowVuln = "Shadow Vulnerability",
}

-- Returns true if the given curse key (agony/corruption/siphonLife) is blocked
-- during Drain Soul channeling. A curse is allowed only when its checkbox is
-- explicitly checked (drainSoulDots[key] == true); otherwise it is blocked.
local function isBlockedByDrainSoul(key)
  if not DrainSoulChanneling then return false end
  -- Channel flag may still be set after the channel ends (CHANNEL_STOP event not yet fired).
  -- Treat as finished so curses are not blocked when DS restarts is imminent.
  if DrainSoulDuration > 0 and (GetTime() - DrainSoulCastedAt) >= (DrainSoulDuration - 0.04) then
    return false
  end
  local combatName = AutoLock._combatConfigName or (AutoLockDB and AutoLockDB.activeConfig)
  if not combatName or not AutoLockDB or not AutoLockDB.configs then return true end
  for _, c in ipairs(AutoLockDB.configs) do
    if c.name == combatName then
      if not c.drainSoulDots then return false end  -- no config = all allowed (default on)
      return c.drainSoulDots[key] ~= true
    end
  end
  return true
end


-- Test hooks: allow unit tests to control internal state without WoW events.
function AutoLock:_testSetFacingFailedSpell(v)
  FacingFailedSpell = v
end
function AutoLock:_testSetDrainSoulChanneling(v)
  DrainSoulChanneling = v
end
function AutoLock:_testIsBlockedByDrainSoul(key)
  return isBlockedByDrainSoul(key)
end
function AutoLock:_testSetDrainSoulTiming(castedAt, duration)
  DrainSoulCastedAt  = castedAt
  DrainSoulDuration  = duration
end
function AutoLock:_testSetDarkHarvestChanneling(v)
  DarkHarvestChanneling = v
end
function AutoLock:_testSetDarkHarvestTiming(castedAt, duration)
  DarkHarvestCastedAt = castedAt
  DarkHarvestDuration = duration
end

-- Returns true if Dark Harvest is allowed to interrupt an active Drain Soul
-- channel per config setting. Defaults to true (existing behaviour).
local function isDHInterruptDSEnabled()
  local combatName = AutoLock._combatConfigName or (AutoLockDB and AutoLockDB.activeConfig)
  if not combatName or not AutoLockDB or not AutoLockDB.configs then return true end
  for _, c in ipairs(AutoLockDB.configs) do
    if c.name == combatName then
      if c.darkHarvestInterruptsDS == nil then return true end
      return c.darkHarvestInterruptsDS == true
    end
  end
  return true
end

-- Returns true if Nightfall (Shadow Trance Shadow Bolt) is allowed to
-- interrupt a running Dark Harvest channel per config setting.
local function isDHNightfallAllowed(entry)
  if not (entry.priority == 1 and entry.name == "Shadow Bolt") then return false end
  local combatName = AutoLock._combatConfigName or (AutoLockDB and AutoLockDB.activeConfig)
  if not combatName or not AutoLockDB or not AutoLockDB.configs then return false end
  for _, c in ipairs(AutoLockDB.configs) do
    if c.name == combatName then
      return c.darkHarvestAllowNightfall == true
    end
  end
  return false
end

local function darkHarvestDotsReady()
  local cfg = nil
  local combatName = AutoLock._combatConfigName or (AutoLockDB and AutoLockDB.activeConfig)
  if combatName and AutoLockDB and AutoLockDB.configs then
    for _, c in ipairs(AutoLockDB.configs) do
      if c.name == combatName then
        cfg = c
        break
      end
    end
  end

  local _, targetGuid = UnitExists("target")

  -- Require enough dot time remaining for maximum DH damage
  if cfg and cfg.darkHarvestRequireFullDotTime and Cursive then
    local dhDuration = AutoLock:GetSpellDurationByName("Dark Harvest")
    if dhDuration then
      local required = dhDuration * 1.3
      local guids = Cursive.curses.guids
      local function rem(name)
        local d = guids[targetGuid] and guids[targetGuid][name]
        return d and Cursive.curses:TimeRemaining(d) or 0
      end
      -- nil means default-on (not yet explicitly unchecked)
      local dotSel = cfg.darkHarvestFullDotTimeDots or {}
      if dotSel.agony      ~= false and rem("curse of agony") < required then return false end
      if dotSel.corruption ~= false and rem("corruption")     < required then return false end
      if dotSel.siphonLife ~= false and rem("siphon life")    < required then return false end
    end
  end

  -- shadowVuln (non-Cursive debuff, configurable via DH Cfg)
  local req = cfg and cfg.darkHarvestDots
  if req and req.shadowVuln then
    if not AutoLock:HasDebuffByName("target", DARK_HARVEST_DEBUFF_NAMES.shadowVuln) then
      return false
    end
  end

  return true
end

local f = CreateFrame("Frame")
-- klassische Cast-Events
f:RegisterEvent("SPELLCAST_START")
f:RegisterEvent("SPELLCAST_STOP")
f:RegisterEvent("SPELLCAST_FAILED")
f:RegisterEvent("SPELLCAST_INTERRUPTED")
-- Channel (manche Clients zeigen Shoot als Channel)
f:RegisterEvent("SPELLCAST_CHANNEL_START")
f:RegisterEvent("SPELLCAST_CHANNEL_STOP")
f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
-- Auto-Repeat (Wand/Auto Shot)
f:RegisterEvent("START_AUTOREPEAT_SPELL")
f:RegisterEvent("STOP_AUTOREPEAT_SPELL")
f:RegisterEvent("BAG_UPDATE")
f:RegisterEvent("SPELLS_CHANGED")
f:RegisterEvent("UI_ERROR_MESSAGE")

f:SetScript("OnEvent", function()
  local E = event

  if E == "SPELLCAST_START" then
		if SpellStartedName == DRAIN_SOUL_NAME then
      DrainSoulChanneling = true
			DrainSoulCastedAt = GetTime()
			DrainSoulDuration = AutoLock:GetSpellDurationByName("Drain Soul")
			-- print("Channel:", DrainSoulChanneling)
		elseif SpellStartedName == DARK_HARVEST_NAME then
			DarkHarvestChanneling = true
			DarkHarvestCastedAt = GetTime()
			DarkHarvestDuration = AutoLock:GetSpellDurationByName("Dark Harvest")
		elseif SpellStartedName == IMMOLATE_NAME then
			ImmolateTargetGUID = targetGuid("target")
		end

  elseif E == "SPELLCAST_STOP" then
    if SpellStartedName == IMMOLATE_NAME then
      ImmolateCastedAt = GetTime()
      DoLock_OnCooldownUntil = ImmolateCastedAt + IMMOLATE_POST_PAUSE
	elseif SpellStartedName == "Shadow Bolt" and ShadowTrancePending then
			ShadowTranceCastedAt = GetTime()
    end
    DrainSoulChanneling = false
		DarkHarvestChanneling = false
		AutoLock._npQueuedThisCast = false
		AutoLock._npQueuedPriority = 99999

  elseif E == "SPELLCAST_FAILED" or E == "SPELLCAST_INTERRUPTED" then
		DarkHarvestChanneling = false
		DrainSoulChanneling = false
		WandShooting = false
		DoLock_OnCooldownUntil = 0
		ImmolateTargetGUID = nil
		AutoLock._npQueuedThisCast = false
		AutoLock._npQueuedPriority = 99999

  elseif E == "SPELLCAST_CHANNEL_START" then
    if SpellStartedName == DRAIN_SOUL_NAME then
        DrainSoulChanneling = true
        DrainSoulCastedAt = GetTime()
				DrainSoulDuration = AutoLock:GetSpellDurationByName("Drain Soul")
				-- print("Channel:", DrainSoulChanneling)
    elseif SpellStartedName == DARK_HARVEST_NAME then
        DarkHarvestChanneling = true
				DarkHarvestCastedAt = GetTime()
				DarkHarvestDuration = AutoLock:GetSpellDurationByName("Dark Harvest")
    elseif SpellStartedName == SHOOT_NAME then
        WandShooting = true
    end

	elseif E == "SPELLCAST_CHANNEL_STOP" or E == "UNIT_SPELLCAST_CHANNEL_STOP" then
			DrainSoulChanneling = false
			DarkHarvestChanneling = false
			WandShooting = false
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
		if frame and frame:IsShown() then AutoLock:PrioScrollUpdate() end  -- refresh list now that KnownSpells is current

	elseif E == "UI_ERROR_MESSAGE" then
		-- If a spell failed because the target is not in front, continue the rotation
		-- so higher-priority procs (e.g. Nightfall) don't silently block the next spell.
		if arg1 == "Target needs to be in front of you" or arg1 == SPELL_FAILED_UNIT_NOT_INFRONT then
			FacingFailedSpell = SpellStartedName
			-- AutoLock._npQueuedThisCast = false
			-- AutoLock._npQueuedPriority = 99999
		end
	end
end)

-- =========================
-- Priority-based spell list
-- =========================
-- Give each spell a "priority" number. Lower = higher priority.
-- You can change just the numbers instead of reordering the table.

-- Problem 3: Movement detection — prefer Nampower's direct C-side query over
-- the 100ms map-position polling in Movement.lua when available.
local function IsPlayerMoving()
  if PlayerIsMoving then return PlayerIsMoving() == 1 end
  if MovementEvents then return MovementEvents:IsMoving() end
  return false
end

local function IsShadowTranceProc()
    local hasBuff = AutoLock:HasAnyBuff("player", "Shadow Trance", "Spell_Shadow_Twilight")
		if hasBuff then
			local now = GetTime()
			local recentCast = ((now - ShadowTranceCastedAt) <= SHADOWTRANCE_POST_PAUSE)
			return not recentCast
		end
    return hasBuff
end

local function drainSoulChannelingFinished()
	if not DrainSoulChanneling then return true end
	-- Nampower can authoritatively tell us if a channel is still active.
	-- isChanneling is the 5th return value of GetCurrentCastingInfo().
	if GetCurrentCastingInfo then
		local _,_,_,_, isChanneling = GetCurrentCastingInfo()
		if not isChanneling or isChanneling == 0 then
			DrainSoulChanneling = false
			return true
		end
	end
	local remain = (DrainSoulCastedAt + DrainSoulDuration) - GetTime()
	return (remain <= 0.04)
end

local function darkHarvestChannelingFinished()
	if not DarkHarvestChanneling then return true end
	-- isChanneling is the 5th return value of GetCurrentCastingInfo().
	if GetCurrentCastingInfo then
		local _,_,_,_, isChanneling = GetCurrentCastingInfo()
		if not isChanneling or isChanneling == 0 then
			DarkHarvestChanneling = false
			return true
		end
	end
	local remain = (DarkHarvestCastedAt + DarkHarvestDuration) - GetTime()
	return (remain <= 0.04)
end

SPELL_PRIORITY = {
 {
    name = "Shadow Bolt",
    type = "cast",
    priority = 1,
    target = "target",
    condition = function(unit)
      return IsShadowTranceProc()
    end,
    uitext  = "Shadow Trance (Shadow Bolt)",
    enabled = true,
  },
	
	{
    name = "Firebolt",
    type = "pet",
    priority = 2,
    target = "target",
    enabled = true,
    condition = function()
        return UnitExists("target")   -- nur wenn Target existiert
           and not UnitIsDead("pet")  -- Pet lebt
           and UnitExists("pet")      -- Pet existiert
    end
	},
	
	{
		name = "Trinket Slot 1",
		type = "trinket",
		priority = 3,
    target = "target",
		condition = function(unit)
			return AutoLock:IsTrinketReady(13) and UnitExists("target")
    end,
		use = function()
			UseInventoryItem(13)
			return true
		end,
		enabled = false,
	},
	
	{
		name = "Trinket Slot 2",
		type = "trinket",
		priority = 4,
    target = "target",
		condition = function(unit)
			return AutoLock:IsTrinketReady(14) and UnitExists("target")
    end,
		use = function()
			UseInventoryItem(14)
			return true
		end,
		enabled = false,
	},

  
	{ name = "Curse of Shadow", type = "curse", priority = 6, refreshtime = 0, target = "target", enabled = true,
    condition = function(unit)
      if isBlockedByDrainSoul("agony") then return false end
      return true
    end },
  { name = "Curse of Agony",  type = "curse", priority = 7, refreshtime = 0, target = "target", enabled = true,
    condition = function(unit)
      if isBlockedByDrainSoul("agony") then return false end
      return true
    end },
  { name = "Corruption",      type = "curse", priority = 8, refreshtime = 0, target = "target", enabled = true,
    condition = function(unit) return not isBlockedByDrainSoul("corruption") end },
  { name = "Siphon Life",
		type = "curse",
		priority = 9,
		refreshtime = 0,
		target = "target",
		enabled = true,
		condition = function(unit)
			return not isBlockedByDrainSoul("siphonLife")
		end
	},

  -- Situative Warlock Curses (bei Bedarf aktivieren/umsortieren)
  { name = "Curse of Recklessness", type = "curse", priority = 10, refreshtime = 0, target = "target", enabled = false },
  { name = "Curse of Weakness",     type = "curse", priority = 11, refreshtime = 0, target = "target", enabled = false },
  { name = "Curse of Tongues",      type = "curse", priority = 12, refreshtime = 0, target = "target", enabled = false },
  { name = "Curse of the Elements", type = "curse", priority = 13, refreshtime = 0, target = "target", enabled = false },
  { name = "Curse of Doom",         type = "curse", priority = 15, refreshtime = 0, target = "target", enabled = false },
	
	{ 
		name = "Soul Fire",     
		type = "cast",  
		priority = 17, 
		target = "target", 
		enabled = false,
		condition = function(unit)
			if IsPlayerMoving() then return false end
			local onCD, rankStr = AutoLock:IsOnCooldown("Soul Fire")
			if onCD then return false end
			return true
		end,
	},
	
	{ 
		name = "Immolate",        
		type = "curse", 
		priority = 18, 
		refreshtime = 1, 
		target = "target",
		enabled = false,
    condition = function(unit)
			local _targetGUID = targetGuid("target")
			if DoLock_OnCooldownUntil > 0 and _targetGUID == ImmolateTargetGUID then
				if GetTime() < DoLock_OnCooldownUntil then return false end
			end
      if IsPlayerMoving() then return false end
      return true
    end,
    
  },
	
	{ 
		name = "Conflagrate",     
		type = "cast",  
		priority = 19, 
		target = "target", 
		enabled = false,
		condition = function(unit)
			if IsPlayerMoving() then return false end
			local onCD, rankStr = AutoLock:IsOnCooldown("Conflagrate")
			if onCD then return false end
			return true
		end,
	},
	
	{ 
		name = "Death Coil",     
		type = "cast",  
		priority = 20, 
		target = "target", 
		enabled = true,
		condition = function(unit)
			local onCD, rankStr = AutoLock:IsOnCooldown("Death Coil")

			return (onCD == false)
		end,
	},
	
	{ 
		name = "Shadowburn",     
		type = "cast",  
		priority = 21, 
		target = "target", 
		enabled = true,
		condition = function(unit)
			local onCD, rankStr = AutoLock:IsOnCooldown("Shadowburn")
	
			return (onCD == false)
		end,
	},

	{ name = "Dark Harvest",
		type = "cast",
		priority = 22,
		target = "target",
		enabled = false,
		condition = function(unit)
			if IsPlayerMoving() then return false end
			local onCD, rankStr = AutoLock:IsOnCooldown("Dark Harvest")
			if onCD then return false end
			if not darkHarvestDotsReady() then return false end
			if not drainSoulChannelingFinished() and not isDHInterruptDSEnabled() then
				return false
			end
			return darkHarvestChannelingFinished()
		end,
	},
	
	{ name = "Drain Soul",
		type = "cast",
		priority = 23,
		target = "target",
		enabled = true,
		condition = function(unit)
			if IsPlayerMoving() then return false end
			return drainSoulChannelingFinished()
		end,
	},

  -- Füllzauber / Nuke
  { 
		name = "Shadow Bolt",     
		type = "cast",  
		priority = 30, 
		target = "target", 
		enabled = false,
		condition = function(unit)
			if IsPlayerMoving() then return false end
			return true
		end,
	},
	
	
	
	{ 
		name = "Searing Pain",     
		type = "cast",  
		priority = 32, 
		target = "target", 
		enabled = false,
		condition = function(unit)
			if IsPlayerMoving() then return false end
			return true
		end,
	},
	
	
  -- Wand als Fallback (ganz unten)
  {
		name      = SHOOT_NAME,
		type      = "cast",
		priority  = 99,                  -- dorthin, wo du Shoot in der Prio willst
		target    = "target",
		uitext    = "Shoot (Wand)",
		condition = function(unit)
			if WandShooting then return false end   -- Kern: nicht doppelt starten
			if IsPlayerMoving() then return false end -- optional
			return true
		end,
		enabled = false,
	},
}

-- Sort by priority once (ascending)
table.sort(SPELL_PRIORITY, function(a, b)
  return (a.priority or 99) < (b.priority or 99)
end)

-- Separate snapshot for the action-bar combat rotation.
-- Built from a saved config; never affected by UI preview/selection.
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

-- =========================
-- Rotation runner
-- =========================
local function TryAction(entry)
  local t = entry.target or "target"

  -- Skip if not enabled
  if entry.enabled == nil or entry.enabled == false then return false end
  -- Skip spell that just failed due to facing; clear so the next press retries it
  if FacingFailedSpell and entry.name == FacingFailedSpell then
    FacingFailedSpell = nil
    return false
  end
  -- Nampower queue guard: the nampower GCD queue is a single slot that is
  -- overwritten on every CastSpellByName call (last-write-wins).  To prevent
  -- a lower-priority spell from replacing a higher-priority spell that is
  -- already queued, skip any spell whose priority is >= the queued priority.
  -- Only a spell with STRICTLY higher priority (smaller number) is allowed
  -- through.  The guard is lifted while a channel is active because channels
  -- clear _npQueuedThisCast via SPELLCAST_STOP and the channel guards take over.
  if AutoLock._npQueuedThisCast then
    local isChanneling = DrainSoulChanneling or DarkHarvestChanneling
    if not isChanneling then
      local queuedPrio = AutoLock._npQueuedPriority or 99999
      if (entry.priority or 99999) > queuedPrio then return false end
    end
  end

  -- Skip if DarkHarvest is Channeling (unless Nightfall override is active)
	if not darkHarvestChannelingFinished() then
		if not isDHNightfallAllowed(entry) then return false end
	end
	
  -- Skip if condition fails
  if entry.condition and not entry.condition(t) then return false end

	if entry.type ~= "trinket" and entry.type ~= "pet" then
		-- Skip if spell is not in range
		local outOfRange = AutoLock:IsSpellOutOfRange(entry.name)
		if outOfRange == true then
			return false
		end
		-- outOfRange == nil means no range data available (spell not on action bar,
		-- Nampower returned -1). We proceed and let the server reject if out of range.
		
		local manaCostNextSpell =  AutoLock:GetSpellManaCostByName(entry.name)
		local playerMana = UnitMana("player")
		
		-- Check player mana and may cast next spell
		if manaCostNextSpell and drainSoulChannelingFinished() and playerMana < manaCostNextSpell then
			if not AutoLockDB or not AutoLockDB.settings or AutoLockDB.settings.useLifeTap ~= false then
				CastSpellByName("Life Tap", t)
			end
			if playerMana < manaCostNextSpell then
				-- life tap not possible -> too less health (or disabled in settings)
				return false
			end
		end
	end 
	
	local ok = false
  if entry.type == "cast" then
    -- Interrupt any active channel before casting a higher-priority spell.
    -- ChannelStopCastingNextTick() signals nampower to cancel the channel on
    -- its next update; we must call it before CastSpellByName so nampower's
    -- queue accepts the new spell immediately.
    if (DrainSoulChanneling or DarkHarvestChanneling) and ChannelStopCastingNextTick then
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
    -- Only call ChannelStopCastingNextTick if the curse genuinely needs to be
    -- cast right now (HasCurse pre-check). This prevents interrupting a
    -- DS/DH channel for a no-op curse (already up / refreshtime not met).
    if Cursive then
      if (DrainSoulChanneling or DarkHarvestChanneling) and ChannelStopCastingNextTick then
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
      if slot then
        CastPetAction(slot)
        ok = true
      end
  end
  if ok then
    SpellStartedName = entry.name
    AutoLock._npQueuedThisCast = true
    AutoLock._npQueuedPriority = entry.priority or 99999
  end
  return ok
end

-- Runs TryAction on each entry; returns the name of the first spell that fires, or nil.
-- Must be defined after TryAction (local function) to capture it as an upvalue.
function AutoLock:_testRunList(list)
  for _, entry in ipairs(list) do
    if TryAction(entry) then return entry.name end
  end
  return nil
end

-- =========================
-- Public entry point
-- =========================
-- configName (optional): when provided, executes that config's snapshot
-- without affecting SPELL_PRIORITY or the UI selection.
-- Macros generated by AutoLock always pass a configName.
function AutoLock:DoAutoLock(configName)
  if configName then
    if self._combatConfigName ~= configName then
      self:_loadCombatSnapshot(configName)
    end
    for _, entry in ipairs(COMBAT_SPELL_PRIORITY) do
      if TryAction(entry) then return end
    end
  else
    -- Fallback (no config name): use SPELL_PRIORITY directly.
    -- Restore the active combat config if the UI is previewing a different one.
    if AutoLockDB and AutoLockDB.activeConfig and
       AutoLock._loadedConfigName ~= AutoLockDB.activeConfig and
       AutoLock._reloadActiveCombatConfig then
      AutoLock:_reloadActiveCombatConfig()
    end
    for _, entry in ipairs(SPELL_PRIORITY) do
      if TryAction(entry) then return end
    end
  end
end

-- Debug: print remaining time of DH-affected dots on the current target.
-- Usage in-game: /run AutoLock:PrintDotTimers()
function AutoLock:PrintDotTimers()
  if not Cursive then
    AutoLockLog.Warning("PrintDotTimers: Cursive not loaded")
    return
  end

  local _, guid = UnitExists("target")
  if not guid then
    AutoLockLog.Warning("PrintDotTimers: no target")
    return
  end

  local dhDuration = AutoLock:GetSpellDurationByName("Dark Harvest")
  local required   = dhDuration and (dhDuration * 1.3) or nil

  local dots = {
    { key = "curse of agony",  label = "Curse of Agony" },
    { key = "corruption",      label = "Corruption"     },
    { key = "siphon life",     label = "Siphon Life"    },
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
    -- Also print raw ms so we can verify nampower's value matches the real cast time
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




