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
--
-- GetSpellCooldown returns (start, duration, enable).
-- During the GCD, start != 0 but duration <= 1.5 s (the GCD window).
-- A real spell cooldown always has duration > 1.5 s.
-- Without this distinction, IsOnCooldown returns true during GCD even for
-- spells with no spell-specific cooldown, blocking Death Coil and Dark Harvest
-- while Drain Soul (which has no cooldown check) fires instead.
function AutoLock:IsOnCooldown(spellName)
  local slot, rankStr = GetHighestRankSpell(spellName)
  if not slot then return nil, nil end
  local start, duration = GetSpellCooldown(slot, BOOKTYPE_SPELL)
  if not start or start == 0 then return false, rankStr end
  if duration and duration <= 1.5 then return false, rankStr end  -- GCD only, not a real cooldown
  return true, rankStr
end

-- Liest die Channel/Cast-Dauer eines Spells per Tooltip
function AutoLock:GetSpellDurationByName(spellName)
    -- Problem 5: Nampower exposes GetSpellDuration(spellId) in milliseconds,
    -- bypassing the tooltip-scan which is locale-dependent ("over X sec" / "X Sek").
    if GetSpellSlotTypeIdForName and GetSpellDuration then
        local _, _, spellId = GetSpellSlotTypeIdForName(spellName)
        if spellId and spellId ~= 0 then
            local ms = GetSpellDuration(spellId)
            if ms and ms > 0 then return ms / 1000 end
        end
    end

    -- Fallback: tooltip scan (locale-dependent, enUS + deDE covered).
    local tt = AutoLock_DurationTooltip or CreateFrame(
        "GameTooltip", "AutoLock_DurationTooltip", nil, "GameTooltipTemplate"
    )
    AutoLock_DurationTooltip = tt

    local slot = FindLastRankSlot(spellName)
    if not slot then return nil end

    tt:SetOwner(UIParent, "ANCHOR_NONE")
    tt:ClearLines()
    tt:SetSpell(slot, BOOKTYPE_SPELL)

    for i = 2, tt:NumLines() do
        local line = _G["AutoLock_DurationTooltipTextLeft"..i]
        if line then
            local text = line:GetText()
            if text then
                local _, _, secs = strfind(string.lower(text), "over%s+(%d+%.?%d*)%s+sec")
                if secs then return tonumber(secs) end

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
  local key = "LAST:"..spellName
  if AutoLock_ManaCostCache[key] ~= nil then
    return AutoLock_ManaCostCache[key]
  end

  -- Problem 4: Nampower provides direct DBC access via GetSpellRec(spellId).manaCost,
  -- bypassing the tooltip-scan which is locale-dependent and creates tooltip frames.
  if GetSpellSlotTypeIdForName and GetSpellRec then
    local _, _, spellId = GetSpellSlotTypeIdForName(spellName)
    if spellId and spellId ~= 0 then
      local rec = GetSpellRec(spellId)
      if rec and rec.manaCost then
        AutoLock_ManaCostCache[key] = rec.manaCost
        return rec.manaCost
      end
    end
  end

  -- Fallback: tooltip scan (locale-dependent, enUS covered).
  local slot = FindLastRankSlot(spellName)
  if not slot then
    AutoLockLog.Warning("Spell not found: " .. spellName)
    return nil
  end

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

function AutoLock:IsTrinketReady(slot)
    -- Problem 7: Nampower provides GetTrinketCooldown(slot) which returns the
    -- remaining cooldown in seconds, or -1 if no trinket is equipped in that slot.
    if GetTrinketCooldown then
        local cd = GetTrinketCooldown(slot)
        if cd == -1 then return false end  -- no trinket equipped
        return cd == 0
    end
    -- Fallback: vanilla inventory cooldown query.
    local start, duration, enable = GetInventoryItemCooldown("player", slot)
    if enable == 1 and duration == 0 then
        return true
    end
    return false
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

  -- Problem 2: Nampower provides IsSpellInRange(name, unit) — no action slot needed.
  -- Returns 1 (in range), 0 (out of range), -1 (invalid: spell unknown, no target).
  if IsSpellInRange then
    local r = IsSpellInRange(spellName, "target")
    if r == 1 then return false end
    if r == 0 then return true end
    -- r == -1: spell not known or no valid target; fall through to slot-based check.
  end

  -- Fallback: scan action slots 1-120 and use vanilla IsActionInRange.
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
