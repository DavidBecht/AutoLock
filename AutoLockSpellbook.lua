-- AutoLockSpellbook.lua — Button im SpellBook-Grid (Vanilla 1.12, ohne AceHook)

local function Chat(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00AutoLock:|r " .. tostring(msg))
  end
end

-- Macro-Setup (für Shift-Drag)
local MACRO_NAME = "AutoLock"
local ICON_INDEX = 1            -- WICHTIG: in 1.12 muss das eine ZAHL sein (Icon-Index)
local MACRO_ICON = "INV_Misc_QuestionMark"
local MACRO_BODY = "/run AutoLock:DoAutoLock()"

local function PickupAutoLockMacro()
  if not (CreateMacro and GetMacroIndexByName and EditMacro and PickupMacro and GetNumMacros) then
    Chat("Macro API not available on this client.")
    return
  end

  local id = GetMacroIndexByName(MACRO_NAME)
  if id and id > 0 then
    -- Edit mit numerischem Icon-Index (einige 1.12-Builds verlangen das)
    pcall(function() EditMacro(id, MACRO_NAME, ICON_INDEX, MACRO_BODY, 1) end)
  else
    -- Schauen, ob noch Platz ist (18 global, 18 char in 1.12)
    local globalCount, charCount = GetNumMacros()
    if (globalCount or 0) >= 18 and (charCount or 0) >= 18 then
      Chat("No free macro slots (global and character macros full).")
      return
    end
    id = CreateMacro(MACRO_NAME, ICON_INDEX, MACRO_BODY, 1)  -- 1 = per-character
    if not id then
      Chat("Could not create macro (slots full or API mismatch).")
      return
    end
  end

  PickupMacro(id)
end


-- ==== internes Helferlein ====
-- Nur Ziffern + Punkt erlauben (1.12 hat kein SetNumeric)
local function IsGeneralTabSelected()
  -- In 1.12 ist meist SpellBookFrame.selectedSkillLine gesetzt (1 = General)
  local line = (SpellBookFrame and SpellBookFrame.selectedSkillLine) or 1
  if type(line) ~= "number" then line = 1 end
  return line == 1
end

-- Prüft, ob ein SpellButton aktuell “belegt” ist (Icon sichtbar)
local function SpellButtonHasIcon(btn)
  if not btn then return false end
  local tex = _G[btn:GetName() .. "IconTexture"]
  if not tex then return false end
  -- In 1.12 ist ein freier Slot meist: IconTexture nicht sichtbar oder Alpha = 0
  return tex:IsShown() and (tex:GetAlpha() or 0) > 0
end

-- Sucht von 12 nach 1 den letzten freien Spell-Slot auf der Seite
local function FindLastFreeSpellButton()
  for i = 1, 12, 1 do
    local b = _G["SpellButton" .. i]
    if b then
      if not SpellButtonHasIcon(b) then
        return b
      end
    end
  end
  -- Fallback: kein freier Slot gefunden → benutze den letzten
  return -1
end


-- ==== State ====
AutoLock.Spellbookbutton = AutoLock.Spellbookbutton or nil
local _old_SpellBookFrame_Update
local _old_SpellBookFrame_UpdateSkillLineTabs

-- ==== Button erstellen ====
function AutoLock:SpellbookCreateButton()
  if self.Spellbookbutton or not SpellBookFrame then return end

  local anchor = FindLastFreeSpellButton()
  if anchor == -1 then return end

  local btn = CreateFrame("Button", "AutoLockSpellButton", SpellBookFrame)
  self.Spellbookbutton = btn

  btn:SetWidth(anchor:GetWidth())
  btn:SetHeight(anchor:GetHeight())
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", anchor, "CENTER", 0, 0)
  btn:SetFrameStrata("HIGH")
  btn:SetFrameLevel(SpellBookFrame:GetFrameLevel() + 10)

  -- Icon
  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetAllPoints(btn)
  icon:SetTexture("Interface\\Icons\\" .. MACRO_ICON)

  local hl = btn:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints(btn)
  hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
  hl:SetBlendMode("ADD")

  -- SpellBook-Text: Überschrift + Subtext
  btn.name = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  btn.name:SetPoint("LEFT", btn, "RIGHT", 6, 6)
  btn.name:SetText("AutoLock")

  btn.subText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  btn.subText:SetPoint("TOPLEFT", btn.name, "BOTTOMLEFT", 0, -2)
  btn.subText:SetText("Cast")
  btn.subText:SetTextColor(0.5, 0.5, 0.5)

  btn:RegisterForClicks("LeftButtonUp")
  btn:RegisterForDrag("LeftButton")

  btn:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
    GameTooltip:SetText("AutoLock", 1,1,1)
    GameTooltip:AddLine("Linksklick: DoAutoLock()", .9,.9,.9)
    GameTooltip:AddLine("Shift + Ziehen: Makro erstellen & ziehen", .9,.9,.9)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  btn:SetScript("OnClick", function()
    if AutoLock and AutoLock.DoAutoLock then
      AutoLock:DoAutoLock()
    else
      Chat("Core DoAutoLock() not available.")
    end
  end)

  btn:SetScript("OnDragStart", function()
    if IsShiftKeyDown and IsShiftKeyDown() then
      PickupAutoLockMacro()
    end
  end)

  btn:Hide()
  Chat("SpellBook button created.")
end
	

-- ==== zentrales Re-Positionieren / Anzeigen ====
function AutoLock:SpellbookUpdatePlacement()
  if not SpellBookFrame then return end
  self:SpellbookCreateButton()
  local btn = self.Spellbookbutton
  if not btn then return end

  if IsGeneralTabSelected() and SpellBookFrame:IsVisible() then
    local anchor = FindLastFreeSpellButton()
		-- kein freier slot gefunden
		if anchor == -1 then return end
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", anchor, "CENTER", 0, 0)
    btn:SetWidth(anchor:GetWidth())
    btn:SetHeight(anchor:GetHeight())
    btn:Show()
  else
    btn:Hide()
end
  end

-- ==== Show/Hide Callbacks ====
function AutoLock:SpellbookOnShow()
  self:SpellbookUpdatePlacement()
end

function AutoLock:SpellbookOnHide()
  if self.Spellbookbutton then self.Spellbookbutton:Hide() end
end

-- ==== Init / Hooks ====
function AutoLock:SpellbookInit()
  if not SpellBookFrame then return end

  -- Frame-Show/Hide hooken (nicht überschreiben, additiv ergänzen)
  if not SpellBookFrame._AutoLockHooked then
    SpellBookFrame._AutoLockHooked = true

    local prevShow = SpellBookFrame:GetScript("OnShow")
    local prevHide = SpellBookFrame:GetScript("OnHide")

    SpellBookFrame:SetScript("OnShow", function()
      if prevShow then prevShow() end
      AutoLock:SpellbookOnShow()
    end)
    SpellBookFrame:SetScript("OnHide", function()
      if prevHide then prevHide() end
      AutoLock:SpellbookOnHide()
    end)
  end

  -- „post-hook“ SpellBookFrame_Update
  if SpellBookFrame_Update and not _old_SpellBookFrame_Update then
    _old_SpellBookFrame_Update = SpellBookFrame_Update
    SpellBookFrame_Update = function(...)
      _old_SpellBookFrame_Update(unpack(arg))
      AutoLock:SpellbookUpdatePlacement()
    end
  end

  -- „post-hook“ Tab-Update
  if SpellBookFrame_UpdateSkillLineTabs and not _old_SpellBookFrame_UpdateSkillLineTabs then
    _old_SpellBookFrame_UpdateSkillLineTabs = SpellBookFrame_UpdateSkillLineTabs
    SpellBookFrame_UpdateSkillLineTabs = function(...)
      _old_SpellBookFrame_UpdateSkillLineTabs(unpack(arg))
      AutoLock:SpellbookUpdatePlacement()
    end
  end

  -- Falls SpellBook schon offen ist, direkt aktualisieren
  if SpellBookFrame:IsVisible() then
    self:SpellbookOnShow()  -- (Fix: richtiger Funktionsname)
  end
end

-- ==== Lifecycle-Wrapper (dein Stil beibehalten) ====
function AutoLock:SpellbookOnEnable()
  -- Events für /reload & Login
  self:RegisterEvent("PLAYER_LOGIN", "SpellbookInit")
  self:RegisterEvent("PLAYER_ENTERING_WORLD", "SpellbookInit")
  self:RegisterEvent("ADDON_LOADED", "SpellbookInit")

  -- Direkt versuchen
  self:SpellbookInit()
end

function AutoLock:SpellbookOnDisable()
  if self.Spellbookbutton then self.Spellbookbutton:Hide() end
  -- Hooks zurücksetzen (optional)
  if _old_SpellBookFrame_Update and SpellBookFrame_Update then
    SpellBookFrame_Update = _old_SpellBookFrame_Update
    _old_SpellBookFrame_Update = nil
  end
  if _old_SpellBookFrame_UpdateSkillLineTabs and SpellBookFrame_UpdateSkillLineTabs then
    SpellBookFrame_UpdateSkillLineTabs = _old_SpellBookFrame_UpdateSkillLineTabs
    _old_SpellBookFrame_UpdateSkillLineTabs = nil
  end
end
