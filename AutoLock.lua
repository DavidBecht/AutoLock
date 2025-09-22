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

function PrintBuffs()
  for i=0,40 do
    local buffId = GetPlayerBuffID(i)
    if not buffId then break end
    print(SpellInfo(buffId))
  end
end

function HasBuff(unit, buff)
  local id, rank = SpellNameToId(buff)
  for i=1,100 do
    local texture, c, found_id = UnitBuff(unit,i)
    if not texture then break end
    if found_id==id then return true end
  end
  return false
end

function HasBuffNew(buff, texturefile)
  for i=0,40 do
    local buffId = GetPlayerBuffID(i)
      if not buffId then break end
      local name, rank, tf, minrange, maxrange = SpellInfo(buffId)
      if name == buff and texturefile ~= nil and texturefile == tf then return true end
      if name == buff and (texturefile == nil or texturefile == "") then return true end
  end
  return false
end

	if SpellStartedName == DRAIN_SOUL_NAME and (DrainSoulNumber == nil or DrainSoulNumber == "") then DrainSoulNumber = A1 end
	if SpellStartedName == DARK_HARVEST_NAME and (DarkHarvestNumber == nil or DarkHarvestNumber == "") then DarkHarvestNumber = A1 end

local ShadowTranceCastedAt = 0
local SHADOWTRANCE_POST_PAUSE = 0.20
local ImmolateCastedAt = 0 
local lastSpell = nil
local DoLock_OnCooldownUntil = 0  -- Zeitpunkt bis zu dem DoLock pausiert
local IMMOLATE_POST_PAUSE = 0.20  -- Sekunden
local SHOOT_NAME   = "Shoot"   -- ggf. lokalisierter Name: deDE="Schießen"
local IMMOLATE_NAME = "Immolate"
local DRAIN_SOUL_NAME = "Drain Soul"
local DARK_HARVEST_NAME = "Dark Harvest"
local SpellStartedName = nil

local WandShooting = false
local DrainSoulChanneling = false
local DrainSoulNumber = nil
local DarkHarvestChanneling = false
local DarkHarvestNumber = nil

local DrainSoulCastedAt = 0
local DarkHarvestCastedAt = 0

local f = CreateFrame("Frame")
-- klassische Cast-Events
f:RegisterEvent("SPELLCAST_START")
f:RegisterEvent("SPELLCAST_STOP")
f:RegisterEvent("SPELLCAST_FAILED")
f:RegisterEvent("SPELLCAST_INTERRUPTED")
-- Channel (manche Clients zeigen Shoot als Channel)
f:RegisterEvent("SPELLCAST_CHANNEL_START")
f:RegisterEvent("SPELLCAST_CHANNEL_STOP")
-- Auto-Repeat (Wand/Auto Shot)
f:RegisterEvent("START_AUTOREPEAT_SPELL")
f:RegisterEvent("STOP_AUTOREPEAT_SPELL")
f:RegisterEvent("BAG_UPDATE")

