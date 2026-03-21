-- AutoLock: Ace2 Mini UI (Vanilla 1.12)

local Dewdrop = AceLibrary and AceLibrary("Dewdrop-2.0")


-- =========================
-- SavedVariables
-- =========================
AutoLockUI_ShowDisabled = true
AutoLockSearchText     = ""
AutoLockTypeFilter     = "all"

-- AutoLockDB is a SavedVariable: WoW restores it after VARIABLES_LOADED.
-- Ace2 may fire OnEnable() before that (via DEFAULT_CHAT_FRAME hack), so
-- we hook VARIABLES_LOADED directly and re-run InitConfigs with real data.
local autoLockVarFrame = CreateFrame("Frame")
autoLockVarFrame:RegisterEvent("VARIABLES_LOADED")
autoLockVarFrame:SetScript("OnEvent", function()
  if AutoLock and AutoLock.InitConfigs then
    AutoLock:InitConfigs()
    if AutoLock.CreateMinimapButton then
      AutoLock:CreateMinimapButton()
    end
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
  local search     = strlower(AutoLockSearchText or "")
  local typeFilter = AutoLockTypeFilter or "all"
  for _, e in ipairs(SPELL_PRIORITY) do
    if e._deleted then
      -- skip
    elseif not AutoLockUI_ShowDisabled and e.enabled == false then
      -- skip
    else
      local passType   = (typeFilter == "all") or (e.type == typeFilter)
      local passSearch = (search == "") or strfind(strlower(e.uitext or e.name or ""), search, 1)
      local passKnown  = true
      if AutoLockDB and AutoLockDB.settings and AutoLockDB.settings.hideUnknownSpells then
        local ks = AutoLock.KnownSpells
        -- only filter if KnownSpells is actually populated; an empty table means
        -- BuildKnownSpellSet ran before the spellbook was ready – don't hide everything
        if ks and next(ks) ~= nil and not ks[e.name] then
          passKnown = false
        end
      end
      if passType and passSearch and passKnown then
        table.insert(filtered, e)
      end
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
local ROW_HEIGHT, ROW_SPACING, VISIBLE_ROWS = 20, 4, 15
local miniBtn
local configStrip
local configBtns = {}
local settingsPanel

-- kleines Bedingungen-Fenster (einmalig wiederverwendet)
local condFrame

-- ESC schließt das oberste sichtbare AutoLock-Fenster
local _origCloseWindows = CloseWindows
CloseWindows = function()
  local picker = getglobal("AutoLockSpellPicker")
  if picker and picker:IsVisible() then
    picker:Hide()
    return true
  end
  local cond = getglobal("AutoLockConditionFrame")
  if cond and cond:IsVisible() then
    cond:Hide()
    return true
  end
  local settings = getglobal("AutoLockSettingsPanel")
  if settings and settings:IsVisible() then
    settings:Hide()
    return true
  end
  if frame and frame:IsVisible() then
    frame:Hide()
    return true
  end
  return _origCloseWindows()
end

-- Spaltenbreiten
local GRIP_W  = 22   -- Drag-Handle
local NAME_W  = 340  -- Spell-Name
local REF_W   = 40   -- Refresh-EditBox
local COND_W  = 56   -- Cond-Button
local DEL_W   = 22   -- Delete-Button
local CFG_W   = 36   -- Spell-Config-Button (z.B. Dark Harvest DoTs)
local GAP     = 8

-- =========================
-- Config helpers
-- =========================
-- Use uitext when available so Shadow Trance (Shadow Bolt) and
-- the filler Shadow Bolt don't share the same key.
local function GetSpellKey(e)
  return (e.uitext or e.name or "?").."|"..(e.type or "?")
end

-- Own tooltip frame so we don't share state/backdrop with GameTooltip
local AL_TT = CreateFrame("Frame", "AutoLockTooltip", UIParent)
AL_TT:SetFrameStrata("TOOLTIP")
AL_TT:SetFrameLevel(200)
AL_TT:SetBackdrop({
  bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left=4, right=4, top=4, bottom=4 },
})
AL_TT:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
AL_TT:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
AL_TT:Hide()

local AL_TT_title = AL_TT:CreateFontString(nil, "OVERLAY", "GameFontNormal")
AL_TT_title:SetPoint("TOPLEFT", AL_TT, "TOPLEFT", 8, -8)
AL_TT_title:SetJustifyH("LEFT")

local AL_TT_body = AL_TT:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
AL_TT_body:SetPoint("TOPLEFT", AL_TT_title, "BOTTOMLEFT", 0, -4)
AL_TT_body:SetJustifyH("LEFT")

local _AL_TT_NativeShow = AL_TT.Show

function AL_TT:SetOwner(owner, anchor)
  self:ClearAllPoints()
  if anchor == "ANCHOR_LEFT" then
    self:SetPoint("RIGHT", owner, "LEFT", -4, 0)
  elseif anchor == "ANCHOR_BOTTOM" then
    self:SetPoint("TOP", owner, "BOTTOM", 0, -4)
  elseif anchor == "ANCHOR_TOP" then
    self:SetPoint("BOTTOM", owner, "TOP", 0, 4)
  else
    self:SetPoint("LEFT", owner, "RIGHT", 4, 0)
  end
  self._ttLines = {}
end

function AL_TT:ClearLines()
  self._ttLines = {}
end

function AL_TT:AddLine(text, r, g, b)
  if not self._ttLines then self._ttLines = {} end
  self._ttLines[table.getn(self._ttLines) + 1] = { text=text, r=r or 1, g=g or 1, b=b or 1 }
end

function AL_TT:Show()
  local lines = self._ttLines or {}
  local n = table.getn(lines)
  -- Title
  AL_TT_title:SetWidth(0)
  AL_TT_title:SetText(n >= 1 and lines[1].text or "")
  if n >= 1 then AL_TT_title:SetTextColor(lines[1].r, lines[1].g, lines[1].b) end
  -- Body (remaining lines joined)
  AL_TT_body:SetWidth(0)
  if n >= 2 then
    local parts = {}
    for i = 2, n do parts[i-1] = lines[i].text end
    AL_TT_body:SetText(table.concat(parts, "\n"))
    AL_TT_body:SetTextColor(0.9, 0.9, 0.9)
  else
    AL_TT_body:SetText("")
  end
  -- Measure using GetWidth/GetHeight (vanilla 1.12 – SetWidth(0) lets string expand freely)
  local titleW = AL_TT_title:GetWidth()
  local bodyW  = AL_TT_body:GetWidth()
  local titleH = AL_TT_title:GetHeight()
  local bodyH  = (n >= 2) and AL_TT_body:GetHeight() or 0
  local gap    = (bodyH > 0) and 4 or 0
  self:SetWidth(math.max(titleW, bodyW) + 16)
  self:SetHeight(titleH + bodyH + gap + 16)
  _AL_TT_NativeShow(self)
end

local function ShowTooltip(owner, title, body)
  AL_TT:SetOwner(owner, "ANCHOR_RIGHT")
  AL_TT:ClearLines()
  AL_TT:AddLine(title, 1, 0.82, 0)
  AL_TT:AddLine(body, 0.9, 0.9, 0.9)
  AL_TT:Show()
end

local function GetActiveConfig()
  -- Gibt den gerade im UI geladenen Config zurück (Vorschau oder Combat-Config)
  local name = AutoLock._loadedConfigName or (AutoLockDB and AutoLockDB.activeConfig)
  for _, c in ipairs(AutoLockDB.configs) do
    if c.name == name then return c end
  end
end

local function SnapshotSpells()
  local t = {}
  for _, e in ipairs(SPELL_PRIORITY) do
    if not e._deleted then
      t[GetSpellKey(e)] = { enabled=e.enabled, priority=e.priority, refreshtime=e.refreshtime }
    end
  end
  return t
end

local function SaveCurrentConfigSpells()
  local cfg = GetActiveConfig()
  if not cfg then return end
  cfg.spells = {}
  for _, e in ipairs(SPELL_PRIORITY) do
    if not e._deleted then
      cfg.spells[GetSpellKey(e)] = {
        enabled=e.enabled, priority=e.priority, refreshtime=e.refreshtime,
        TH_player_hp=e.TH_player_hp,       TH_player_hp_cmp=e.TH_player_hp_cmp,
        TH_player_mana=e.TH_player_mana,   TH_player_mana_cmp=e.TH_player_mana_cmp,
        TH_target_hp=e.TH_target_hp,       TH_target_hp_cmp=e.TH_target_hp_cmp,
        TH_mode=e.TH_mode,
      }
    end
  end
  -- If the just-saved config is the one bound to the action bar, refresh its snapshot.
  if AutoLock._combatConfigName == cfg.name then
    AutoLock:_loadCombatSnapshot(cfg.name)
  end
end

