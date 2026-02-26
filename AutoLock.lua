local L = AceLibrary("AceLocale-2.2"):new("AutoLock")

AutoLock = AceLibrary("AceAddon-2.0"):new(
  "AceEvent-2.0",
  "AceConsole-2.0",
	"AceHook-2.1"
)

DEFAULT_CHAT_FRAME:AddMessage("AutoLock.lua loaded")

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
    }
  })
end

function AutoLock:OnEnable()
  DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00AutoLock loaded. Use /autolock toggle|r")
	self:InitUI()
	self:SpellbookInit()
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
		AutoLock:DeleteSoulShards()
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
			print("AutoLock: No Action-Slot for spell " .. entry.name .. " found! Range check not possible") 
		end
		
		local manaCostNextSpell =  AutoLock:GetSpellManaCostByName(entry.name)
		local playerMana = UnitMana("player")
		
		-- Check player mana and may cast next spell
		if manaCostNextSpell and drainSoulChannelingFinished() and playerMana < manaCostNextSpell then
			CastSpellByName("Life Tap", t)
			if playerMana < manaCostNextSpell then
				-- life tap not possible -> too less health
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
    ok = Cursive:Curse(entry.name, t, { refreshtime = entry.refreshtime or 1 })
	elseif entry.type == "trinket" then
		ok = entry.use()
	elseif entry.type == "pet" then
      local slot = GetPetSpellSlot(entry.name)
      if slot then CastPetAction(slot) end
  end
	if ok then SpellStartedName = entry.name end
  return ok
end

-- =========================
-- Public entry point
-- =========================
function AutoLock:DoAutoLock()
  for _, entry in ipairs(SPELL_PRIORITY) do
    if TryAction(entry) then
      return -- stop after the first action that fires
    end
  end
end






