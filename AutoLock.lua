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

-- Cursive-tracked curses (use Cursive.curses:HasCurse)
local DARK_HARVEST_CURSE_NAMES = {
  agony      = "curse of agony",
  corruption = "corruption",
  siphonLife = "siphon life",
}
-- Non-Cursive debuffs (use UnitDebuff + SpellInfo via SuperWoW)
local DARK_HARVEST_DEBUFF_NAMES = {
  shadowVuln = "Shadow Vulnerability",
}

-- Curse names checked for Drain Soul (same Cursive-tracked set, no Shadow Vuln)
local DRAIN_SOUL_CURSE_NAMES = {
  agony      = "curse of agony",
  corruption = "corruption",
  siphonLife = "siphon life",
}

local function drainSoulDotsReady()
  local req = nil
  local combatName = AutoLock._combatConfigName or (AutoLockDB and AutoLockDB.activeConfig)
  if combatName and AutoLockDB and AutoLockDB.configs then
    for _, c in ipairs(AutoLockDB.configs) do
      if c.name == combatName then
        req = c.drainSoulDots
        break
      end
    end
  end
  if not req then return true end
  local _, targetGuid = UnitExists("target")
  for key, curseName in pairs(DRAIN_SOUL_CURSE_NAMES) do
    if req[key] then
      if not Cursive or not Cursive.curses:HasCurse(curseName, targetGuid, 0) then
        return false
      end
    end
  end
  return true
end

local function darkHarvestDotsReady()
  local req = nil
  local combatName = AutoLock._combatConfigName or (AutoLockDB and AutoLockDB.activeConfig)
  if combatName and AutoLockDB and AutoLockDB.configs then
    for _, c in ipairs(AutoLockDB.configs) do
      if c.name == combatName then
        req = c.darkHarvestDots
        break
      end
    end
  end
  if not req then return true end

  local _, targetGuid = UnitExists("target")

  for key, curseName in pairs(DARK_HARVEST_CURSE_NAMES) do
    if req[key] then
      if not Cursive or not Cursive.curses:HasCurse(curseName, targetGuid, 0) then
        return false
      end
    end
  end

  for key, debuffName in pairs(DARK_HARVEST_DEBUFF_NAMES) do
    if req[key] then
      if not AutoLock:HasDebuffByName("target", debuffName) then
        return false
      end
    end
  end

  return true
end

local WandShooting = false
local DrainSoulChanneling = false
local DarkHarvestChanneling = false
local ShadowTrancePending = false

local DrainSoulCastedAt = 0
local DrainSoulDuration = 0

local DarkHarvestCastedAt = 0
local DarkHarvestDuration = 0

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

  elseif E == "SPELLCAST_FAILED" or E == "SPELLCAST_INTERRUPTED" then
		DarkHarvestChanneling = false
		DrainSoulChanneling = false
		WandShooting = false
		DoLock_OnCooldownUntil = 0
		ImmolateTargetGUID = nil

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
	end
end)

-- =========================
-- Priority-based spell list
-- =========================
-- Give each spell a "priority" number. Lower = higher priority.
-- You can change just the numbers instead of reordering the table.
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
	if DrainSoulChanneling then
		local remain = (DrainSoulCastedAt + DrainSoulDuration) - GetTime()
		-- print("Remain:", remain, "Channel:", DrainSoulChanneling)
		return (remain <= 0.04) 
	end
	return true
end

local function darkHarvestChannelingFinished()
	if DarkHarvestChanneling then
		local remain = (DarkHarvestCastedAt + DarkHarvestDuration) - GetTime()
		-- print("Remain:", remain, "Channel:", DrainSoulChanneling)
		return (remain <= 0.04) 
	end
	return true
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

  
	{ name = "Curse of Shadow", type = "curse", priority = 6, refreshtime = 0, target = "target", enabled = true },
  { name = "Curse of Agony",  type = "curse", priority = 7, refreshtime = 0, target = "target", enabled = true },
  { name = "Corruption",      type = "curse", priority = 8, refreshtime = 0, target = "target", enabled = true },
  { name = "Siphon Life",     
		type = "curse", 
		priority = 9, 
		refreshtime = 0, 
		target = "target", 
		enabled = true, 
		condition = function(unit)
			return drainSoulChannelingFinished()
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
			if MovementEvents and MovementEvents:IsMoving() then return false end
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
      if MovementEvents and MovementEvents:IsMoving() then return false end
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
			if MovementEvents and MovementEvents:IsMoving() then return false end
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
			if MovementEvents and MovementEvents:IsMoving() then return false end
			local onCD, rankStr = AutoLock:IsOnCooldown("Dark Harvest")
			if onCD then return false end
			if not darkHarvestDotsReady() then return false end
			return darkHarvestChannelingFinished()
		end,
	},
	
	{ name = "Drain Soul",
		type = "cast",
		priority = 23,
		target = "target",
		enabled = true,
		condition = function(unit)
			if MovementEvents and MovementEvents:IsMoving() then return false end
			if not drainSoulChannelingFinished() then return false end
			return drainSoulDotsReady()
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
			if MovementEvents and MovementEvents:IsMoving() then return false end
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
			if MovementEvents and MovementEvents:IsMoving() then return false end
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
			if MovementEvents and MovementEvents:IsMoving() then return false end -- optional
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
	
	-- Skip if DarkHarvest is Channeling
	if not darkHarvestChannelingFinished() then return false end
	
  -- Skip if condition fails
  if entry.condition and not entry.condition(t) then return false end

	if entry.type ~= "trinket" and entry.type ~= "pet" then
		-- Skip if spell is not in range
		local outOfRange = AutoLock:IsSpellOutOfRange(entry.name)
		if outOfRange == true then
			return false
		elseif outOfRange == nil then 
			AutoLockLog.Warning("No Action-Slot for spell " .. entry.name .. " found! Range check not possible")
		end
		
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
    CastSpellByName(entry.name, t)
		if entry.name == "Shadow Bolt" and AutoLock:HasAnyBuff("player", "Shadow Trance", "Spell_Shadow_Twilight") then
			ShadowTrancePending = true
		else
			ShadowTrancePending = false
    end
		ok = true
  elseif entry.type == "curse" then
    if Cursive then
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
	if ok then SpellStartedName = entry.name end
  return ok
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