local function ApplyConfigToSpells(cfg)
  AutoLock._loadedConfigName = cfg.name
  for _, e in ipairs(SPELL_PRIORITY) do
    e._deleted = nil  -- reset deletion flag from previous config
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
  if cfg.deletedSpells then
    for _, e in ipairs(SPELL_PRIORITY) do
      if cfg.deletedSpells[GetSpellKey(e)] then
        e._deleted = true
      end
    end
  end
  SortByPriorityNumbers()
  RenumberPriorities()
end

-- Lädt Config für Anzeige im UI, ändert NICHT AutoLockDB.activeConfig
local function PreviewConfig(cfg)
  if not cfg then return end
  ApplyConfigToSpells(cfg)
  if scroll then AutoLock:PrioScrollUpdate() end
  AutoLockRefreshConfigList()
end

local function LoadConfig(cfg)
  if not cfg then return end
  AutoLockDB.activeConfig = cfg.name
  ApplyConfigToSpells(cfg)
  if scroll then AutoLock:PrioScrollUpdate() end
  AutoLockRefreshConfigList()  -- forward ref to global defined below
end

-- Stellt den aktiven Combat-Config wieder her (z.B. nach UI-Vorschau)
function AutoLock:_reloadActiveCombatConfig()
  local name = AutoLockDB and AutoLockDB.activeConfig
  if not name then return end
  for _, cfg in ipairs(AutoLockDB.configs) do
    if cfg.name == name then
      local savedName = AutoLock._loadedConfigName
      ApplyConfigToSpells(cfg)
      AutoLock._loadedConfigName = savedName  -- goldener Rahmen bleibt auf zuletzt gewähltem Config
      return
    end
  end
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
  if not frame or not scroll then
    AutoLockLog.Warning("PrioScrollUpdate skipped: frame=" .. tostring(frame ~= nil) .. " scroll=" .. tostring(scroll ~= nil))
    return
  end

  local filtered = AutoLockUI_GetFiltered()
  local total = table.getn(filtered)
  if total == 0 then
    AutoLockLog.Warning("PrioScrollUpdate: 0 entries visible! SPELL_PRIORITY=" .. table.getn(SPELL_PRIORITY) .. " ShowDisabled=" .. tostring(AutoLockUI_ShowDisabled) .. " TypeFilter=" .. tostring(AutoLockTypeFilter))
  end

  local offset = FauxScrollFrame_GetOffset(scroll)
  local maxOff = math.max(total - VISIBLE_ROWS, 0)
  if offset > maxOff then
    offset = maxOff
    FauxScrollFrame_SetOffset(scroll, offset)
  end

  FauxScrollFrame_Update(scroll, total, VISIBLE_ROWS, ROW_HEIGHT + ROW_SPACING)

  for i = 1, VISIBLE_ROWS do
    local row = rows[i]
    if not row then
      AutoLockLog.Warning("PrioScrollUpdate: rows[" .. i .. "] is nil – UI not fully initialized")
      break
    end
    local idx = offset + i
    row.index = idx

    if idx >= 1 and idx <= total then
      local e = filtered[idx]
      row.entry = e

      row:Show()
      row.check:SetChecked(e.enabled ~= false and 1 or nil)
      row.nameText:SetText((e.uitext or e.name or "?") .. " (" .. (e.type or "?") .. ")")

      if e.enabled == false then
        row.nameText:SetTextColor(0.5, 0.5, 0.5)
      else
        row.nameText:SetTextColor(1, 0.82, 0)
      end

      if e.name == "Dark Harvest" or e.name == "Drain Soul" then
        row.cfgBtn:Show()
      else
        row.cfgBtn:Hide()
      end

      if e.type == "curse" then
        row.refreshBox:Show()
        row.refreshBox.settingEntry = e
        row.refreshBox:SetText(e.refreshtime and tostring(e.refreshtime) or "")
        row.refreshBox:SetScript("OnEditFocusLost", function()
          local v = tonumber(this:GetText())
          local tgt = this.settingEntry
          if tgt then
            tgt.refreshtime = v
            SaveCurrentConfigSpells()
          end
        end)
      else
        row.refreshBox:Hide()
        row.refreshBox.settingEntry = nil
      end

      row.check:SetScript("OnClick", function()
        -- Toggle stored value; do NOT use GetChecked() which returns the pre-click
        -- state in vanilla 1.12 and would invert the intended change.
        e.enabled = not (e.enabled == true)
        AutoLock:PrioScrollUpdate()
      end)
    else
      row:Hide()
    end
  end
  SaveCurrentConfigSpells()
end

-- =========================
-- Dark Harvest DoTs Popup
-- =========================
local dhDotsPopup = nil

local function ShowDHDotsPopup(anchor)
  if not dhDotsPopup then
    dhDotsPopup = CreateFrame("Frame", "AutoLockDHDotsPopup", UIParent)
    dhDotsPopup:SetWidth(220); dhDotsPopup:SetHeight(212)
    dhDotsPopup:SetFrameStrata("TOOLTIP")
    dhDotsPopup:SetBackdrop({
      bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })
    dhDotsPopup:SetBackdropColor(0.1, 0.1, 0.15, 1)
    dhDotsPopup:EnableMouse(true)
    dhDotsPopup:SetMovable(true)
    dhDotsPopup:RegisterForDrag("LeftButton")
    dhDotsPopup:SetScript("OnDragStart", function() this:StartMoving() end)
    dhDotsPopup:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)

    local title = dhDotsPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOP", dhDotsPopup, "TOP", 0, -10)
    title:SetText("Dark Harvest requires DoTs:")

    local closeBtn = CreateFrame("Button", nil, dhDotsPopup, "UIPanelCloseButton")
    closeBtn:SetWidth(18); closeBtn:SetHeight(18)
    closeBtn:SetPoint("TOPRIGHT", dhDotsPopup, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() dhDotsPopup:Hide() end)

    local function makeDotCheck(key, label, prevAnchor, yOffset, tooltip)
      local cb = CreateFrame("CheckButton", nil, dhDotsPopup, "UICheckButtonTemplate")
      cb:SetWidth(18); cb:SetHeight(18)
      if prevAnchor then
        cb:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 0, yOffset or -6)
      else
        cb:SetPoint("TOPLEFT", dhDotsPopup, "TOPLEFT", 10, -30)
      end
      cb:SetScript("OnClick", function()
        local cfg = GetActiveConfig()
        if not cfg then return end
        if not cfg.darkHarvestDots then cfg.darkHarvestDots = {} end
        local newVal = not (cfg.darkHarvestDots[key] == true)
        cfg.darkHarvestDots[key] = newVal
        cb:SetChecked(newVal and 1 or nil)
      end)
      if tooltip then
        cb:SetScript("OnEnter", function() ShowTooltip(this, label, tooltip) end)
        cb:SetScript("OnLeave", function() AL_TT:Hide() end)
      end
      local lbl = dhDotsPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
      lbl:SetText(label)
      cb._key = key
      return cb
    end

    dhDotsPopup.agonyCheck      = makeDotCheck("agony",      "Curse of Agony",
      nil, nil, "Curse of Agony must be active on the\ntarget before Dark Harvest can be cast.")
    dhDotsPopup.corruptionCheck = makeDotCheck("corruption", "Corruption",
      dhDotsPopup.agonyCheck, nil, "Corruption must be active on the\ntarget before Dark Harvest can be cast.")
    dhDotsPopup.siphonCheck     = makeDotCheck("siphonLife", "Siphon Life",
      dhDotsPopup.corruptionCheck, nil, "Siphon Life must be active on the\ntarget before Dark Harvest can be cast.")
    dhDotsPopup.shadowVulnCheck = makeDotCheck("shadowVuln", "Shadow Vulnerability",
      dhDotsPopup.siphonCheck, nil, "Shadow Vulnerability must be active on the\ntarget before Dark Harvest can be cast.")

    -- Divider
    local divider = dhDotsPopup:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetWidth(190)
    divider:SetPoint("TOPLEFT", dhDotsPopup.shadowVulnCheck, "BOTTOMLEFT", 0, -10)
    divider:SetTexture(0.4, 0.4, 0.4, 0.8)

    -- Nightfall checkbox (separate config key, not darkHarvestDots)
    local nightfallCb = CreateFrame("CheckButton", nil, dhDotsPopup, "UICheckButtonTemplate")
    nightfallCb:SetWidth(18); nightfallCb:SetHeight(18)
    nightfallCb:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -6)
    nightfallCb:SetScript("OnClick", function()
      local cfg = GetActiveConfig()
      if not cfg then return end
      local newVal = not (cfg.darkHarvestAllowNightfall == true)
      cfg.darkHarvestAllowNightfall = newVal
      nightfallCb:SetChecked(newVal and 1 or nil)
    end)
    local nightfallLbl = dhDotsPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nightfallLbl:SetPoint("LEFT", nightfallCb, "RIGHT", 4, 0)
    nightfallLbl:SetText("Allow Nightfall interrupt")
    nightfallCb:SetScript("OnEnter", function()
      ShowTooltip(this, "Allow Nightfall interrupt",
        "When checked, a Nightfall proc\n(Shadow Trance) interrupts the Dark\nHarvest channel and casts Shadow Bolt.")
    end)
    nightfallCb:SetScript("OnLeave", function() AL_TT:Hide() end)
    dhDotsPopup.nightfallCheck = nightfallCb

  end

  if dhDotsPopup:IsShown() and dhDotsPopup.anchor == anchor then
    dhDotsPopup:Hide()
    return
  end
  dhDotsPopup.anchor = anchor
  dhDotsPopup:ClearAllPoints()
  dhDotsPopup:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 4)

  -- Checkboxen vor Show() setzen damit der Zustand beim Öffnen korrekt ist
  local cfg = GetActiveConfig()
  local dh = (cfg and cfg.darkHarvestDots) or {}
  dhDotsPopup.agonyCheck:SetChecked(dh.agony and 1 or nil)
  dhDotsPopup.corruptionCheck:SetChecked(dh.corruption and 1 or nil)
  dhDotsPopup.siphonCheck:SetChecked(dh.siphonLife and 1 or nil)
  dhDotsPopup.shadowVulnCheck:SetChecked(dh.shadowVuln and 1 or nil)
  dhDotsPopup.nightfallCheck:SetChecked(cfg and cfg.darkHarvestAllowNightfall and 1 or nil)

  dhDotsPopup:Show()
