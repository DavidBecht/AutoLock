-- AutoLock: Ace2 Mini UI (Vanilla 1.12)

local Dewdrop = AceLibrary and AceLibrary("Dewdrop-2.0")


-- =========================
-- SavedVariables
-- =========================
AutoLockUI_ShowDisabled = true

-- AutoLockDB is a SavedVariable: WoW restores it after VARIABLES_LOADED.
-- Ace2 may fire OnEnable() before that (via DEFAULT_CHAT_FRAME hack), so
-- we hook VARIABLES_LOADED directly and re-run InitConfigs with real data.
local autoLockVarFrame = CreateFrame("Frame")
autoLockVarFrame:RegisterEvent("VARIABLES_LOADED")
autoLockVarFrame:SetScript("OnEvent", function()
  if AutoLock and AutoLock.InitConfigs then
    AutoLock:InitConfigs()
    if frame and frame:IsShown() then
      AutoLockRefreshConfigList()
      AutoLock:PrioScrollUpdate()
    end
  end
end)

-- =========================
-- Helpers: Sortieren/Verschieben
-- =========================
local function SanitizeNumberText(s)
  s = tostring(s or "")
  -- Dezimalkomma -> Punkt (falls jemand , tippt)
  s = string.gsub(s, ",", ".")
  -- alles außer Ziffern und Punkt raus
  s = string.gsub(s, "[^0-9%.]", "")
  -- ab dem zweiten Punkt alle weiteren Punkte entfernen
  local firstDot = string.find(s, "%.")
  if firstDot then
    local head = string.sub(s, 1, firstDot)                -- inkl. erstem Punkt
    local tail = string.gsub(string.sub(s, firstDot + 1), "%.", "")
    s = head .. tail
  end
  return s
end

local function AutoLockUI_GetFiltered()
  local filtered = {}
  for _, e in ipairs(SPELL_PRIORITY) do
    if AutoLockUI_ShowDisabled or e.enabled ~= false then
      table.insert(filtered, e)
    end
  end
  return filtered
end

local function SortByPriorityNumbers()
  table.sort(SPELL_PRIORITY, function(a, b)
    local pa = a.priority or 99
    local pb = b.priority or 99
    if pa == pb then return (a.name or "") < (b.name or "") end
    return pa < pb
  end)
end

local function RenumberPriorities()
  local n = table.getn(SPELL_PRIORITY)
  for i = 1, n do
    local e = SPELL_PRIORITY[i]
    e.priority = i
    if e.enabled == nil then e.enabled = true end
  end
end

local function MoveEntry(fromIdx, toIdx)
  local n = table.getn(SPELL_PRIORITY)
  if not fromIdx or not toIdx then return end
  if fromIdx < 1 or fromIdx > n or toIdx < 1 or toIdx > n then return end
  if fromIdx == toIdx then return end
  local e = table.remove(SPELL_PRIORITY, fromIdx)
  table.insert(SPELL_PRIORITY, toIdx, e)
  RenumberPriorities()
end

-- =========================
-- Frames/State
-- =========================
local frame, scroll
local rows = {}
local header = {}
local ROW_HEIGHT, ROW_SPACING, VISIBLE_ROWS = 20, 4, 12
local miniBtn
local configStrip
local configBtns = {}

-- kleines Bedingungen-Fenster (einmalig wiederverwendet)
local condFrame

-- Spaltenbreiten (angepasst für großes Fenster)
local NAME_W  = 260
local PRIO_W  = 80
local REF_W   = 30
local BTN_W   = 70
local GAP     = 10

-- =========================
-- Config helpers
-- =========================
-- Use uitext when available so Shadow Trance (Shadow Bolt) and
-- the filler Shadow Bolt don't share the same key.
local function GetSpellKey(e)
  return (e.uitext or e.name or "?").."|"..(e.type or "?")
end

local function GetActiveConfig()
  for _, c in ipairs(AutoLockDB.configs) do
    if c.name == AutoLockDB.activeConfig then return c end
  end
end

local function SnapshotSpells()
  local t = {}
  for _, e in ipairs(SPELL_PRIORITY) do
    t[GetSpellKey(e)] = { enabled=e.enabled, priority=e.priority, refreshtime=e.refreshtime }
  end
  return t
end

local function SaveCurrentConfigSpells()
  local cfg = GetActiveConfig()
  if not cfg then return end
  cfg.spells = {}
  for _, e in ipairs(SPELL_PRIORITY) do
    cfg.spells[GetSpellKey(e)] = {
      enabled=e.enabled, priority=e.priority, refreshtime=e.refreshtime,
      TH_player_hp=e.TH_player_hp,       TH_player_hp_cmp=e.TH_player_hp_cmp,
      TH_player_mana=e.TH_player_mana,   TH_player_mana_cmp=e.TH_player_mana_cmp,
      TH_target_hp=e.TH_target_hp,       TH_target_hp_cmp=e.TH_target_hp_cmp,
      TH_mode=e.TH_mode,
    }
  end
