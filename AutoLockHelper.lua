-- Safety fallback: if AutoLockLog.lua was not picked up yet (e.g. first
-- launch after a TOC change without a full game restart), define no-op stubs
-- so the rest of the file doesn't crash.  AutoLockLog.lua will overwrite
-- these with the real coloured versions once the game is fully restarted.
if not AutoLockLog then
  AutoLockLog = {}
  function AutoLockLog.Info(msg)    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff9482C9[AutoLock]|r|cff00aaff[Info]|r: " .. tostring(msg)) end end
  function AutoLockLog.Warning(msg) if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff9482C9[AutoLock]|r|cffffff00[Warning]|r: " .. tostring(msg)) end end
  function AutoLockLog.Error(msg)   if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff9482C9[AutoLock]|r|cffff3333[Error]|r: " .. tostring(msg)) end end
end

-- Optional: kleine Cache-Tabelle, um wiederholte Scans zu sparen
AutoLock_ManaCostCache = AutoLock_ManaCostCache or {}

-- ensure tooltip exists for IsSoulBag() usage
AutoLockTooltip = AutoLockTooltip or CreateFrame("GameTooltip", "AutoLockTooltip", UIParent, "GameTooltipTemplate")

-- Hilfsfunktion: Slot für Zaubername suchen
function AutoLock:FindSpellSlot(spellName)
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

local function GetHighestRankSpell(spellName)
  local slot = FindLastRankSlot(spellName)
  if not slot then return nil, nil end
  local name, rankStr = GetSpellName(slot, BOOKTYPE_SPELL)
  if name ~= spellName then return nil, nil end
  return slot, rankStr
end

-- Returns: onCooldown:boolean|nil, rankStr:string|nil
-- false -> ready; true -> on cooldown; nil -> spell not found
function AutoLock:IsOnCooldown(spellName)
  local slot, rankStr = GetHighestRankSpell(spellName)
  if not slot then return nil, nil end
  local cd = GetSpellCooldown(slot, BOOKTYPE_SPELL) -- Vanilla: 0 = ready
  return (cd ~= 0), rankStr
end

-- Liest die Channel/Cast-Dauer eines Spells per Tooltip
function AutoLock:GetSpellDurationByName(spellName)
    -- Tooltip-Frame vorbereiten
    local tt = AutoLock_DurationTooltip or CreateFrame(
        "GameTooltip", "AutoLock_DurationTooltip", nil, "GameTooltipTemplate"
    )
    AutoLock_DurationTooltip = tt

    -- Höchsten Rank nutzen
    local slot = FindLastRankSlot(spellName)
    if not slot then return nil end

    tt:SetOwner(UIParent, "ANCHOR_NONE")
    tt:ClearLines()
    tt:SetSpell(slot, BOOKTYPE_SPELL)

    -- Tooltip durchsuchen
    for i = 2, tt:NumLines() do
        local line = _G["AutoLock_DurationTooltipTextLeft"..i]
        if line then
            local text = line:GetText()
            if text then
                -- Sucht "... over 15 sec" → liefert "15"
                local _, _, secs = strfind(string.lower(text), "over%s+(%d+%.?%d*)%s+sec")
                if secs then return tonumber(secs) end

                -- Fallback für andere Sprachen:
                -- "über 15 Sekunden" etc.
                local _, _, secs2 = strfind(string.lower(text), "(%d+)%s+sek")
                if secs2 then return tonumber(secs2) end
            end
        end
    end

    return nil
end


function AutoLock:PrintBuffs()
  for i=0,40 do
    local buffId = GetPlayerBuffID(i)
    if not buffId then break end
    AutoLockLog.Info(SpellInfo(buffId))
  end
end

function AutoLock:HasAnyBuff(unit, buffName, texturefile)
    unit = unit or "player"

    local id = nil
    if SpellNameToId then
        id = SpellNameToId(buffName)
    end

    -- Variante 1: UnitBuff
    for i = 1, 100 do
        local tex, stacks, found_id = UnitBuff(unit, i)
        if not tex then break end

        -- Sicherster Check: Spell-ID
        if id and found_id == id then
            return true, stacks
        end

        -- Name im Texturepfad
        if buffName and tex and strfind(tex, buffName) then
            return true, stacks
        end

        -- Teilstring-Texture-Match
        if texturefile and tex and strfind(tex, texturefile) then
            return true, stacks
        end
    end


    -- Variante 2: GetPlayerBuffID + SpellInfo
    for i = 0, 40 do
        local buffId = GetPlayerBuffID(i)
        if not buffId then break end

        local name, rank, tf = SpellInfo(buffId)

        if name == buffName then
            if texturefile and texturefile ~= "" then
                if tf and strfind(tf, texturefile) then
                    return true, 1
                end
            else
                return true, 1
            end
        end
    end

    return false
end

-- Checks debuff by spell name via SuperWoW (requires GUID, same pattern as Cursive)
function AutoLock:HasDebuffByName(unit, spellName)
  if not SpellInfo then return false end
  local _, guid = UnitExists(unit)
  if not guid then return false end
  for i = 1, 40 do
    local _, _, _, spellID = UnitDebuff(guid, i)
    if spellID then
      local name = SpellInfo(spellID)
      if name == spellName then return true end
    else
      break
    end
  end
  return false
end

