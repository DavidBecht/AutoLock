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


-- Lokalisierte Schlüsselwörter (kannst du erweitern)
local SOUL_BAG_SUBTYPES = {
  ["Soul Bag"]   = true, -- enUS
  ["Seelenbeutel"] = true, -- deDE
  ["Borsa dell'anima"] = true, -- itIT (falls vorhanden)
  ["Bourse d’âme"] = true, -- frFR
  -- weitere, falls nötig
}

-- Fallback: bekannte Namen klassischer Soul-Bags (Classic/Vanilla)
local SOUL_BAG_NAMES = {
  ["Small Soul Pouch"]   = true,
  ["Soul Pouch"]         = true,
  ["Felcloth Bag"]       = true, -- ist in Classic tatsächlich Soul-Bag
  ["Core Felcloth Bag"]  = true,
  ["Box of Souls"]       = true,
  -- ggf. Server-Customs ergänzen
}

-- Prüft, ob die Tasche im Bag-Index (1..4) eine Soul-Bag ist
local function IsSoulBag(bag)
  if bag == 0 then return false end -- Backpack ist nie Soul-Bag
  local invId = ContainerIDToInventoryID(bag)
  if not invId then return false end

  local link = GetInventoryItemLink("player", invId)
  if not link then return false end

  -- 1) Versuch über Item-Infos
  local name, _, _, _, _, itemType, itemSubType = GetItemInfo(link)
  if itemSubType and SOUL_BAG_SUBTYPES[itemSubType] then
    return true
  end
  if name and SOUL_BAG_NAMES[name] then
    return true
  end

  -- 2) Tooltip-Scan (lokalisierungsrobust)
  AutoLockTooltip:SetOwner(UIParent, "ANCHOR_NONE")
  AutoLockTooltip:ClearLines()
  AutoLockTooltip:SetInventoryItem("player", invId)

  for i = 2, AutoLockTooltip:NumLines() do
    local line = _G["AutoLockTooltipTextLeft"..i]
    local txt = line and line:GetText()
    if txt then
      -- prüfe auf Subtype-Wörter
      for subType in pairs(SOUL_BAG_SUBTYPES) do
        if string.find(txt, subType, 1, true) then
          return true
        end
      end
      -- generischer Fallback: „Soul“/„Seelen“ im Tooltip
      if string.find(string.lower(txt), "soul", 1, true) or string.find(string.lower(txt), "seelen", 1, true) then
        if string.find(string.lower(txt), "bag", 1, true) or string.find(string.lower(txt), "beutel", 1, true) then
          return true
        end
      end
    end
  end

  return false
end

-- Liefert alle Soul-Bags (1..4) als Liste
local function GetSoulBags()
  local res = {}
  for bag = 1, 4 do
    if IsSoulBag(bag) then
      table.insert(res, bag)
    end
  end
  return res
end

-- Zählt Soul Shards und sammelt deren Positionen (inside/outside Soul-Bags)
function AutoLock:ScanSoulShards()
  local total = 0
  local locsAll, locsOutsideSoulBags = {}, {}
  local soulBags = {}
  for _, b in ipairs(GetSoulBags()) do soulBags[b] = true end

  for bag = 0, 4 do
    local slots = GetContainerNumSlots(bag) or 0
    for slot = 1, slots do
      local link = GetContainerItemLink(bag, slot)
      if link and GetItemIdFromLink(link) == SOUL_SHARD_ITEM_ID then
        total = total + 1
        table.insert(locsAll, {bag=bag, slot=slot})
        if not soulBags[bag] then
          table.insert(locsOutsideSoulBags, {bag=bag, slot=slot})
        end
      end
    end
  end
  return total, locsAll, locsOutsideSoulBags
end

-- Beispiel: ist irgendeine Soul-Bag voll?
function AutoLock:AnySoulBagFull()
  local bags = GetSoulBags()
  for _, bag in ipairs(bags) do
    local size = GetContainerNumSlots(bag)
    for slot = 1, size do
      if not GetContainerItemLink(bag, slot) then
        -- freier Slot vorhanden → nicht voll
        size = nil
        break
      end
    end
    if size then
      -- wir haben die Schleife nicht frühzeitig verlassen → voll
      return true, bag
    end
  end
  return false, nil
end

function AutoLock:DeleteSoulShards()
	local full, soulbag = AutoLock:AnySoulBagFull()
	if full and soulbag then

		local SHARD_ID = 6265
		-- alle Bags außer den Soul Bags durchsuchen
		for bag = 0, 4 do
			if bag ~= soulbag then
				local slots = GetContainerNumSlots(bag) or 0
				for slot = slots, 1, -1 do  -- rückwärts = neuester Slot zuerst
					local link = GetContainerItemLink(bag, slot)
					if link then
						local itemId = string.match(link, "item:(%d+)")
						if itemId and tonumber(itemId) == SHARD_ID then
							PickupContainerItem(bag, slot)
							DeleteCursorItem()
							DEFAULT_CHAT_FRAME:AddMessage("|cffff5555[AutoLock] Soul Shard außerhalb der Soul Bag gelöscht|r")
							return
						end
					end
				end
			end
		end
	end
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