end

local function ApplyConfigToSpells(cfg)
  for _, e in ipairs(SPELL_PRIORITY) do
    local s = cfg.spells and cfg.spells[GetSpellKey(e)]
    if s then
      e.enabled = s.enabled
      if s.priority    ~= nil then e.priority    = s.priority    end
      if s.refreshtime ~= nil then e.refreshtime = s.refreshtime end
      e.TH_player_hp=s.TH_player_hp;     e.TH_player_hp_cmp=s.TH_player_hp_cmp
      e.TH_player_mana=s.TH_player_mana; e.TH_player_mana_cmp=s.TH_player_mana_cmp
      e.TH_target_hp=s.TH_target_hp;     e.TH_target_hp_cmp=s.TH_target_hp_cmp
      e.TH_mode=s.TH_mode
    end
  end
  SortByPriorityNumbers()
  RenumberPriorities()
end

local function LoadConfig(cfg)
  if not cfg then return end
  AutoLockDB.activeConfig = cfg.name
  ApplyConfigToSpells(cfg)
  if scroll then AutoLock:PrioScrollUpdate() end
  AutoLockRefreshConfigList()  -- forward ref to global defined below
end

function AutoLock:LoadConfigByName(name)
  for _, cfg in ipairs(AutoLockDB.configs) do
    if cfg.name == name then LoadConfig(cfg); return true end
  end
  return false
end

-- =========================
-- UI: Condition Box
-- =========================
local function CreateSmallEditBox(parent, w)
  local eb = CreateFrame("EditBox", nil, parent)
  eb:SetAutoFocus(false)
  eb:SetWidth(w or 40)
  eb:SetHeight(18)
  eb:SetFontObject(GameFontHighlightSmall)
  eb:SetJustifyH("LEFT")
  eb:SetTextInsets(4, 0, 0, 0)
  eb:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
  })
  eb:SetBackdropColor(0,0,0,0.6)
  eb:SetScript("OnTextChanged", function()
    local txt = this:GetText() or ""
    local clean = SanitizeNumberText(txt)
    if clean ~= txt then this:SetText(clean) end
  end)
  eb:SetScript("OnEnterPressed",  function() this:ClearFocus() end)
  eb:SetScript("OnEscapePressed", function() this:ClearFocus() end)
  return eb
end

-- kleine Helper für Vanilla-Dropdowns
local function CreateSimpleDropdown(parent, width)
  local dd = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
  dd:SetWidth(width or 100)
  dd:SetHeight(24)
  return dd
end

local function SetDropDownSelectedByValue(drop, val, textMap)
  UIDropDownMenu_SetSelectedValue(drop, val)
  local label = textMap and textMap[val] or tostring(val)
  UIDropDownMenu_SetText(drop, label)
end

