-- AutoLockSoulShards.lua
-- Soul bag detection and shard management.
-- Depends on: AutoLockTooltip (defined in AutoLockHelper.lua)

local SOUL_BAG_SUBTYPES = {
  ["Soul Bag"]          = true,  -- enUS
  ["Seelenbeutel"]      = true,  -- deDE
  ["Borsa dell'anima"]  = true,  -- itIT
  ["Bourse d'âme"]      = true,  -- frFR
}

local SOUL_BAG_NAMES = {
  ["Small Soul Pouch"]  = true,
  ["Soul Pouch"]        = true,
  ["Felcloth Bag"]      = true,
  ["Core Felcloth Bag"] = true,
  ["Box of Souls"]      = true,
}

local function GetItemIdFromLink(link)
  if not link then return nil end
  local _, _, idStr = strfind(link, "item:(%d+)")
  if idStr then return tonumber(idStr) end
  return nil
end

-- Returns true if the bag slot (1–4) contains a soul bag.
local function IsSoulBag(bag)
  if bag == 0 then return false end
  local invId = ContainerIDToInventoryID(bag)
  if not invId then return false end

  local link = GetInventoryItemLink("player", invId)
  if not link then return false end

  local name, _, _, _, _, _, itemSubType = GetItemInfo(link)
  if itemSubType and SOUL_BAG_SUBTYPES[itemSubType] then return true end
  if name and SOUL_BAG_NAMES[name] then return true end

  -- Tooltip scan fallback (locale-robust)
  AutoLockTooltip:SetOwner(UIParent, "ANCHOR_NONE")
  AutoLockTooltip:ClearLines()
  AutoLockTooltip:SetInventoryItem("player", invId)
  for i = 2, AutoLockTooltip:NumLines() do
    local line = _G["AutoLockTooltipTextLeft"..i]
    local txt = line and line:GetText()
    if txt then
      for subType in pairs(SOUL_BAG_SUBTYPES) do
        if strfind(txt, subType) then return true end
      end
      local txtLower = strlower(txt)
      if (strfind(txtLower, "soul") or strfind(txtLower, "seelen")) then
        if strfind(txtLower, "bag") or strfind(txtLower, "beutel") then
          return true
        end
      end
    end
  end
  return false
end

-- Returns list of bag indices (1–4) that are soul bags.
local function GetSoulBags()
  local res = {}
  for bag = 1, 4 do
    if IsSoulBag(bag) then table.insert(res, bag) end
  end
  return res
end

local SOUL_SHARD_ITEM_ID = 6265

function AutoLock:ScanSoulShards()
  local total = 0
  local locsAll, locsOutside = {}, {}
  local soulBagMap = {}
  for _, b in ipairs(GetSoulBags()) do soulBagMap[b] = true end

  for bag = 0, 4 do
    local slots = GetContainerNumSlots(bag) or 0
    for slot = 1, slots do
      local link = GetContainerItemLink(bag, slot)
      if link and GetItemIdFromLink(link) == SOUL_SHARD_ITEM_ID then
        total = total + 1
        table.insert(locsAll, { bag = bag, slot = slot })
        if not soulBagMap[bag] then
          table.insert(locsOutside, { bag = bag, slot = slot })
        end
      end
    end
  end
  return total, locsAll, locsOutside
end

function AutoLock:AnySoulBagFull()
  for _, bag in ipairs(GetSoulBags()) do
    local size = GetContainerNumSlots(bag)
    local full = true
    for slot = 1, size do
      if not GetContainerItemLink(bag, slot) then
        full = false
        break
      end
    end
    if full then return true, bag end
  end
  return false, nil
end

function AutoLock:DeleteSoulShards()
  local full, soulbag = AutoLock:AnySoulBagFull()
  if not (full and soulbag) then return end

  for bag = 0, 4 do
    if bag ~= soulbag then
      local slots = GetContainerNumSlots(bag) or 0
      for slot = slots, 1, -1 do
        local link = GetContainerItemLink(bag, slot)
        if link then
          local _, _, idStr = strfind(link, "item:(%d+)")
          local itemId = idStr and tonumber(idStr)
          if itemId == SOUL_SHARD_ITEM_ID then
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
