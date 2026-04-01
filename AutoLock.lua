local L = AceLibrary("AceLocale-2.2"):new("AutoLock")

AutoLock = AceLibrary("AceAddon-2.0"):new(
  "AceEvent-2.0",
  "AceConsole-2.0",
  "AceHook-2.1"
)

-- ===========================
-- Addon lifecycle
-- ===========================
function AutoLock:OnInitialize()
  self:RegisterChatCommand({ "/autolock" }, {
    handler = self,
    type    = "group",
    args    = {
      show = {
        name = "show", desc = "Show the UI", type = "execute",
        func = function() AutoLock:ShowUI() end,
      },
      hide = {
        name = "hide", desc = "Hide the UI", type = "execute",
        func = function() AutoLock:HideUI() end,
      },
      toggle = {
        name = "toggle", desc = "Toggle the UI", type = "execute",
        func = function() AutoLock:ToggleUI() end,
      },
      debug = {
        name = "debug", desc = "Print diagnostic info to chat", type = "execute",
        func = function()
          AutoLockLog.Info("=== AutoLock Debug ===")
          AutoLockLog.Info("SPELL_PRIORITY entries: " .. table.getn(SPELL_PRIORITY))

          local visibleCount, hiddenDisabled, hiddenUnknown = 0, 0, 0
          local ks = AutoLock.KnownSpells
          for _, e in ipairs(SPELL_PRIORITY) do
            if not AutoLockUI_ShowDisabled and e.enabled == false then
              hiddenDisabled = hiddenDisabled + 1
            else
              local passKnown = true
              local s = AutoLockDB and AutoLockDB.settings
              if s and s.hideUnknownSpells and ks and next(ks) ~= nil and not ks[e.name] then
                passKnown = false
                hiddenUnknown = hiddenUnknown + 1
              end
              if passKnown then visibleCount = visibleCount + 1 end
            end
          end
          AutoLockLog.Info("Visible: " .. visibleCount
            .. " | hidden disabled: " .. hiddenDisabled
            .. " | hidden unknown: "  .. hiddenUnknown)

          local ksCount = 0
          if AutoLock.KnownSpells then
            for _ in pairs(AutoLock.KnownSpells) do ksCount = ksCount + 1 end
          end
          AutoLockLog.Info("KnownSpells: " .. ksCount)

          local s = AutoLockDB and AutoLockDB.settings
          AutoLockLog.Info("hideUnknownSpells: " .. tostring(s and s.hideUnknownSpells))
          AutoLockLog.Info("ShowDisabled: "      .. tostring(AutoLockUI_ShowDisabled))
          AutoLockLog.Info("TypeFilter: "        .. tostring(AutoLockTypeFilter))
          AutoLockLog.Info("SearchText: '"       .. tostring(AutoLockSearchText) .. "'")
          AutoLockLog.Info("activeConfig: "      .. tostring(AutoLockDB and AutoLockDB.activeConfig))

          AutoLockLog.Info("First 5 SPELL_PRIORITY entries:")
          for i = 1, math.min(5, table.getn(SPELL_PRIORITY)) do
            local e = SPELL_PRIORITY[i]
            AutoLockLog.Info("  [" .. i .. "] prio=" .. tostring(e.priority)
              .. " name=" .. tostring(e.name) .. " enabled=" .. tostring(e.enabled))
          end
        end,
      },
    },
  })
end

function AutoLock:OnEnable()
  AutoLockLog.Info("Loaded. SPELL_PRIORITY has " .. table.getn(SPELL_PRIORITY)
    .. " entries. Use /autolock toggle")

  if GetLocale and GetLocale() ~= "enUS" then
    AutoLockLog.Warning("AutoLock uses English spell names. Non-English clients may have issues.")
  end
  if not GetPlayerBuffID or not SpellInfo then
    AutoLockLog.Warning("SuperWoW not detected. Buff-based features will not work.")
  end
  if not Cursive then
    AutoLockLog.Warning("Cursive not found. Curse spells will be skipped.")
  end
  if not GetCurrentCastingInfo then
    AutoLockLog.Warning("Nampower not detected. Spell queueing conflicts possible when spam-casting.")
  end

  self:InitUI()
  self:BuildKnownSpellSet()
end

-- Builds the set of spell names the player currently knows (spellbook + pet).
function AutoLock:BuildKnownSpellSet()
  local known = {}
  for i = 1, 1024 do
    local name = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    known[name] = true
  end
  if BOOKTYPE_PET then
    for i = 1, 200 do
      local name = GetSpellName(i, BOOKTYPE_PET)
      if not name then break end
      known[name] = true
    end
  end
  for i = 1, 10 do
    local name = GetPetActionInfo(i)
    if type(name) == "string" and name ~= "" then known[name] = true end
  end
  self.KnownSpells = known
end

-- ===========================
-- PLAYER_LOGIN — runs after UI and spellbook are ready.
-- ===========================
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function()
  AutoLock:OnLogin()
end)

function AutoLock:OnLogin()
  self.Scanner = CreateFrame("GameTooltip", "AutoLockScanner", UIParent, "GameTooltipTemplate")
  self.Scanner:SetOwner(UIParent, "ANCHOR_NONE")
  if self.BuildKnownSpellSet then self:BuildKnownSpellSet() end
  AutoLockLog.Info("Loaded.")
end

-- ===========================
-- Global spell lookup helpers
-- (used by AutoLockUI.lua and AutoLockSpellbook.lua)
-- ===========================
function SpellNameToId(buff)
  for i = 1, 1000 do
    local name, rank, id = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    if name == buff then
      local nextName = GetSpellName(i + 1, BOOKTYPE_SPELL)
      if nextName ~= buff then
        if id then return id end
        return i, rank
      end
    end
  end
end

function SpellIdToName(id)
  for i = 1, 1000 do
    local name, rank, spellId = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    if spellId == id then return name end
  end
end