local function ShowCondFrameForEntry(entry, anchor)
  if not entry then return end
  if not Dewdrop then
    AutoLockLog.Warning("Dewdrop-2.0 not found – Conditions menu disabled.")
    return
  end

  local function cmpLabel(v) return (v == ">=") and "≥" or "≤" end
  local function logicLabel(v) return (v == "OR") and "ANY (OR)" or "ALL (AND)" end

  -- Fenster bauen (einmalig)
  if not condFrame then
    condFrame = CreateFrame("Frame", "AutoLockConditionFrame", UIParent)
    condFrame:SetWidth(280)
    condFrame:SetHeight(190)
    condFrame:SetFrameStrata("DIALOG")
    condFrame:SetFrameLevel(20)
    condFrame:SetBackdrop({
      bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })
    condFrame:SetBackdropColor(0,0,0,1)
    condFrame:EnableMouse(true)
    condFrame:SetMovable(true)
    condFrame:RegisterForDrag("LeftButton")
    condFrame:SetScript("OnDragStart", function() this:StartMoving() end)
    condFrame:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)

    local title = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", condFrame, "TOP", 0, -8)
    title:SetText("Conditions")

    local close = CreateFrame("Button", nil, condFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", condFrame, "TOPRIGHT", -4, -4)

    -- Labels
    condFrame.l_ph  = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.l_ph:SetPoint("TOPLEFT", condFrame, "TOPLEFT", 12, -36)
    condFrame.l_ph:SetText("Player HP")

    condFrame.l_pm  = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.l_pm:SetPoint("TOPLEFT", condFrame.l_ph, "BOTTOMLEFT", 0, -14)
    condFrame.l_pm:SetText("Player Mana")

    condFrame.l_th  = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.l_th:SetPoint("TOPLEFT", condFrame.l_pm, "BOTTOMLEFT", 0, -14)
    condFrame.l_th:SetText("Target HP")

    -- kleine Button-Factory
    local function MakeBtn(parent, w, h)
      local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
      b:SetWidth(w or 60); b:SetHeight(h or 18)
      return b
    end

    -- Comparator-Buttons (Dewdrop-Menüs mit ≤ / ≥)
    condFrame.phCmpBtn = MakeBtn(condFrame, 50, 18)
    condFrame.phCmpBtn:SetPoint("LEFT", condFrame.l_ph, "RIGHT", 6, 0)

    condFrame.pmCmpBtn = MakeBtn(condFrame, 50, 18)
    condFrame.pmCmpBtn:SetPoint("LEFT", condFrame.l_pm, "RIGHT", 6, 0)

    condFrame.thCmpBtn = MakeBtn(condFrame, 50, 18)
    condFrame.thCmpBtn:SetPoint("LEFT", condFrame.l_th, "RIGHT", 6, 0)

    -- Prozent-Editboxen daneben (nutzt deine vorhandene Helper-Funktion)
    condFrame.e_ph = CreateSmallEditBox(condFrame, 50)
    condFrame.e_ph:SetPoint("LEFT", condFrame.phCmpBtn, "RIGHT", 6, 0)

    condFrame.e_pm = CreateSmallEditBox(condFrame, 50)
    condFrame.e_pm:SetPoint("LEFT", condFrame.pmCmpBtn, "RIGHT", 6, 0)

    condFrame.e_th = CreateSmallEditBox(condFrame, 50)
    condFrame.e_th:SetPoint("LEFT", condFrame.thCmpBtn, "RIGHT", 6, 0)

    -- Logik (AND/OR) Button
    condFrame.l_logic = condFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    condFrame.l_logic:SetPoint("TOPLEFT", condFrame.l_th, "BOTTOMLEFT", 0, -18)
    condFrame.l_logic:SetText("Combine:")

    condFrame.logicBtn = MakeBtn(condFrame, 100, 18)
    condFrame.logicBtn:SetPoint("LEFT", condFrame.l_logic, "RIGHT", 6, 0)

    -- Speichern der Zahlen beim Fokusverlust
    local function bindSaver(box, key)
      box:SetScript("OnEditFocusLost", function()
        local v = tonumber(this:GetText())
        entry[key] = v
      end)
    end
    bindSaver(condFrame.e_ph, "TH_player_hp")
    bindSaver(condFrame.e_pm, "TH_player_mana")
    bindSaver(condFrame.e_th, "TH_target_hp")

    -- OnClick Menüs (Dewdrop)
    local function OpenCmpMenu(btn, key)
      local b = btn
      Dewdrop:Open(b, 'children', function(level, value)
        Dewdrop:AddLine('text', "≤", 'func', function()
          entry[key] = "<="; b:SetText("≤"); Dewdrop:Close()
        end)
        Dewdrop:AddLine('text', "≥", 'func', function()
          entry[key] = ">="; b:SetText("≥"); Dewdrop:Close()
        end)
      end)
    end

    condFrame.phCmpBtn:SetScript("OnClick", function() OpenCmpMenu(this, "TH_player_hp_cmp") end)
    condFrame.pmCmpBtn:SetScript("OnClick", function() OpenCmpMenu(this, "TH_player_mana_cmp") end)
    condFrame.thCmpBtn:SetScript("OnClick", function() OpenCmpMenu(this, "TH_target_hp_cmp") end)

    condFrame.logicBtn:SetScript("OnClick", function()
      local b = this
      Dewdrop:Open(b, 'children', function(level, value)
        Dewdrop:AddLine('text', "ALL (AND)", 'func', function()
          entry.TH_mode = "AND"; b:SetText("ALL (AND)"); Dewdrop:Close()
        end)
        Dewdrop:AddLine('text', "ANY (OR)",  'func', function()
          entry.TH_mode = "OR";  b:SetText("ANY (OR)");  Dewdrop:Close()
        end)
      end)
    end)
  end

  -- Werte in die UI laden
  condFrame.phCmpBtn:SetText(cmpLabel(entry.TH_player_hp_cmp or "<="))
  condFrame.pmCmpBtn:SetText(cmpLabel(entry.TH_player_mana_cmp or "<="))
  condFrame.thCmpBtn:SetText(cmpLabel(entry.TH_target_hp_cmp or "<="))
  condFrame.logicBtn:SetText(logicLabel(entry.TH_mode or "AND"))

  condFrame.e_ph:SetText(entry.TH_player_hp   and tostring(entry.TH_player_hp)   or "")
  condFrame.e_pm:SetText(entry.TH_player_mana and tostring(entry.TH_player_mana) or "")
  condFrame.e_th:SetText(entry.TH_target_hp   and tostring(entry.TH_target_hp)   or "")

  -- andocken + anzeigen
  condFrame:ClearAllPoints()
  if anchor then
    condFrame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
  else
    condFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
  condFrame:Show()
end



-- =========================
-- UI: Prio-List
-- =========================
function AutoLock:PrioScrollUpdate()
  if not frame or not scroll then return end

  local filtered = AutoLockUI_GetFiltered()
  local total = table.getn(filtered)

  local offset = FauxScrollFrame_GetOffset(scroll)
  local maxOff = math.max(total - VISIBLE_ROWS, 0)
  if offset > maxOff then
    offset = maxOff
    FauxScrollFrame_SetOffset(scroll, offset)
  end

  FauxScrollFrame_Update(scroll, total, VISIBLE_ROWS, ROW_HEIGHT + ROW_SPACING)

  for i = 1, VISIBLE_ROWS do
    local row = rows[i]
    local idx = offset + i
    row.index = idx

    if idx >= 1 and idx <= total then
      local e = filtered[idx]
      row.entry = e

      row:Show()
      row.check:SetChecked(e.enabled ~= false and 1 or nil)
      row.nameText:SetText((e.uitext or e.name or "?") .. " (" .. (e.type or "?") .. ")")
      row.prioText:SetText("Prio: " .. tostring(e.priority or idx))

      if e.enabled == false then
        row.nameText:SetTextColor(0.5, 0.5, 0.5)
        row.prioText:SetTextColor(0.5, 0.5, 0.5)
      else
        row.nameText:SetTextColor(1, 0.82, 0)
        row.prioText:SetTextColor(1, 1, 0)
      end

      -- Refresh-Edit nur (cast/curse) – Label ist oben im Header
      if e.type == "curse" then
        row.refreshBox:Show()
        row.refreshBox.settingEntry = e
        row.refreshBox:SetText(e.refreshtime and tostring(e.refreshtime) or "")
        row.refreshBox:SetScript("OnEditFocusLost", function()
          local v = tonumber(this:GetText())
          local tgt = this.settingEntry
          if tgt then tgt.refreshtime = v end
        end)
      else
        row.refreshBox:Hide()
        row.refreshBox.settingEntry = nil
      end

      row.check:SetScript("OnClick", function()
        e.enabled = (row.check:GetChecked() and true) or false
        AutoLock:PrioScrollUpdate()
      end)

      row.up:SetScript("OnClick", function()
        local realIdx
        for k, v in ipairs(SPELL_PRIORITY) do if v == e then realIdx = k; break end end
        if realIdx and realIdx > 1 then
          MoveEntry(realIdx, realIdx - 1)
          AutoLock:PrioScrollUpdate()
        end
      end)

      row.down:SetScript("OnClick", function()
        local realIdx
        for k, v in ipairs(SPELL_PRIORITY) do if v == e then realIdx = k; break end end
        if realIdx and realIdx < table.getn(SPELL_PRIORITY) then
          MoveEntry(realIdx, realIdx + 1)
          AutoLock:PrioScrollUpdate()
        end
      end)

      if idx <= 1 then row.up:Disable() else row.up:Enable() end
      if idx >= total then row.down:Disable() else row.down:Enable() end
    else
      row:Hide()
    end
  end
  SaveCurrentConfigSpells()
end

local function CreatePrioUIOnce(parent)
  if scroll then return end

  SortByPriorityNumbers()
  RenumberPriorities()

  -- ==== Kopfzeile: Name | Prio | Refresh ====
  header.name = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  header.name:SetPoint("TOPLEFT", parent, "TOPLEFT", 32, -97)
  header.name:SetText("Name")

  header.prio = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  header.prio:SetPoint("LEFT", header.name, "RIGHT", NAME_W + GAP, 0)
  header.prio:SetText("Prio")

  header.refresh = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  header.refresh:SetPoint("LEFT", header.prio, "LEFT", PRIO_W + GAP - REF_W - 15, 0)
  header.refresh:SetText("Refresh (s)")

  -- ==== ScrollFrame ====
  scroll = CreateFrame("ScrollFrame", "AutoLockPrioScroll", parent, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT",     parent, "TOPLEFT",   8, -91)
  scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 34)
  scroll:EnableMouse(false)
  scroll:EnableMouseWheel(true)

  scroll:SetScript("OnVerticalScroll", function()
    FauxScrollFrame_OnVerticalScroll(arg1, ROW_HEIGHT + ROW_SPACING, function()
      AutoLock:PrioScrollUpdate()
    end)
  end)

  scroll:SetScript("OnMouseWheel", function()
    local delta  = arg1 or 0
    local total  = table.getn(AutoLockUI_GetFiltered())
    local off    = FauxScrollFrame_GetOffset(scroll) - delta
    local maxOff = math.max(total - VISIBLE_ROWS, 0)
    if off < 0 then off = 0 end
    if off > maxOff then off = maxOff end
    FauxScrollFrame_SetOffset(scroll, off)
    AutoLock:PrioScrollUpdate()
  end)

  -- ==== Zeilen ====
  for i = 1, VISIBLE_ROWS do
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("LEFT",  parent, "LEFT", 10, 0)
    row:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    if i == 1 then
      row:SetPoint("TOP", parent, "TOP", 0, -115)
    else
      row:SetPoint("TOP", rows[i-1], "BOTTOM", 0, -ROW_SPACING)
    end
    row:SetFrameLevel(scroll:GetFrameLevel() + 2)

    -- Checkbox
    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetWidth(16); row.check:SetHeight(16)
    row.check:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.check:SetFrameLevel(row:GetFrameLevel() + 1)

    -- Name/Typ (erste Spalte)
    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.nameText:SetPoint("LEFT", row.check, "RIGHT", GAP, 0)
    row.nameText:SetWidth(NAME_W)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetNonSpaceWrap(false)

    -- Prio-Text (zweite Spalte)
    row.prioText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.prioText:SetPoint("LEFT", row.nameText, "RIGHT", GAP, 0)
    row.prioText:SetWidth(PRIO_W)
    row.prioText:SetJustifyH("CENTER")

    -- Refresh EditBox (dritte Spalte, nur bei curse sichtbar)
		row.refreshBox = CreateFrame("EditBox", nil, row)
		row.refreshBox:SetAutoFocus(false)
		row.refreshBox:SetWidth(REF_W)        -- z.B. 40–60 ist gut
		row.refreshBox:SetHeight(18)
		row.refreshBox:SetPoint("LEFT", row.prioText, "RIGHT", GAP, 0)
		row.refreshBox:SetFontObject(GameFontHighlightSmall)
		row.refreshBox:SetJustifyH("LEFT")
		row.refreshBox:SetTextInsets(4, 0, 0, 0) 

		-- eigener Backdrop (schlicht, Vanilla-kompatibel)
		row.refreshBox:SetBackdrop({
			bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 }
		})
		row.refreshBox:SetBackdropColor(0,0,0,0.6)

		-- Eingabe-Logik
		row.refreshBox:SetScript("OnTextChanged", function()
			local txt = this:GetText() or ""
			local clean = SanitizeNumberText(txt)
			if clean ~= txt then this:SetText(clean) end
		end)
		row.refreshBox:SetScript("OnEnterPressed",  function() this:ClearFocus() end)
		row.refreshBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)
		
		

    -- Up/Down Buttons (rechte Seite)
    row.down = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.down:SetText("Down")
    row.down:SetWidth(BTN_W); row.down:SetHeight(18)
    row.down:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.down:SetFrameLevel(row:GetFrameLevel() + 1)

    row.up = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.up:SetText("Up")
    row.up:SetWidth(BTN_W); row.up:SetHeight(18)
    row.up:SetPoint("RIGHT", row.down, "LEFT", -GAP, 0)
    row.up:SetFrameLevel(row:GetFrameLevel() + 1)
		
		-- NEU: Conditions-Button (links von Up)
    row.cond = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.cond:SetText("Cond")
    row.cond:SetWidth(54); row.cond:SetHeight(18)
    row.cond:SetPoint("RIGHT", row.up, "LEFT", -GAP, 0)
    row.cond:SetFrameLevel(row:GetFrameLevel() + 1)
    row.cond:SetScript("OnClick", function()
      -- row.entry wird in PrioScrollUpdate pro Zeile gesetzt
      ShowCondFrameForEntry(row.entry, row)
    end)

    rows[i] = row
  end