end

-- =========================
-- Drain Soul DoTs Popup
-- =========================
local dsDotsPopup = nil

local function ShowDSDotsPopup(anchor)
  if not dsDotsPopup then
    dsDotsPopup = CreateFrame("Frame", "AutoLockDSDotsPopup", UIParent)
    dsDotsPopup:SetWidth(220); dsDotsPopup:SetHeight(148)
    dsDotsPopup:SetFrameStrata("TOOLTIP")
    dsDotsPopup:SetBackdrop({
      bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })
    dsDotsPopup:SetBackdropColor(0.1, 0.1, 0.15, 1)
    dsDotsPopup:EnableMouse(true)
    dsDotsPopup:SetMovable(true)
    dsDotsPopup:RegisterForDrag("LeftButton")
    dsDotsPopup:SetScript("OnDragStart", function() this:StartMoving() end)
    dsDotsPopup:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)

    local title = dsDotsPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOP", dsDotsPopup, "TOP", 0, -10)
    title:SetText("Allow renewal during DS channel:")

    local closeBtn = CreateFrame("Button", nil, dsDotsPopup, "UIPanelCloseButton")
    closeBtn:SetWidth(18); closeBtn:SetHeight(18)
    closeBtn:SetPoint("TOPRIGHT", dsDotsPopup, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() dsDotsPopup:Hide() end)

    local function makeDSCheck(key, label, prevAnchor, tooltip)
      local cb = CreateFrame("CheckButton", nil, dsDotsPopup, "UICheckButtonTemplate")
      cb:SetWidth(18); cb:SetHeight(18)
      if prevAnchor then
        cb:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 0, -6)
      else
        cb:SetPoint("TOPLEFT", dsDotsPopup, "TOPLEFT", 10, -30)
      end
      cb:SetScript("OnClick", function()
        local cfg = GetActiveConfig()
        if not cfg then return end
        if not cfg.drainSoulDots then cfg.drainSoulDots = {} end
        local newVal = not (cfg.drainSoulDots[key] == true)
        cfg.drainSoulDots[key] = newVal
        cb:SetChecked(newVal and 1 or nil)
      end)
      if tooltip then
        cb:SetScript("OnEnter", function() ShowTooltip(this, label, tooltip) end)
        cb:SetScript("OnLeave", function() AL_TT:Hide() end)
      end
      local lbl = dsDotsPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
      lbl:SetText(label)
      cb._key = key
      return cb
    end

    dsDotsPopup.agonyCheck      = makeDSCheck("agony",      "Curse of Agony",
      nil, "Checked: Curse of Agony and Curse of Shadow\ncan be renewed during Drain Soul.\nUnchecked: both are blocked to avoid\ninterrupting the channel.")
    dsDotsPopup.corruptionCheck = makeDSCheck("corruption", "Corruption",
      dsDotsPopup.agonyCheck, "Checked: Corruption can be renewed\nduring Drain Soul.\nUnchecked: blocked to avoid interrupting\nthe channel.")
    dsDotsPopup.siphonCheck     = makeDSCheck("siphonLife", "Siphon Life",
      dsDotsPopup.corruptionCheck, "Checked: Siphon Life can be renewed\nduring Drain Soul.\nUnchecked: blocked to avoid interrupting\nthe channel.")
  end

  if dsDotsPopup:IsShown() and dsDotsPopup.anchor == anchor then
    dsDotsPopup:Hide()
    return
  end
  dsDotsPopup.anchor = anchor
  dsDotsPopup:ClearAllPoints()
  dsDotsPopup:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 4)

  local cfg = GetActiveConfig()
  local ds = (cfg and cfg.drainSoulDots) or {}
  dsDotsPopup.agonyCheck:SetChecked(ds.agony      and 1 or nil)
  dsDotsPopup.corruptionCheck:SetChecked(ds.corruption and 1 or nil)
  dsDotsPopup.siphonCheck:SetChecked(ds.siphonLife and 1 or nil)

  dsDotsPopup:Show()
end