f:SetScript("OnEvent", function()
  local E, A1 = event, arg1

  if A1 == DrainSoulNumber then A1 = DRAIN_SOUL_NAME end   -- Drain Soul
  if A1 == DarkHarvestNumber then A1 = DARK_HARVEST_NAME end -- Dark Harvest

  if E == "SPELLCAST_START" then
    lastSpell = A1
    if A1 == DARK_HARVEST_NAME then
      DarkHarvestChanneling = true
    elseif A1 == DRAIN_SOUL_NAME then
      DrainSoulChanneling = true -- falls dein Server Drain Soul als START feuert
    end

  elseif E == "SPELLCAST_STOP" then
    if lastSpell == IMMOLATE_NAME then
      ImmolateCastedAt = GetTime()
      DoLock_OnCooldownUntil = ImmolateCastedAt + IMMOLATE_POST_PAUSE
    end
    if lastSpell == DARK_HARVEST_NAME then
      DarkHarvestChanneling = false
    elseif lastSpell == DRAIN_SOUL_NAME then
      DrainSoulChanneling = false
    end
    lastSpell = nil

  elseif E == "SPELLCAST_FAILED" or E == "SPELLCAST_INTERRUPTED" then
    if lastSpell == DARK_HARVEST_NAME then
      DarkHarvestChanneling = false
    elseif lastSpell == DRAIN_SOUL_NAME then
      DrainSoulChanneling = false
    end
    lastSpell = nil

  elseif E == "SPELLCAST_CHANNEL_START" then
		if SpellStartedName == DRAIN_SOUL_NAME and (DrainSoulNumber == nil or DrainSoulNumber == "") then DrainSoulNumber = A1 end
		if SpellStartedName == DARK_HARVEST_NAME and (DarkHarvestNumber == nil or DarkHarvestNumber == "") then DarkHarvestNumber = A1 end
		if A1 == DrainSoulNumber then A1 = DRAIN_SOUL_NAME end   -- Drain Soul
		if A1 == DarkHarvestNumber then A1 = DARK_HARVEST_NAME end -- Dark Harvest
		--print("SSN: " .. SpellStartedName .. " | SavedNr: " .. DrainSoulNumber .. " | Event: " .. E)
    if A1 == DRAIN_SOUL_NAME then
      DrainSoulChanneling = true
    elseif A1 == DARK_HARVEST_NAME then
      DarkHarvestChanneling = true
    elseif A1 == SHOOT_NAME then
      WandShooting = true
    end

  elseif E == "SPELLCAST_CHANNEL_STOP" then
    if DrainSoulChanneling then DrainSoulChanneling = false end
    if DarkHarvestChanneling then DarkHarvestChanneling = false end
    WandShooting = false
    lastSpell = nil

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
  return HasBuffNew("Shadow Trance", "Interface\\Icons\\Spell_Shadow_Twilight")
end


-- helper für Cursive
local function lowerNoRank(spellName)
  return string.lower(spellName or "")
end

local function targetGuid(unit)
  local _, guid = UnitExists(unit or "target")
  return guid
end

SPELL_PRIORITY = {
  {
    name = "Shadow Bolt",
    type = "cast",
    priority = 1,
    target = "target",
    condition = function(unit)
			if (GetTime() - ShadowTranceCastedAt) < SHADOWTRANCE_POST_PAUSE then return false end
      return IsShadowTranceProc()
    end,
    uitext  = "Shadow Trance (Shadow Bolt)",
    enabled = true,
  },

  -- Kern-DoTs / Standard-Rota
  { name = "Immolate",        
		type = "curse", 
		priority = 2, 
		refreshtime = 2, 
		target = "target",
    condition = function(unit)
      if GetTime() < DoLock_OnCooldownUntil then return false end
      if MovementEvents and MovementEvents:IsMoving() then return false end
      if not (Cursive and Cursive.curses) then return true end
      local guid = targetGuid(unit or "target"); if not guid then return true end
      return not Cursive.curses:HasCurse(lowerNoRank("Immolate"), guid, 2)
    end,
    enabled = false,
  },
	{ name = "Curse of Shadow", type = "curse", priority = 3, refreshtime = 5, target = "target", enabled = true },
  { name = "Curse of Agony",  type = "curse", priority = 4, refreshtime = 1, target = "target", enabled = true },
  { name = "Corruption",      type = "curse", priority = 5, refreshtime = 1, target = "target", enabled = true },
  { name = "Siphon Life",     type = "curse", priority = 6, refreshtime = 1, target = "target", enabled = true },

  -- Situative Warlock Curses (bei Bedarf aktivieren/umsortieren)
  { name = "Curse of Recklessness", type = "curse", priority = 10, refreshtime = 2, target = "target", enabled = false },
  { name = "Curse of Weakness",     type = "curse", priority = 11, refreshtime = 2, target = "target", enabled = false },
  { name = "Curse of Tongues",      type = "curse", priority = 12, refreshtime = 5, target = "target", enabled = false },
  { name = "Curse of the Elements", type = "curse", priority = 13, refreshtime = 5, target = "target", enabled = false },
  { name = "Curse of Doom",         type = "curse", priority = 15, refreshtime = 30, target = "target", enabled = false },

	{ name = "Dark Harvest",         
		type = "cast", 
		priority = 20,  
		target = "target", 
		enabled = false, 
		condition = function(unit)
			if MovementEvents and MovementEvents:IsMoving() then return false end
			if DarkHarvestChanneling then return false end
			return true
		end,
	},
	
	{ name = "Drain Soul",         
		type = "cast", 
		priority = 21,  
		target = "target", 
		enabled = true, 
		condition = function(unit)
			if MovementEvents and MovementEvents:IsMoving() then return false end
			if MovementEvents and MovementEvents:IsMoving() then return false end
			if DrainSoulChanneling then return false end
			return true
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
	if entry.enabled == nil or entry.enabled == false then
		return false
	end
	--print(entry.name)
	--print(entry.enabled)
	--print(entry.condition)
	
  -- Skip if condition fails
  if entry.condition and not entry.condition(t) then
		-- print("condition false")
    return false
  end
	
	-- Check player mana and may cast next spell
	if UnitMana("player") < AutoLock:GetSpellManaCostByName(entry.name) then
		--print("Spell skipped too less mana")
		return false
	end
	
	-- print(DrainSoulChanneling)
	
	if DrainSoulChanneling and IsShadowTranceProc() and entry.name ~= "Shadow Bolt" then return true end 

	local ok = false
  if entry.type == "cast" then
    CastSpellByName(entry.name, t)
		if entry.name == "Shadow Bolt" and IsShadowTranceProc() then ShadowTranceCastedAt = GetTime() end
		ok = true
  elseif entry.type == "curse" then
    ok = Cursive:Curse(entry.name, t, { refreshtime = entry.refreshtime or 1 })
  end
	if ok then SpellStartedName = entry.name end
	--print(ok)
	--print(SpellStartedName)
  return ok
end

-- =========================
-- Public entry point
-- =========================
function AutoLock:DoAutoLock()
	-- print("DoAutoLock")
	-- solange einer der beiden läuft: NICHTS anderes machen
  if DarkHarvestChanneling then
    return
  end
  for _, entry in ipairs(SPELL_PRIORITY) do
    if TryAction(entry) then
      return -- stop after the first action that fires
    end
  end
end