end




-- =========================
-- Main Frame
-- =========================
function AutoLock:CreateUI()
  if frame then return end
  self:InitConfigs()  -- ensure AutoLockDB.configs is populated before rendering

  frame = CreateFrame("Frame", "AutoLockFrame", UIParent)
  frame:SetWidth(700)
  frame:SetHeight((ROW_HEIGHT+ROW_SPACING)*VISIBLE_ROWS + 147)
  frame:ClearAllPoints()
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  frame:SetFrameStrata("DIALOG")

  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function() this:StartMoving() end)
  frame:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)

  frame:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
  })
  frame:SetBackdropColor(0,0,0,0.85)

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", frame, "TOP", 0, -8)
  title:SetText("AutoLock – Spell Priorities")

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

  configStrip = CreateFrame("Frame", "AutoLockConfigStrip", frame)
  configStrip:SetPoint("TOPLEFT",  frame, "TOPLEFT",  6, -26)
  configStrip:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -26)
  configStrip:SetHeight(52)
  configStrip:SetBackdrop({
    bgFile="Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
    tile=true, tileSize=16, edgeSize=8,
    insets={left=2, right=2, top=2, bottom=2}
  })
  configStrip:SetBackdropColor(0, 0, 0, 0.4)
  AutoLockRefreshConfigList()

  local filterCheck = CreateFrame("CheckButton", "AutoLockFilterCheck", frame, "UICheckButtonTemplate")
  filterCheck:SetWidth(20); filterCheck:SetHeight(20)
  filterCheck:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -83)
  filterCheck:SetChecked(AutoLockUI_ShowDisabled and 1 or nil)
  filterCheck.text = filterCheck:CreateFontString(nil,	  "OVERLAY", "GameFontNormalSmall")
  filterCheck.text:SetPoint("LEFT", filterCheck, "RIGHT", 4, 0)
  filterCheck.text:SetText("Show disabled")
  filterCheck:SetScript("OnClick", function()
    AutoLockUI_ShowDisabled = (filterCheck:GetChecked() == 1)
    if scroll then FauxScrollFrame_SetOffset(scroll, 0) end
    AutoLock:PrioScrollUpdate()
  end)

  local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  refresh:SetWidth(90); refresh:SetHeight(20)
  refresh:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 10)
  refresh:SetText("Apply")
  refresh:SetScript("OnClick", function() AutoLock:PrioScrollUpdate() end)
	
	local newCofig = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  newCofig:SetWidth(90); newCofig:SetHeight(20)
  newCofig:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 120, 10)
  newCofig:SetText("New Config")
  newCofig:SetScript("OnClick", function() AutoLockNewConfigFrame:Show() end)
	
	

  CreatePrioUIOnce(frame)
  AutoLock:PrioScrollUpdate()

  frame:Hide()