local function CreatePrioUIOnce(parent)
  if scroll then return end

  SortByPriorityNumbers()
  RenumberPriorities()

  -- ==== Drag-State ====
  local dragEntry    = nil
  local dropTargetRow = nil

  -- Ghost-Frame (folgt Cursor während Drag)
  local dragGhost = CreateFrame("Frame", "AutoLockDragGhost", UIParent)
  dragGhost:SetWidth(300); dragGhost:SetHeight(20)
  dragGhost:SetFrameStrata("TOOLTIP")
  dragGhost:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 8,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
  })
  dragGhost:SetBackdropColor(0.1, 0.3, 0.8, 0.85)
  local ghostText = dragGhost:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  ghostText:SetPoint("LEFT", dragGhost, "LEFT", 6, 0)
  ghostText:SetPoint("RIGHT", dragGhost, "RIGHT", 0, 0)
  ghostText:SetJustifyH("LEFT")
  ghostText:SetTextColor(1, 1, 1)
  dragGhost:Hide()

  -- Full-Screen Mouse-Catcher (empfängt OnMouseUp egal wo losgelassen)
  local mouseCatcher = CreateFrame("Frame", "AutoLockMouseCatcher", UIParent)
  mouseCatcher:SetAllPoints(UIParent)
  mouseCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
  mouseCatcher:EnableMouse(true)
  mouseCatcher:Hide()

  mouseCatcher:SetScript("OnUpdate", function()
    if not dragEntry then return end
    local cx, cy = GetCursorPosition()
    local s = UIParent:GetScale()
    dragGhost:ClearAllPoints()
    dragGhost:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", cx/s + 14, cy/s - 12)
    -- Ziel-Zeile unter Cursor bestimmen
    dropTargetRow = nil
    for _, r in ipairs(rows) do
      if r:IsShown() and r.entry and r.entry ~= dragEntry then
        local rb = r:GetBottom()
        local rt = r:GetTop()
        local rl = r:GetLeft()
        local rr = r:GetRight()
        if rb and rt and rl and rr then
          local ux, uy = cx/s, cy/s
          if ux >= rl and ux <= rr and uy >= rb and uy <= rt then
            dropTargetRow = r
          end
        end
      end
    end
    -- Drop-Indikatoren aktualisieren
    for _, r in ipairs(rows) do
      if r.dropIndicator then
        if r == dropTargetRow then r.dropIndicator:Show()
        else r.dropIndicator:Hide() end
      end
    end
  end)

  mouseCatcher:SetScript("OnMouseUp", function()
    mouseCatcher:Hide()
    dragGhost:Hide()
    for _, r in ipairs(rows) do
      if r.dropIndicator then r.dropIndicator:Hide() end
    end
    if dragEntry and dropTargetRow and dropTargetRow.entry and dragEntry ~= dropTargetRow.entry then
      local fromIdx, toIdx
      for k, v in ipairs(SPELL_PRIORITY) do
        if v == dragEntry     then fromIdx = k end
        if v == dropTargetRow.entry then toIdx   = k end
      end
      if fromIdx and toIdx then
        MoveEntry(fromIdx, toIdx)
        AutoLock:PrioScrollUpdate()
      end
    end
    dragEntry     = nil
    dropTargetRow = nil
  end)

  -- ==== Kopfzeile: Name | Refresh | Cond ====
  header.name = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  header.name:SetPoint("TOPLEFT", parent, "TOPLEFT", 60, -109)
  header.name:SetText("Name")

  header.refresh = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  header.refresh:SetPoint("TOPLEFT", parent, "TOPLEFT", 408, -109)
  header.refresh:SetText("Refresh (s)")

  header.cond = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  header.cond:SetPoint("TOPLEFT", parent, "TOPLEFT", 456, -109)
  header.cond:SetText("Cond")

  -- ==== ScrollFrame ====
  scroll = CreateFrame("ScrollFrame", "AutoLockPrioScroll", parent, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT",     parent, "TOPLEFT",   8, -107)
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
      row:SetPoint("TOP", parent, "TOP", 0, -131)
    else
      row:SetPoint("TOP", rows[i-1], "BOTTOM", 0, -ROW_SPACING)
    end
    row:SetFrameLevel(scroll:GetFrameLevel() + 2)

    -- Drop-Indikator (leuchtet auf wenn diese Zeile Drag-Ziel ist)
    row.dropIndicator = row:CreateTexture(nil, "OVERLAY")
    row.dropIndicator:SetAllPoints(row)
    row.dropIndicator:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    row.dropIndicator:SetBlendMode("ADD")
    row.dropIndicator:SetVertexColor(0.8, 0.4, 0, 0.8)
    row.dropIndicator:Hide()

    -- Drag-Grip
    row.grip = CreateFrame("Button", nil, row)
    row.grip:SetWidth(GRIP_W); row.grip:SetHeight(ROW_HEIGHT)
    row.grip:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.grip:SetFrameLevel(row:GetFrameLevel() + 1)
    row.grip:RegisterForDrag("LeftButton")
    local gripLabel = row.grip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gripLabel:SetAllPoints(); gripLabel:SetJustifyH("CENTER")
    gripLabel:SetText("|cff555555= =|r")
    row.grip:SetScript("OnEnter", function() gripLabel:SetText("|cffaaaaaa= =|r") end)
    row.grip:SetScript("OnLeave", function() gripLabel:SetText("|cff555555= =|r") end)
    row.grip:SetScript("OnDragStart", function()
      if not row.entry then return end
      dragEntry = row.entry
      ghostText:SetText(dragEntry.uitext or dragEntry.name or "?")
      dragGhost:Show()
      mouseCatcher:Show()
      dropTargetRow = nil
    end)

    -- Checkbox
    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetWidth(16); row.check:SetHeight(16)
    row.check:SetPoint("LEFT", row.grip, "RIGHT", 4, 0)
    row.check:SetFrameLevel(row:GetFrameLevel() + 1)

    -- Name/Typ
    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.nameText:SetPoint("LEFT", row.check, "RIGHT", GAP, 0)
    row.nameText:SetWidth(NAME_W)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetNonSpaceWrap(false)

    -- Refresh EditBox (nur bei curse sichtbar)
    row.refreshBox = CreateFrame("EditBox", nil, row)
    row.refreshBox:SetAutoFocus(false)
    row.refreshBox:SetWidth(REF_W); row.refreshBox:SetHeight(18)
    row.refreshBox:SetPoint("LEFT", row.nameText, "RIGHT", GAP, 0)
    row.refreshBox:SetFontObject(GameFontHighlightSmall)
    row.refreshBox:SetJustifyH("LEFT")
    row.refreshBox:SetTextInsets(4, 0, 0, 0)
    row.refreshBox:SetBackdrop({
      bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    row.refreshBox:SetBackdropColor(0, 0, 0, 0.6)
    row.refreshBox:SetScript("OnTextChanged", function()
      local txt = this:GetText() or ""
      local clean = SanitizeNumberText(txt)
      if clean ~= txt then this:SetText(clean) end
    end)
    row.refreshBox:SetScript("OnEnterPressed",  function() this:ClearFocus() end)
    row.refreshBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)

    -- Conditions-Button
    row.cond = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.cond:SetText("Cond")
    row.cond:SetWidth(COND_W); row.cond:SetHeight(18)
    row.cond:SetPoint("LEFT", row.refreshBox, "RIGHT", GAP, 0)
    row.cond:SetFrameLevel(row:GetFrameLevel() + 1)
    row.cond:SetScript("OnClick", function()
      ShowCondFrameForEntry(row.entry, row)
    end)

    -- Cfg-Button (nur für Spells mit per-spell Config, z.B. Dark Harvest)
    row.cfgBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.cfgBtn:SetText("Cfg")
    row.cfgBtn:SetWidth(CFG_W); row.cfgBtn:SetHeight(18)
    row.cfgBtn:SetPoint("LEFT", row.cond, "RIGHT", GAP, 0)
    row.cfgBtn:SetFrameLevel(row:GetFrameLevel() + 1)
    row.cfgBtn:SetScript("OnClick", function()
      if not row.entry then return end
      if row.entry.name == "Dark Harvest" then
        ShowDHDotsPopup(row.cfgBtn)
      elseif row.entry.name == "Drain Soul" then
        ShowDSDotsPopup(row.cfgBtn)
      end
    end)
    row.cfgBtn:SetScript("OnEnter", function()
      if not row.entry then return end
      if row.entry.name == "Dark Harvest" then
        ShowTooltip(this, "Dark Harvest – DoT Requirements",
          "Check which DoTs must be active\non the target before Dark Harvest\ncan be cast.")
      elseif row.entry.name == "Drain Soul" then
        ShowTooltip(this, "Drain Soul – Curse Renewal",
          "Check which curses are allowed\nto be renewed while Drain Soul\nis channeling.")
      end
    end)
    row.cfgBtn:SetScript("OnLeave", function()
      AL_TT:Hide()
    end)
    row.cfgBtn:Hide()

    -- Delete-Button
    row.delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.delBtn:SetText("X")
    row.delBtn:SetWidth(DEL_W); row.delBtn:SetHeight(18)
    row.delBtn:SetPoint("LEFT", row.cfgBtn, "RIGHT", GAP, 0)
    row.delBtn:SetFrameLevel(row:GetFrameLevel() + 1)
    row.delBtn:SetScript("OnClick", function()
      if not row.entry then return end
      local e = row.entry
      local cfg = GetActiveConfig()
      if cfg then
        if not cfg.deletedSpells then cfg.deletedSpells = {} end
        cfg.deletedSpells[GetSpellKey(e)] = true
      end
      e._deleted = true
      SaveCurrentConfigSpells()
      AutoLock:PrioScrollUpdate()
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
  frame:SetHeight((ROW_HEIGHT+ROW_SPACING)*VISIBLE_ROWS + 163)
  frame:ClearAllPoints()
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  frame:SetFrameStrata("DIALOG")

  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function()
    -- Don't move the frame when the drag started on a config button.
    if not AutoLock._configDragging then this:StartMoving() end
  end)
  frame:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)

  frame:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
  })
  frame:SetBackdropColor(0,0,0,0.85)

  tinsert(UISpecialFrames, "AutoLockFrame")

  frame:SetScript("OnShow", function()
    -- Restore SPELL_PRIORITY from the previewed config.
    -- _reloadActiveCombatConfig() (called on close) replaces SPELL_PRIORITY with the
    -- active combat config; without this restore, PrioScrollUpdate → SaveCurrentConfigSpells
    -- would overwrite the previewed config's saved spells with the combat config's values.
    local name = AutoLock._loadedConfigName
    if name and AutoLockDB and AutoLockDB.configs then
      for _, cfg in ipairs(AutoLockDB.configs) do
        if cfg.name == name then
          ApplyConfigToSpells(cfg)  -- restores SPELL_PRIORITY; keeps _loadedConfigName = name
          break
        end
      end
    end
  end)

  frame:SetScript("OnHide", function()
    -- ESC-Priorität: offene Spell-Popups zuerst schließen
    if dhDotsPopup and dhDotsPopup:IsShown() then
      frame:Show()
      dhDotsPopup:Hide()
      return
    end
    if dsDotsPopup and dsDotsPopup:IsShown() then
      frame:Show()
      dsDotsPopup:Hide()
      return
    end
    -- SPELL_PRIORITY könnte durch UI-Vorschau abweichen → Combat-Config wiederherstellen
    if AutoLock._reloadActiveCombatConfig then
      AutoLock:_reloadActiveCombatConfig()
    end
  end)

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

  -- Search box (same row as filterCheck)
  local searchLbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  searchLbl:SetPoint("LEFT", filterCheck.text, "RIGHT", 14, 0)
  searchLbl:SetText("Search:")

  local searchBox = CreateFrame("EditBox", "AutoLockSearchBox", frame)
  searchBox:SetWidth(140); searchBox:SetHeight(18)
  searchBox:SetPoint("LEFT", searchLbl, "RIGHT", 4, 0)
  searchBox:SetAutoFocus(false)
  searchBox:SetFontObject(GameFontHighlightSmall)
  searchBox:SetJustifyH("LEFT")
  searchBox:SetTextInsets(4, 0, 0, 0)
  searchBox:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
  })
  searchBox:SetBackdropColor(0, 0, 0, 0.6)
  searchBox:SetScript("OnTextChanged", function()
    AutoLockSearchText = strlower(this:GetText() or "")
    if scroll then FauxScrollFrame_SetOffset(scroll, 0) end
    AutoLock:PrioScrollUpdate()
  end)
  searchBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)

  local srchClear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  srchClear:SetWidth(22); srchClear:SetHeight(18)
  srchClear:SetPoint("LEFT", searchBox, "RIGHT", 2, 0)
  srchClear:SetText("X")
  srchClear:SetScript("OnClick", function()
    searchBox:SetText("")
    AutoLockSearchText = ""
    if scroll then FauxScrollFrame_SetOffset(scroll, 0) end
    AutoLock:PrioScrollUpdate()
  end)

  -- Type filter buttons
  local typeLabels = {"All", "Cast", "Curse", "Pet", "Trnkt"}
  local typeValues = {"all", "cast", "curse", "pet", "trinket"}
  local typeWidths = {34, 40, 44, 34, 42}
  local lastFBtn = srchClear
  for fi = 1, 5 do
    local fb = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    fb:SetWidth(typeWidths[fi]); fb:SetHeight(18)
    fb:SetText(typeLabels[fi])
    fb:SetPoint("LEFT", lastFBtn, "RIGHT", 4, 0)
    local ftype = typeValues[fi]
    fb:SetScript("OnClick", function()
      AutoLockTypeFilter = ftype
      if scroll then FauxScrollFrame_SetOffset(scroll, 0) end
      AutoLock:PrioScrollUpdate()
    end)
    lastFBtn = fb
  end

  local newCofig = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  newCofig:SetWidth(90); newCofig:SetHeight(20)
  newCofig:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 10)
  newCofig:SetText("New Config")
  newCofig:SetScript("OnClick", function() AutoLockNewConfigFrame:Show() end)

  -- ===== Settings button =====
  local settingsBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  settingsBtn:SetWidth(90); settingsBtn:SetHeight(20)
  settingsBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 120, 10)
  settingsBtn:SetText("Settings")
  settingsBtn:SetScript("OnClick", function()
    if settingsPanel and settingsPanel:IsShown() then
      settingsPanel:Hide()
    elseif settingsPanel then
      settingsPanel:Show()
    end
  end)

  -- ===== Add Spell button =====
  local addSpellBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  addSpellBtn:SetWidth(80); addSpellBtn:SetHeight(20)
  addSpellBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 230, 10)
  addSpellBtn:SetText("Add Spell")
  addSpellBtn:SetScript("OnClick", function() AutoLock:ShowSpellPicker() end)

  -- ===== Settings panel =====
  settingsPanel = CreateFrame("Frame", "AutoLockSettingsPanel", frame)
  settingsPanel:SetWidth(360)
  settingsPanel:SetHeight(244)
  settingsPanel:SetFrameStrata("DIALOG")
  settingsPanel:SetFrameLevel(50)
  settingsPanel:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 16,
    insets = { left = 5, right = 5, top = 5, bottom = 5 }
  })
  settingsPanel:SetBackdropColor(0.1, 0.1, 0.15, 1)
  settingsPanel:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 230, 34)
  settingsPanel:EnableMouse(true)
  settingsPanel:SetMovable(true)
  settingsPanel:RegisterForDrag("LeftButton")
  settingsPanel:SetScript("OnDragStart", function() this:StartMoving() end)
  settingsPanel:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)
  settingsPanel:Hide()

  local spTitle = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  spTitle:SetPoint("TOP", settingsPanel, "TOP", 0, -10)
  spTitle:SetText("Settings")

  local spClose = CreateFrame("Button", nil, settingsPanel, "UIPanelCloseButton")
  spClose:SetPoint("TOPRIGHT", settingsPanel, "TOPRIGHT", -4, -4)
  spClose:SetScript("OnClick", function() settingsPanel:Hide() end)

  -- Checkbox: auto-delete soul shards
  local shardCheck = CreateFrame("CheckButton", "AutoLockSettingsShardsCheck", settingsPanel, "UICheckButtonTemplate")
  shardCheck:SetWidth(20); shardCheck:SetHeight(20)
  shardCheck:SetPoint("TOPLEFT", settingsPanel, "TOPLEFT", 14, -38)
  shardCheck:SetScript("OnClick", function()
    AutoLockDB.settings.autoDeleteShards = (this:GetChecked() and true) or false
  end)
  shardCheck:SetScript("OnEnter", function()
    ShowTooltip(this, "Auto-delete Soul Shards",
      "Automatically deletes Soul Shards from\nnon-soul bags when your Soul Bag is full.")
  end)
  shardCheck:SetScript("OnLeave", function() AL_TT:Hide() end)
  local shardLbl = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  shardLbl:SetPoint("LEFT", shardCheck, "RIGHT", 4, 0)
  shardLbl:SetWidth(310)
  shardLbl:SetJustifyH("LEFT")
  shardLbl:SetText("Auto-delete Soul Shards when Soul Bag is full")

  -- Checkbox: use life tap
  local lifeTapCheck = CreateFrame("CheckButton", "AutoLockSettingsLifeTapCheck", settingsPanel, "UICheckButtonTemplate")
  lifeTapCheck:SetWidth(20); lifeTapCheck:SetHeight(20)
  lifeTapCheck:SetPoint("TOPLEFT", shardCheck, "BOTTOMLEFT", 0, -14)
  lifeTapCheck:SetScript("OnClick", function()
    AutoLockDB.settings.useLifeTap = (this:GetChecked() and true) or false
  end)
  lifeTapCheck:SetScript("OnEnter", function()
    ShowTooltip(this, "Use Life Tap",
      "Automatically casts Life Tap before a\nspell when mana is insufficient.\nStops if health is too low.")
  end)
  lifeTapCheck:SetScript("OnLeave", function() AL_TT:Hide() end)
  local lifeTapLbl = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  lifeTapLbl:SetPoint("LEFT", lifeTapCheck, "RIGHT", 4, 0)
  lifeTapLbl:SetWidth(310)
  lifeTapLbl:SetJustifyH("LEFT")
  lifeTapLbl:SetText("Use Life Tap when low on mana")

  -- Checkbox: hide spells not in spellbook
  local hideUnknownCheck = CreateFrame("CheckButton", "AutoLockSettingsHideUnknownCheck", settingsPanel, "UICheckButtonTemplate")
  hideUnknownCheck:SetWidth(20); hideUnknownCheck:SetHeight(20)
  hideUnknownCheck:SetPoint("TOPLEFT", lifeTapCheck, "BOTTOMLEFT", 0, -14)
  hideUnknownCheck:SetScript("OnClick", function()
    AutoLockDB.settings.hideUnknownSpells = (this:GetChecked() and true) or false
    AutoLock:PrioScrollUpdate()
  end)
  hideUnknownCheck:SetScript("OnEnter", function()
    ShowTooltip(this, "Hide unknown spells",
      "Hides spells in the list that are not\nin your current spellbook\n(e.g. not yet learned).")
  end)
  hideUnknownCheck:SetScript("OnLeave", function() AL_TT:Hide() end)
  local hideUnknownLbl = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hideUnknownLbl:SetPoint("LEFT", hideUnknownCheck, "RIGHT", 4, 0)
  hideUnknownLbl:SetWidth(310)
  hideUnknownLbl:SetJustifyH("LEFT")
  hideUnknownLbl:SetText("Hide spells not in my spellbook")

  -- Version label
  local spVersion = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  spVersion:SetPoint("BOTTOM", settingsPanel, "BOTTOM", 0, 52)
  spVersion:SetText("AutoLock v" .. (GetAddOnMetadata and GetAddOnMetadata("AutoLock", "Version") or "?"))

  -- Buy me a coffee button
  -- Update the URL below with your PayPal.me link.
  local PAYPAL_URL = "https://paypal.me/TWoWCoffee"
  local coffeeBtn = CreateFrame("Button", nil, settingsPanel, "UIPanelButtonTemplate")
  coffeeBtn:SetWidth(220); coffeeBtn:SetHeight(22)
  coffeeBtn:SetPoint("BOTTOM", settingsPanel, "BOTTOM", 0, 18)
  coffeeBtn:SetText("Buy me a Coffee - PayPal")
  coffeeBtn:SetScript("OnClick", function()
    AutoLockLog.Info("Support AutoLock - PayPal link:")
    AutoLockLog.Info(PAYPAL_URL)
  end)
  coffeeBtn:SetScript("OnEnter", function()
    AL_TT:SetOwner(this, "ANCHOR_TOP")
    AL_TT:ClearLines(); AL_TT:AddLine("Buy me a Coffee", 1, 0.82, 0)
    AL_TT:AddLine("Click to print the PayPal link to chat.", 0.9, 0.9, 0.9)
    AL_TT:AddLine(PAYPAL_URL, 0.5, 0.8, 1)
    AL_TT:Show()
  end)
  coffeeBtn:SetScript("OnLeave", function() AL_TT:Hide() end)

  -- Sync checkbox states when the panel opens
  settingsPanel:SetScript("OnShow", function()
    shardCheck:SetChecked(AutoLockDB.settings.autoDeleteShards ~= false and 1 or nil)
    lifeTapCheck:SetChecked(AutoLockDB.settings.useLifeTap ~= false and 1 or nil)
    hideUnknownCheck:SetChecked(AutoLockDB.settings.hideUnknownSpells and 1 or nil)
  end)

  local ok, err = pcall(CreatePrioUIOnce, frame)
  if not ok then
    AutoLockLog.Error("CreatePrioUIOnce failed: " .. tostring(err))
  end
  AutoLock:PrioScrollUpdate()

  frame:Hide()