-- Debug: /run AutoLock:PrintTargetDebuffs()
function AutoLock:PrintTargetDebuffs()
  if not SpellInfo then AutoLockLog.Warning("SuperWoW required"); return end
  local _, guid = UnitExists("target")
  if not guid then AutoLockLog.Warning("No target"); return end
  AutoLockLog.Info("Target debuffs:")
  for i = 1, 40 do
    local _, _, _, spellID = UnitDebuff(guid, i)
    if spellID then
      AutoLockLog.Info("  [" .. i .. "] " .. (SpellInfo(spellID) or "?") .. " (id=" .. spellID .. ")")
    else
      break
    end
  end
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
    AutoLockLog.Warning("Spell not found: " .. spellName)
    return nil
  end

  -- Tooltip vorbereiten
  local tt = AutoLock_ScanTooltip or CreateFrame("GameTooltip","AutoLock_ScanTooltip",nil,"GameTooltipTemplate")
  tt:SetOwner(UIParent,"ANCHOR_NONE")
  tt:ClearLines()
  tt:SetSpell(slot, BOOKTYPE_SPELL)

  for i = 2, tt:NumLines() do
    local text = _G["AutoLock_ScanTooltipTextLeft"..i]:GetText()

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
  ["Soul Bag"]     = true, -- enUS
  ["Seelenbeutel"] = true, -- deDE
  ["Borsa dell'anima"] = true, -- itIT (falls vorhanden)
  ["Bourse d’âme"] = true, -- frFR
}

-- Fallback: bekannte Namen klassischer Soul-Bags (Classic/Vanilla)
local SOUL_BAG_NAMES = {
  ["Small Soul Pouch"]   = true,
  ["Soul Pouch"]         = true,
  ["Felcloth Bag"]       = true,
  ["Core Felcloth Bag"]  = true,
  ["Box of Souls"]       = true,
}

local function GetItemIdFromLink(link)
  if not link then return nil end
  local s, e, idStr = strfind(link, "item:(%d+)")
  if idStr then return tonumber(idStr) end
  return nil
end

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
        if strfind(txt, subType) then
          return true
        end
      end
      -- generischer Fallback: „Soul”/„Seelen” im Tooltip
      local txtLower = strlower(txt)
      if strfind(txtLower, "soul") or strfind(txtLower, "seelen") then
        if strfind(txtLower, "bag") or strfind(txtLower, "beutel") then
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

local SOUL_SHARD_ITEM_ID = 6265

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
            -- Vanilla-safe statt string.match
            local s, e, idStr = strfind(link, "item:(%d+)")
            local itemId = idStr and tonumber(idStr) or nil
            if itemId and itemId == SHARD_ID then
              PickupContainerItem(bag, slot)
              DeleteCursorItem()
              AutoLockLog.Info("Soul Shard deleted outside Soul Bag.")
              return
            end
          end
        end
      end
    end
  end
end

function AutoLock:IsTrinketReady(slot)
    local start, duration, enable = GetInventoryItemCooldown("player", slot)
    if enable == 1 and duration == 0 then
        return true
    end
    return false
end

-- Event frame
AutoLock.EventFrame = CreateFrame("Frame")
AutoLock.EventFrame:RegisterEvent("PLAYER_LOGIN")

AutoLock.EventFrame:SetScript("OnEvent", function()
    AutoLock:OnLogin()
end)

function AutoLock:OnLogin()
    -- Create tooltip AFTER UI is ready
    self.Scanner = CreateFrame(
        "GameTooltip",
        "AutoLockScanner",
        UIParent,
        "GameTooltipTemplate"
    )
    self.Scanner:SetOwner(UIParent, "ANCHOR_NONE")

    -- Spellbook is ready at PLAYER_LOGIN; refresh known spell set
    if self.BuildKnownSpellSet then self:BuildKnownSpellSet() end

    AutoLockLog.Info("Loaded.")
end

function AutoLock:HasTarget()
  return UnitExists("target")
end

-- Find action slot by spell name (tries action text first, then tooltip)
function AutoLock:FindActionSlotBySpellName(spellName)
  if not spellName then return nil end

  local tt = self.Scanner
  local ttName = tt:GetName()
  local left1 = _G[ttName .. "TextLeft1"]  -- safer than hardcoding AutoLockScannerTextLeft1

  for slot = 1, 120 do
    -- Fast path: buttons with visible text (often macros)
    local atext = GetActionText(slot)
    if atext == spellName then
      return slot
    end

    -- Tooltip scan
    tt:ClearLines()
    tt:SetAction(slot)

    local text = left1 and left1:GetText()
    if text == spellName then
      return slot
    end
  end

  return nil
end

-- Returns: true(out of range), false(in range), nil(no data)
function AutoLock:IsSpellOutOfRange(spellName)
  if not self:HasTarget() then return false end

  local slot = self:FindActionSlotBySpellName(spellName)
  if not slot then return nil end

  local r = IsActionInRange(slot)
  if r == 0 then return true end
  if r == 1 then return false end
  return nil
end

-- Quick test
function AutoLock:TestRange(spellName)
  local slot = self:FindActionSlotBySpellName(spellName)
  AutoLockLog.Info("Spell=" .. tostring(spellName) .. " slot=" .. tostring(slot))

  local oor = self:IsSpellOutOfRange(spellName)
  AutoLockLog.Info("OutOfRange=" .. tostring(oor))
end