end

function AutoLock:ShowUI()
  self:CreateUI()
  frame:Show()
  AutoLockRefreshConfigList()
end
function AutoLock:HideUI()   if frame then frame:Hide() end end
function AutoLock:ToggleUI()
  self:CreateUI()
  if frame:IsShown() then
    frame:Hide()
  else
    frame:Show()
    AutoLockRefreshConfigList()
  end
end

-- =========================
-- Minimap-Button (ohne GetCursorPosition)
-- =========================
function AutoLock:CreateMinimapButton()
  if miniBtn then return end

  miniBtn = CreateFrame("Button", "AutoLockMiniBtn", Minimap)
  miniBtn:SetWidth(32); miniBtn:SetHeight(32)
  miniBtn:SetFrameStrata("MEDIUM")
  -- center-basierter Offset (robuster, kein Cursor nötig)
  miniBtn:SetPoint("CENTER", Minimap, "CENTER", AutoLockDB.minimap.x or 0, AutoLockDB.minimap.y or 0)

  local border = miniBtn:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetWidth(56); border:SetHeight(56)
  border:SetPoint("TOPLEFT", miniBtn, "TOPLEFT")

  local icon = miniBtn:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture("Interface\\Icons\\Spell_Shadow_Shadowbolt")
  icon:SetWidth(20); icon:SetHeight(20)
  icon:SetPoint("CENTER", miniBtn, "CENTER", 0, 0)

  miniBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  miniBtn:GetHighlightTexture():SetBlendMode("ADD")

  miniBtn:RegisterForDrag("LeftButton")
  miniBtn:SetMovable(true)
  miniBtn:SetScript("OnDragStart", function() this:StartMoving() end)
  miniBtn:SetScript("OnDragStop", function()
    this:StopMovingOrSizing()
    -- neue Ankerung relativ zur Minimap-Mitte, OHNE Cursor-APIs
    local bx, by = this:GetCenter()
    local mx, my = Minimap:GetCenter()
    if bx and by and mx and my then
      local x = bx - mx
      local y = by - my
      -- sanft begrenzen (damit er nicht endlos wegdriftet)
      if x > 120 then x = 120 end
      if x < -120 then x = -120 end
      if y > 120 then y = 120 end
      if y < -120 then y = -120 end
      this:ClearAllPoints()
      this:SetPoint("CENTER", Minimap, "CENTER", x, y)
      AutoLockDB.minimap.x = x
      AutoLockDB.minimap.y = y
    end
  end)

  miniBtn:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_LEFT")
    GameTooltip:SetText("AutoLock", 1,1,1)
    GameTooltip:AddLine("Klick: Prio-UI öffnen", .9,.9,.9)
    GameTooltip:Show()
  end)
  miniBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  miniBtn:SetScript("OnClick", function() AutoLock:ToggleUI() end)