end

function AutoLock:ShowUI()
  self:CreateUI()
  self:BuildKnownSpellSet()
  frame:Show()
  self:PrioScrollUpdate()
  AutoLockRefreshConfigList()
end
function AutoLock:HideUI()   if frame then frame:Hide() end end
function AutoLock:ToggleUI()
  self:CreateUI()
  if frame:IsShown() then
    frame:Hide()
  else
    self:BuildKnownSpellSet()
    frame:Show()
    self:PrioScrollUpdate()
    AutoLockRefreshConfigList()
  end
end

-- =========================
-- Spell Picker
-- =========================
local spellPickerFrame    = nil
local spellPickerList     = {}
local spellPickerSelected = nil
local spellPickerSearchText = ""
local spellPickerTabFilter  = 0
local pickerRows   = {}
local pickerScroll = nil

local PICKER_ROW_H   = 20
local PICKER_VISIBLE = 18
local PICKER_ROW_GAP = 2

local PICKER_SKIP_TABS = {["general"]=true, ["zmounts"]=true, ["zzcompanions"]=true, ["zzzztoys"]=true}

local PICKER_MISC_TAB = -1
local PICKER_MISC_ENTRIES = {
  {
    name="Trinket Slot 1", uitext="Trinket Slot 1", type="trinket",
    tab=PICKER_MISC_TAB, tabName="Misc", target="target", enabled=false,
    use=function() UseInventoryItem(13); return true end,
    condition=function() return AutoLock:IsTrinketReady(13) and UnitExists("target") end,
  },
  {
    name="Trinket Slot 2", uitext="Trinket Slot 2", type="trinket",
    tab=PICKER_MISC_TAB, tabName="Misc", target="target", enabled=false,
    use=function() UseInventoryItem(14); return true end,
    condition=function() return AutoLock:IsTrinketReady(14) and UnitExists("target") end,
  },
  {
    name="Firebolt", uitext="Firebolt (Pet)", type="pet",
    tab=PICKER_MISC_TAB, tabName="Misc", target="target", enabled=true,
  },
}

