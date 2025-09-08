-- Optional: kleine Cache-Tabelle, um wiederholte Scans zu sparen
AutoLock_ManaCostCache = AutoLock_ManaCostCache or {}

local function percent(cur, max)
  if not max or max <= 0 then return 0 end
  return floor((cur / max) * 100 + 0.5)
end

-- Hilfsfunktion: Slot für Zaubername suchen
local function FindSpellSlot(spellName)
  for i = 1, 300 do
    local name = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    if name == spellName then
      return i
    end
  end
  return nil
end

local function FindLastRankSlot(spellName)
  local lastSlot = nil
  for slot = 1, 1024 do
    local name = GetSpellName(slot, BOOKTYPE_SPELL)
    if not name then break end
    if name == spellName then
      lastSlot = slot  -- immer weiter überschreiben → am Ende ist das der höchste Rank
    end
  end
  return lastSlot
end

local function ExtractManaCost(text)
  if not text then return nil end
  local s, e, num = strfind(text, "(%d+)%s+[Mm][Aa][Nn][Aa]")
  if num then
    return tonumber(num)
  end
  return nil
end

-- Hilfsfunktion: Mana-Kosten lesen
function AutoLock:GetSpellManaCostByName(spellName)

	 -- Cache-Key
  local key = "LAST:"..spellName
  if AutoLock_ManaCostCache[key] ~= nil then
		-- print("from cache")
		return AutoLock_ManaCostCache[key]
  end

  local slot = FindLastRankSlot(spellName)
  if not slot then
    DEFAULT_CHAT_FRAME:AddMessage("Spell not found: "..spellName)
    return nil
  end

  -- Tooltip vorbereiten
  local tt = AutoLock_ScanTooltip or CreateFrame("GameTooltip","AutoLock_ScanTooltip",nil,"GameTooltipTemplate")
  tt:SetOwner(UIParent,"ANCHOR_NONE")
  tt:ClearLines()
  tt:SetSpell(slot, BOOKTYPE_SPELL)

  for i = 2, tt:NumLines() do
    local text = getglobal("AutoLock_ScanTooltipTextLeft"..i):GetText()

		local n = ExtractManaCost(text)
		if n then
			local cost = tonumber(n)
			AutoLock_ManaCostCache[key] = cost
			return cost
		end

  end

  return nil
end


function test()

	-- Beispiel: Ziel-Lebenspunkte in %
	local thp  = UnitHealth("target")
	local thpm = UnitHealthMax("target")
	local tPct = percent(thp, thpm)

	print("Health Target: " .. tostring(thp))
	print("Health Target %:" .. tostring(tPct))
	
	
	local thp  = UnitHealth("player")
	local thpm = UnitHealthMax("player")
	local tPct = percent(thp, thpm)
	local pow     = UnitMana("player")
	local powMax  = UnitManaMax("player")
	local powPct = percent(thp, thpm)

	print("Health Player: " .. tostring(thp))
	print("Health Player %:" .. tostring(tPct))
	print("Mana Player: " .. tostring(pow))
	print("Mana Player %:" .. tostring(powPct))
	
	
	local id, rank = SpellNameToId("Immolate")
	local spellInfo = GetSpellManaCostByName("Immolate")
	print(spellInfo)
	
end