end

function AutoLock:InitUI()
  self:InitConfigs()
  self:CreateMinimapButton()
  AutoLockLog.Info("Loaded.")
end

AutoLockSelectedIcon = nil
AutoLockEditingConfig = nil
function AutoLockNewConfigPopupFrame_Update()
    local numMacroIcons = GetNumMacroIcons()
    local offset = FauxScrollFrame_GetOffset(AutoLockNewConfigPopupScrollFrame)
		local num_macros_icons_shown = 25
		local num_icons_per_row = 5
		local num_icons_rows = 6
		local macro_icon_row_height = 36;
		
    for i = 1, num_macros_icons_shown do
        local index = offset * num_icons_per_row + i

        local button = _G["AutoLockNewConfigPopupButton"..i]
        local icon   = _G["AutoLockNewConfigPopupButton"..i.."Icon"]

        if index <= numMacroIcons then
            icon:SetTexture(GetMacroIconInfo(index))
            button:Show()
        else
            icon:SetTexture(nil)
            button:Hide()
        end
				
				if index == AutoLockSelectedIcon then
					button:SetChecked(true)
				else
					button:SetChecked(false)
				end
    end

    FauxScrollFrame_Update(
        AutoLockNewConfigPopupScrollFrame,
        ceil(numMacroIcons / num_icons_per_row),
        num_icons_rows,
        macro_icon_row_height
    )
end