local function BuildSpellPickerList()
  spellPickerList = {}
  local numTabs = GetNumSpellTabs and GetNumSpellTabs() or 0
  for tab = 1, numTabs do
    local tabName, _, offset, numSpells = GetSpellTabInfo(tab)
    if not PICKER_SKIP_TABS[strlower(tabName or "")] then
      for s = offset + 1, offset + numSpells do
        local name, rank = GetSpellName(s, BOOKTYPE_SPELL)
        if name then
          table.insert(spellPickerList, {name=name, rank=rank, tab=tab, tabName=tabName or ""})
        end
      end
    end
  end
  for _, e in ipairs(PICKER_MISC_ENTRIES) do
    table.insert(spellPickerList, e)
  end
end

local function PickerGetFiltered()
  local filtered = {}
  local search = strlower(spellPickerSearchText or "")
  for _, e in ipairs(spellPickerList) do
    local passTab    = (spellPickerTabFilter == 0) or (e.tab == spellPickerTabFilter)
    local passSearch = (search == "") or strfind(strlower(e.name), search, 1)
    if passTab and passSearch then
      table.insert(filtered, e)
    end
  end
  return filtered
end

local function PickerScrollUpdate()
  if not pickerScroll then return end
  local filtered = PickerGetFiltered()
  local total    = table.getn(filtered)
  local offset   = FauxScrollFrame_GetOffset(pickerScroll)
  local maxOff   = math.max(total - PICKER_VISIBLE, 0)
  if offset > maxOff then
    offset = maxOff
    FauxScrollFrame_SetOffset(pickerScroll, offset)
  end
  FauxScrollFrame_Update(pickerScroll, total, PICKER_VISIBLE, PICKER_ROW_H + PICKER_ROW_GAP)
  for i = 1, PICKER_VISIBLE do
    local row = pickerRows[i]
    if not row then break end
    local idx = offset + i
    if idx >= 1 and idx <= total then
      local e = filtered[idx]
      row:Show()
      local rankStr = (e.rank and e.rank ~= "") and (" (" .. e.rank .. ")") or ""
      row.nameText:SetText(e.name .. rankStr)
      row.entry = e
      if e == spellPickerSelected then
        row.nameText:SetTextColor(1, 0.82, 0)
      else
        row.nameText:SetTextColor(0.9, 0.9, 0.9)
      end
    else
      row:Hide()
      row.entry = nil
    end
  end
end