function AutoLockNewConfigPopupFrame_OnHide()
    if AutoLockNewConfigPopupEditBox then
        AutoLockNewConfigPopupEditBox:ClearFocus()
    end
    AutoLockSelectedIcon = nil
    AutoLockEditingConfig = nil

    if AutoLockConfigFrameOkayButton then
        AutoLockConfigFrameOkayButton:Enable()
        AutoLockConfigFrameOkayButton:SetText("OKAY")
    end
    if AutoLockConfigFrameCancelButton then
        AutoLockConfigFrameCancelButton:Enable()
    end

    if AutoLockNewConfigPopupEditBox then
        AutoLockNewConfigPopupEditBox:SetText("")
    end

    if AutoLockRefreshConfigList then
        AutoLockRefreshConfigList()
    end
end

function AutoLockNewConfigPopupButton_OnClick()
		local num_icons_per_row = 5
    AutoLockSelectedIcon =
        this:GetID() + FauxScrollFrame_GetOffset(AutoLockNewConfigPopupScrollFrame) * num_icons_per_row

    AutoLockNewConfigPopupFrame_Update() -- WICHTIG!
end

-- =========================
-- Config macro pickup helper
-- =========================
local function AutoLockPickupConfigMacro(cfg)
  if not (CreateMacro and GetMacroIndexByName and EditMacro and PickupMacro and GetNumMacros) then
    AutoLockLog.Warning("Macro API not available.")
    return
  end
  local macroName = "AL:" .. string.sub(cfg.name, 1, 12)
  local iconIndex  = cfg.icon or 1
  local macroBody  = '/run AutoLock:LoadConfigByName("'..cfg.name..'");AutoLock:DoAutoLock()'
  local id = GetMacroIndexByName(macroName)
  if id and id > 0 then
    pcall(function() EditMacro(id, macroName, iconIndex, macroBody, 1) end)
  else
    local globalCount, charCount = GetNumMacros()
    if (globalCount or 0) >= 18 and (charCount or 0) >= 18 then
      AutoLockLog.Warning("No free macro slots.")
      return
    end
    id = CreateMacro(macroName, iconIndex, macroBody, 1)
    if not id then
      AutoLockLog.Error("Could not create macro.")
      return
    end
  end
  PickupMacro(id)
end

local function AutoLockOpenEditConfig(cfg)
  AutoLockEditingConfig = cfg
  AutoLockSelectedIcon  = cfg.icon
  AutoLockNewConfigPopupEditBox:SetText(cfg.name)
  AutoLockConfigFrameOkayButton:SetText("Save")
  AutoLockNewConfigFrame:Show()
  AutoLockNewConfigPopupFrame_Update()
end

-- =========================
-- Config strip renderer
-- =========================
function AutoLockRefreshConfigList()
  if not configStrip then return end
  if not AutoLockDB or not AutoLockDB.configs then return end
  -- Calling GetNumMacroIcons() primes the macro icon list in WoW 1.12's lazy-load
  -- system, so subsequent GetMacroIconInfo() calls return valid texture paths.
  if GetNumMacroIcons then GetNumMacroIcons() end
  for _, b in ipairs(configBtns) do b:Hide() end
  configBtns = {}
  local x = 6
  for _, cfg in ipairs(AutoLockDB.configs) do
    local btn = CreateFrame("Button", nil, configStrip)
    btn:SetWidth(46); btn:SetHeight(50)
    btn:SetPoint("TOPLEFT", configStrip, "TOPLEFT", x, -2)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    local isActive = (AutoLockDB.activeConfig == cfg.name)

    local borderBg = btn:CreateTexture(nil, "BACKGROUND")
    borderBg:SetWidth(40); borderBg:SetHeight(40)
    borderBg:SetPoint("TOP", btn, "TOP", 0, -1)
    borderBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    borderBg:SetVertexColor(1, 0.82, 0, 1)
    if not isActive then borderBg:Hide() end

    local iconTex = btn:CreateTexture(nil, "ARTWORK")
    iconTex:SetWidth(36); iconTex:SetHeight(36)
    iconTex:SetPoint("TOP", btn, "TOP", 0, -2)
    local iconResult = cfg.icon and cfg.icon > 0 and GetMacroIconInfo(cfg.icon) or nil
    if type(iconResult) ~= "string" or iconResult == "" then
      iconResult = "Interface\\Icons\\INV_Misc_QuestionMark"
    elseif not string.find(iconResult, "\\") and not string.find(iconResult, "/") then
      -- GetMacroIconInfo returned a bare name with no path separator; prepend full path
      iconResult = "Interface\\Icons\\" .. iconResult
    end
    iconTex:SetTexture(iconResult)
    if isActive then
      iconTex:SetVertexColor(1, 1, 1)
    else
      iconTex:SetVertexColor(0.6, 0.6, 0.6)
    end

    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOP", iconTex, "BOTTOM", 0, -1)
    lbl:SetWidth(46); lbl:SetJustifyH("CENTER")
    local short = string.sub(cfg.name, 1, 6)
    if string.len(cfg.name) > 6 then short = short .. ".." end
    lbl:SetText(short)

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")

    local cfgRef = cfg

    btn:SetScript("OnEnter", function()
      GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
      GameTooltip:SetText(cfgRef.name, 1, 0.82, 0)
      GameTooltip:AddLine("Left-click: Load config", 0.9, 0.9, 0.9)
      GameTooltip:AddLine("Shift + drag: Place on action bar", 0.9, 0.9, 0.9)
      GameTooltip:AddLine("Right-click: Edit", 0.9, 0.9, 0.9)
      GameTooltip:AddLine("Shift + right-click: Delete", 0.9, 0.9, 0.9)
      GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
      GameTooltip:Hide()
    end)

    btn:SetScript("OnDragStart", function()
      if IsShiftKeyDown and IsShiftKeyDown() then
        AutoLockPickupConfigMacro(cfgRef)
      end
    end)

    btn:SetScript("OnClick", function()
      local shift = IsShiftKeyDown and IsShiftKeyDown()
      if arg1 == "RightButton" then
        if shift then
          AutoLock_PendingDeleteConfig = cfgRef
          StaticPopup_Show("AUTOLOCK_DELETE_CONFIG", cfgRef.name)
        else
          AutoLockOpenEditConfig(cfgRef)
        end
      else  -- LeftButton
        if not shift then
          LoadConfig(cfgRef)
        end
      end
    end)

    table.insert(configBtns, btn)
    x = x + 50
  end