function AutoLock:ShowSpellPicker()
  if not spellPickerFrame then
    -- Build frame once
    spellPickerFrame = CreateFrame("Frame", "AutoLockSpellPicker", UIParent)
    spellPickerFrame:SetWidth(460); spellPickerFrame:SetHeight(540)
    spellPickerFrame:SetPoint("CENTER", UIParent, "CENTER", 80, 0)
    spellPickerFrame:SetFrameStrata("DIALOG")
    spellPickerFrame:SetFrameLevel(30)
    spellPickerFrame:SetBackdrop({
      bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    spellPickerFrame:SetBackdropColor(0.06, 0.06, 0.1, 1)
    spellPickerFrame:SetMovable(true)
    spellPickerFrame:EnableMouse(true)
    spellPickerFrame:RegisterForDrag("LeftButton")
    spellPickerFrame:SetScript("OnDragStart", function() this:StartMoving() end)
    spellPickerFrame:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)

    local title = spellPickerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", spellPickerFrame, "TOP", 0, -10)
    title:SetText("Add Spell from Spellbook")

    local closeBtn = CreateFrame("Button", nil, spellPickerFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", spellPickerFrame, "TOPRIGHT", -4, -4)

    -- Search box
    local srchBox = CreateFrame("EditBox", nil, spellPickerFrame)
    srchBox:SetAutoFocus(false)
    srchBox:SetWidth(190); srchBox:SetHeight(20)
    srchBox:SetPoint("TOPLEFT", spellPickerFrame, "TOPLEFT", 14, -34)
    srchBox:SetFontObject(GameFontHighlightSmall)
    srchBox:SetJustifyH("LEFT")
    srchBox:SetTextInsets(4, 0, 0, 0)
    srchBox:SetBackdrop({
      bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    srchBox:SetBackdropColor(0, 0, 0, 0.6)
    srchBox:SetScript("OnTextChanged", function()
      spellPickerSearchText = strlower(this:GetText() or "")
      if pickerScroll then FauxScrollFrame_SetOffset(pickerScroll, 0) end
      PickerScrollUpdate()
    end)
    srchBox:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    spellPickerFrame.srchBox = srchBox

    local srchClearBtn = CreateFrame("Button", nil, spellPickerFrame, "UIPanelButtonTemplate")
    srchClearBtn:SetWidth(22); srchClearBtn:SetHeight(18)
    srchClearBtn:SetPoint("LEFT", srchBox, "RIGHT", 2, 0)
    srchClearBtn:SetText("X")
    srchClearBtn:SetScript("OnClick", function()
      srchBox:SetText("")
      spellPickerSearchText = ""
      if pickerScroll then FauxScrollFrame_SetOffset(pickerScroll, 0) end
      PickerScrollUpdate()
    end)

    -- Tab button container (rebuilt on each open)
    spellPickerFrame.tabArea = CreateFrame("Frame", nil, spellPickerFrame)
    spellPickerFrame.tabArea:SetPoint("TOPLEFT",  spellPickerFrame, "TOPLEFT",  14, -60)
    spellPickerFrame.tabArea:SetPoint("TOPRIGHT", spellPickerFrame, "TOPRIGHT", -14, -60)
    spellPickerFrame.tabArea:SetHeight(20)
    spellPickerFrame._tabBtns = {}

    -- Scroll frame
    pickerScroll = CreateFrame("ScrollFrame", "AutoLockPickerScroll", spellPickerFrame, "FauxScrollFrameTemplate")
    pickerScroll:SetPoint("TOPLEFT",     spellPickerFrame, "TOPLEFT",   14, -88)
    pickerScroll:SetPoint("BOTTOMRIGHT", spellPickerFrame, "BOTTOMRIGHT", -14, 60)
    pickerScroll:EnableMouse(false)
    pickerScroll:EnableMouseWheel(true)
    pickerScroll:SetScript("OnVerticalScroll", function()
      FauxScrollFrame_OnVerticalScroll(arg1, PICKER_ROW_H + PICKER_ROW_GAP, function()
        PickerScrollUpdate()
      end)
    end)
    pickerScroll:SetScript("OnMouseWheel", function()
      local delta  = arg1 or 0
      local total  = table.getn(PickerGetFiltered())
      local off    = FauxScrollFrame_GetOffset(pickerScroll) - delta
      local maxOff = math.max(total - PICKER_VISIBLE, 0)
      if off < 0 then off = 0 end
      if off > maxOff then off = maxOff end
      FauxScrollFrame_SetOffset(pickerScroll, off)
      PickerScrollUpdate()
    end)

    -- Spell rows
    pickerRows = {}
    for i = 1, PICKER_VISIBLE do
      local row = CreateFrame("Button", nil, spellPickerFrame)
      row:SetHeight(PICKER_ROW_H)
      row:SetPoint("LEFT",  spellPickerFrame, "LEFT",  14, 0)
      row:SetPoint("RIGHT", spellPickerFrame, "RIGHT", -30, 0)
      if i == 1 then
        row:SetPoint("TOP", spellPickerFrame, "TOP", 0, -90)
      else
        row:SetPoint("TOP", pickerRows[i-1], "BOTTOM", 0, -PICKER_ROW_GAP)
      end
      row:SetFrameLevel(spellPickerFrame:GetFrameLevel() + 2)
      row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
      row:GetHighlightTexture():SetBlendMode("ADD")
      row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      row.nameText:SetPoint("LEFT",  row, "LEFT",  4, 0)
      row.nameText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
      row.nameText:SetJustifyH("LEFT")
      row.nameText:SetTextColor(0.9, 0.9, 0.9)
      row:SetScript("OnClick", function()
        spellPickerSelected = row.entry
        PickerScrollUpdate()
      end)
      pickerRows[i] = row
    end

    -- Type selector
    local typeLbl = spellPickerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    typeLbl:SetPoint("BOTTOMLEFT", spellPickerFrame, "BOTTOMLEFT", 14, 34)
    typeLbl:SetText("Type:")
    spellPickerFrame.typeSelected = "cast"
    local typeOpts    = {"cast",  "curse"}
    local typeLabels2 = {"Cast",  "Curse"}
    local lastTBtn = typeLbl
    for ti = 1, 2 do
      local tb = CreateFrame("Button", nil, spellPickerFrame, "UIPanelButtonTemplate")
      tb:SetWidth(46); tb:SetHeight(18)
      tb:SetText(typeLabels2[ti])
      tb:SetPoint("LEFT", lastTBtn, "RIGHT", 4, 0)
      local ttype = typeOpts[ti]
      tb:SetScript("OnClick", function() spellPickerFrame.typeSelected = ttype end)
      lastTBtn = tb
    end

    -- Add to List button
    local addBtn = CreateFrame("Button", nil, spellPickerFrame, "UIPanelButtonTemplate")
    addBtn:SetWidth(100); addBtn:SetHeight(20)
    addBtn:SetPoint("BOTTOMRIGHT", spellPickerFrame, "BOTTOMRIGHT", -14, 14)
    addBtn:SetText("Add to List")
    addBtn:SetScript("OnClick", function()
      if not spellPickerSelected then
        AutoLockLog.Warning("Select a spell first.")
        return
      end
      local newEntry
      if spellPickerSelected.tab == PICKER_MISC_TAB then
        local sel = spellPickerSelected
        local displayName = sel.uitext or sel.name
        for _, e in ipairs(SPELL_PRIORITY) do
          if e.name == sel.name and e.type == sel.type then
            if e._deleted then
              e._deleted = nil
              local cfg = GetActiveConfig()
              if cfg and cfg.deletedSpells then cfg.deletedSpells[GetSpellKey(e)] = nil end
              SaveCurrentConfigSpells()
              AutoLock:PrioScrollUpdate()
              AutoLockLog.Info(displayName .. " restored to rotation.")
            else
              AutoLockLog.Warning(displayName .. " is already in the rotation.")
            end
            return
          end
        end
        newEntry = {
          name      = sel.name,
          uitext    = sel.uitext,
          type      = sel.type,
          target    = sel.target or "target",
          enabled   = true,
          priority  = table.getn(SPELL_PRIORITY) + 1,
          use       = sel.use,
          condition = sel.condition,
        }
      else
        local spellName = spellPickerSelected.name
        local spellType = spellPickerFrame.typeSelected
        for _, e in ipairs(SPELL_PRIORITY) do
          if e.name == spellName and e.type == spellType then
            if e._deleted then
              e._deleted = nil
              local cfg = GetActiveConfig()
              if cfg and cfg.deletedSpells then cfg.deletedSpells[GetSpellKey(e)] = nil end
              SaveCurrentConfigSpells()
              AutoLock:PrioScrollUpdate()
              AutoLockLog.Info(spellName .. " restored to rotation.")
            else
              AutoLockLog.Warning(spellName .. " (" .. spellType .. ") is already in the rotation. Check 'Show disabled' in the main list to find it.")
            end
            return
          end
        end
        newEntry = {
          name     = spellName,
          type     = spellType,
          priority = table.getn(SPELL_PRIORITY) + 1,
          target   = "target",
          enabled  = true,
          uitext   = spellName,
        }
      end
      table.insert(SPELL_PRIORITY, newEntry)
      local cfg = GetActiveConfig()
      if cfg and cfg.deletedSpells then
        cfg.deletedSpells[GetSpellKey(newEntry)] = nil
      end
      RenumberPriorities()
      SaveCurrentConfigSpells()
      AutoLock:PrioScrollUpdate()
      AutoLockLog.Info("Added " .. (newEntry.uitext or newEntry.name) .. " (" .. newEntry.type .. ") to rotation. Total: " .. table.getn(SPELL_PRIORITY))
    end)
  end  -- end one-time frame creation

  -- Rebuild spell list and tab buttons every open (spells may change)
  BuildSpellPickerList()
  for _, b in ipairs(spellPickerFrame._tabBtns) do b:Hide() end
  spellPickerFrame._tabBtns = {}

  local tabX = 0
  local allTabBtn = CreateFrame("Button", nil, spellPickerFrame.tabArea, "UIPanelButtonTemplate")
  allTabBtn:SetWidth(36); allTabBtn:SetHeight(18)
  allTabBtn:SetPoint("TOPLEFT", spellPickerFrame.tabArea, "TOPLEFT", tabX, 0)
  allTabBtn:SetText("All")
  allTabBtn:SetScript("OnClick", function()
    spellPickerTabFilter = 0
    if pickerScroll then FauxScrollFrame_SetOffset(pickerScroll, 0) end
    PickerScrollUpdate()
  end)
  table.insert(spellPickerFrame._tabBtns, allTabBtn)
  tabX = tabX + 40

  local numTabs = GetNumSpellTabs and GetNumSpellTabs() or 0
  for tab = 1, numTabs do
    local tabName = GetSpellTabInfo(tab)
    if not PICKER_SKIP_TABS[strlower(tabName or "")] then
      local shortName = tabName and string.sub(tabName, 1, 9) or ("Tab" .. tab)
      local tbW = math.max(50, string.len(shortName) * 7 + 14)
      local tb = CreateFrame("Button", nil, spellPickerFrame.tabArea, "UIPanelButtonTemplate")
      tb:SetWidth(tbW); tb:SetHeight(18)
      tb:SetText(shortName)
      tb:SetPoint("TOPLEFT", spellPickerFrame.tabArea, "TOPLEFT", tabX, 0)
      local tabIdx = tab
      tb:SetScript("OnClick", function()
        spellPickerTabFilter = tabIdx
        if pickerScroll then FauxScrollFrame_SetOffset(pickerScroll, 0) end
        PickerScrollUpdate()
      end)
      table.insert(spellPickerFrame._tabBtns, tb)
      tabX = tabX + tbW + 4
    end
  end

  local miscBtn = CreateFrame("Button", nil, spellPickerFrame.tabArea, "UIPanelButtonTemplate")
  miscBtn:SetWidth(50); miscBtn:SetHeight(18)
  miscBtn:SetText("Misc")
  miscBtn:SetPoint("TOPLEFT", spellPickerFrame.tabArea, "TOPLEFT", tabX, 0)
  miscBtn:SetScript("OnClick", function()
    spellPickerTabFilter = PICKER_MISC_TAB
    if pickerScroll then FauxScrollFrame_SetOffset(pickerScroll, 0) end
    PickerScrollUpdate()
  end)
  table.insert(spellPickerFrame._tabBtns, miscBtn)

  -- Reset state
  if spellPickerFrame.srchBox then spellPickerFrame.srchBox:SetText("") end
  spellPickerSearchText = ""
  spellPickerTabFilter  = 0
  spellPickerSelected   = nil
  if pickerScroll then FauxScrollFrame_SetOffset(pickerScroll, 0) end
  PickerScrollUpdate()
  spellPickerFrame:Show()
end

-- =========================
-- Minimap-Button (ohne GetCursorPosition)
-- =========================
function AutoLock:CreateMinimapButton()
  if miniBtn then
    -- Button already exists; update anchor to saved position now that VARIABLES_LOADED has run.
    if AutoLockDB and AutoLockDB.minimap then
      miniBtn:ClearAllPoints()
      miniBtn:SetPoint("CENTER", Minimap, "CENTER", AutoLockDB.minimap.x or 0, AutoLockDB.minimap.y or 0)
    end
    return
  end

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
    AL_TT:SetOwner(this, "ANCHOR_LEFT")
    AL_TT:ClearLines(); AL_TT:AddLine("AutoLock", 1, 1, 1)
    AL_TT:AddLine("Click: Open spell priority UI", .9, .9, .9)
    AL_TT:AddLine("Drag: Reposition button", .9, .9, .9)
    AL_TT:Show()
  end)
  miniBtn:SetScript("OnLeave", function() AL_TT:Hide() end)

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
-- Drag-visual: floating icon frame that follows the cursor so the user
-- clearly sees what is being dragged (WoW 1.12 only changes the cursor
-- icon subtly; a floating frame is far more visible).
-- =========================
local _dragFrame, _dragTex, _draggingActive = nil, nil, false

local function AL_CreateDragFrame()
  if _dragFrame then return end
  _dragFrame = CreateFrame("Frame", "AutoLockDragFrame", UIParent)
  _dragFrame:SetWidth(36); _dragFrame:SetHeight(36)
  _dragFrame:SetFrameStrata("TOOLTIP")
  _dragFrame:EnableMouse(false)
  _dragTex = _dragFrame:CreateTexture(nil, "ARTWORK")
  _dragTex:SetAllPoints(_dragFrame)
  _dragFrame:SetScript("OnUpdate", function()
    if not _draggingActive then return end
    local cx, cy = GetCursorPosition()
    local s = UIParent:GetScale()
    _dragFrame:ClearAllPoints()
    _dragFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx / s, cy / s)
  end)
  _dragFrame:Hide()
end

local function AL_ShowDragIcon(tex)
  AL_CreateDragFrame()
  _dragTex:SetTexture(tex)
  _draggingActive = true
  local cx, cy = GetCursorPosition()
  local s = UIParent:GetScale()
  _dragFrame:ClearAllPoints()
  _dragFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx / s, cy / s)
  _dragFrame:Show()
end

local function AL_HideDragIcon()
  _draggingActive = false
  if _dragFrame then _dragFrame:Hide() end
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
  local macroBody  = '/run AutoLock:DoAutoLock("'..cfg.name..'")'
  local id = GetMacroIndexByName(macroName)
  if id and id > 0 then
    pcall(function() EditMacro(id, macroName, iconIndex, macroBody, 1) end)
  else
    local globalCount, charCount = GetNumMacros()
    if (globalCount or 0) >= 18 and (charCount or 0) >= 18 then
      AutoLockLog.Warning("No free macro slots.")
      return
    end
    local perChar = ((charCount or 0) < 18) and 1 or 0
    id = CreateMacro(macroName, iconIndex, macroBody, perChar)
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

    -- isUIShown: this config is currently displayed in the UI (for editing/viewing)
    local isUIShown = (AutoLock._loadedConfigName == cfg.name) or
                      (not AutoLock._loadedConfigName and AutoLockDB.activeConfig == cfg.name)
    -- isCombatActive: this config is bound to an action bar button and will be executed
    local isCombatActive = (AutoLock._combatConfigName == cfg.name)

    -- Gold border = UI-selected config
    local borderBg = btn:CreateTexture(nil, "BACKGROUND")
    borderBg:SetWidth(40); borderBg:SetHeight(40)
    borderBg:SetPoint("TOP", btn, "TOP", 0, -1)
    borderBg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    borderBg:SetVertexColor(1, 0.82, 0, 1)
    if not isUIShown then borderBg:Hide() end

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
    if isUIShown then
      iconTex:SetVertexColor(1, 1, 1)
    else
      iconTex:SetVertexColor(0.6, 0.6, 0.6)
    end

    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOP", iconTex, "BOTTOM", 0, -1)
    lbl:SetWidth(46); lbl:SetJustifyH("CENTER")
    local short = string.sub(cfg.name, 1, 6)
    if string.len(cfg.name) > 6 then short = short .. ".." end
    -- Green dot prefix = combat-active config (bound to action bar button)
    if isCombatActive then
      lbl:SetText("|cff00ff00\226\150\182|r" .. short)
    else
      lbl:SetText(short)
    end

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")

    local cfgRef = cfg

    btn:SetScript("OnEnter", function()
      AL_TT:SetOwner(this, "ANCHOR_RIGHT")
      AL_TT:ClearLines(); AL_TT:AddLine(cfgRef.name, 1, 0.82, 0)
      AL_TT:AddLine("Left-click: View in UI", 0.9, 0.9, 0.9)
      AL_TT:AddLine("Drag: Bind to action bar", 0.9, 0.9, 0.9)
      AL_TT:AddLine("Right-click: Edit", 0.9, 0.9, 0.9)
      AL_TT:AddLine("Shift + right-click: Delete", 0.9, 0.9, 0.9)
      if AutoLock._combatConfigName == cfgRef.name then
        AL_TT:AddLine("[Active combat config]", 0, 1, 0)
      end
      AL_TT:Show()
    end)
    btn:SetScript("OnLeave", function()
      AL_TT:Hide()
    end)

    -- Real WoW drag-and-drop: hold + move → OnDragStart → macro picked up
    -- → release over action bar slot → OnReceiveDrag → macro placed.
    -- Flag prevents parent AutoLockFrame's OnDragStart (StartMoving) firing.
    -- Floating drag frame gives visible feedback (cursor icon alone is subtle).
    local cfgIconTex = iconResult  -- captured per-button for the drag visual
    btn:SetScript("OnDragStart", function()
      AutoLock._configDragging = true
      AutoLockPickupConfigMacro(cfgRef)
      AL_ShowDragIcon(cfgIconTex)
    end)
    btn:SetScript("OnDragStop", function()
      AutoLock._configDragging = false
      AL_HideDragIcon()
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
          PreviewConfig(cfgRef)
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
      -- Combat-Config gelöscht → ersten verfügbaren laden
      if table.getn(AutoLockDB.configs) > 0 then
        LoadConfig(AutoLockDB.configs[1])
      else
        AutoLockDB.activeConfig = nil
        AutoLock._loadedConfigName = nil
        AutoLockRefreshConfigList()
      end
    elseif AutoLock._loadedConfigName == cfg.name then
      -- Vorgeschauter Config gelöscht → auf Combat-Config zurück
      AutoLock:LoadConfigByName(AutoLockDB.activeConfig)
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
    if AutoLock._loadedConfigName == AutoLockEditingConfig.name then
      AutoLock._loadedConfigName = name
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
    local newCfg = { name=name, icon=AutoLockSelectedIcon or 1, spells=SnapshotSpells(), drainSoulDots={ agony=true, corruption=true, siphonLife=true } }
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
  if not AutoLockDB.settings then AutoLockDB.settings = {} end
  if AutoLockDB.settings.autoDeleteShards  == nil then AutoLockDB.settings.autoDeleteShards  = true  end
  if AutoLockDB.settings.useLifeTap       == nil then AutoLockDB.settings.useLifeTap       = true  end
  if AutoLockDB.settings.hideUnknownSpells == nil then AutoLockDB.settings.hideUnknownSpells = false end
  if table.getn(AutoLockDB.configs) == 0 then
    -- Seed a "Default" config from the current SPELL_PRIORITY state.
    SortByPriorityNumbers()
    RenumberPriorities()
    table.insert(AutoLockDB.configs, { name="Default", icon=1, spells=SnapshotSpells(), drainSoulDots={ agony=true, corruption=true, siphonLife=true } })
    AutoLockDB.activeConfig = "Default"
  end
  local cfg = GetActiveConfig()
  if cfg then
    ApplyConfigToSpells(cfg)
    self:_loadCombatSnapshot(cfg.name)
  end
end