end

-- =========================
-- Delete confirmation
-- =========================
StaticPopupDialogs["AUTOLOCK_DELETE_CONFIG"] = {
  text = "Are you sure you want to delete this configuration?",
  button1 = "Delete", button2 = "Cancel",
  OnAccept = function()
    local cfg = AutoLock_PendingDeleteConfig
    if not cfg then return end
    local newList = {}
    for _, c in ipairs(AutoLockDB.configs) do
      if c.name ~= cfg.name then table.insert(newList, c) end
    end
    AutoLockDB.configs = newList
    if AutoLockDB.activeConfig == cfg.name then
      if table.getn(AutoLockDB.configs) > 0 then
        LoadConfig(AutoLockDB.configs[1])
      else
        AutoLockDB.activeConfig = nil
        AutoLockRefreshConfigList()
      end
    else
      AutoLockRefreshConfigList()
    end
  end,
  timeout=0, whileDead=1, hideOnEscape=1,
}
AutoLock_PendingDeleteConfig = nil

-- =========================
-- New-config save
-- =========================
function AutoLockNewConfigPopup_Save()
  local name = AutoLockNewConfigPopupEditBox and AutoLockNewConfigPopupEditBox:GetText() or ""
  name = string.gsub(name, "^%s+", "")
  name = string.gsub(name, "%s+$", "")
  if name == "" then
    AutoLockLog.Warning("Config name cannot be empty.")
    return
  end

  if AutoLockEditingConfig then
    -- Edit mode: allow same name, disallow collision with OTHER configs
    for _, c in ipairs(AutoLockDB.configs) do
      if c.name == name and c ~= AutoLockEditingConfig then
        AutoLockLog.Warning("Config \"" .. name .. "\" already exists.")
        return
      end
    end
    if AutoLockDB.activeConfig == AutoLockEditingConfig.name then
      AutoLockDB.activeConfig = name
    end
    AutoLockEditingConfig.name = name
    AutoLockEditingConfig.icon = AutoLockSelectedIcon or AutoLockEditingConfig.icon
    AutoLockNewConfigFrame:Hide()
  else
    -- Create mode: existing logic unchanged
    for _, c in ipairs(AutoLockDB.configs) do
      if c.name == name then
        AutoLockLog.Warning("Config \"" .. name .. "\" already exists.")
        return
      end
    end
    local newCfg = { name=name, icon=AutoLockSelectedIcon or 1, spells=SnapshotSpells() }
    table.insert(AutoLockDB.configs, newCfg)
    AutoLockNewConfigFrame:Hide()  -- triggers OnHide (clears editbox + icon)
    LoadConfig(newCfg)
  end
end

-- =========================
-- InitConfigs
-- =========================
function AutoLock:InitConfigs()
  if not AutoLockDB then
    AutoLockDB = { minimap = { x = -6, y = -6 }, configs = {}, activeConfig = nil }
  end
  if not AutoLockDB.minimap then AutoLockDB.minimap = { x = -6, y = -6 } end
  if not AutoLockDB.configs then AutoLockDB.configs = {} end
  if table.getn(AutoLockDB.configs) == 0 then
    -- Seed a "Default" config from the current SPELL_PRIORITY state.
    SortByPriorityNumbers()
    RenumberPriorities()
    table.insert(AutoLockDB.configs, { name="Default", icon=1, spells=SnapshotSpells() })
    AutoLockDB.activeConfig = "Default"
  end
  local cfg = GetActiveConfig()
  if cfg then ApplyConfigToSpells(cfg) end
end

