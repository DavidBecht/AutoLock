local L = AceLibrary("AceLocale-2.2"):new("AutoLock")

AutoLock = AceLibrary("AceAddon-2.0"):new(
  "AceEvent-2.0",
  "AceDebug-2.0",
  "AceModuleCore-2.0",
  "AceConsole-2.0",
  "AceDB-2.0",
  "AceHook-2.1"
)

AutoLock.superwow = true

local function chat(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00AutoLock:|r "..tostring(msg))
  end
end

if not GetPlayerBuffID or not CombatLogAdd or not SpellInfo then
  local notify = CreateFrame("Frame", "AutoLockNoSuperwow", UIParent)
  notify:SetScript("OnUpdate", function()
    chat("Couldn't detect SuperWoW.")
    this:Hide()
  end)
  AutoLock.superwow = false
  if Cursive then Cursive.superwow = false end
end

function AutoLock:OnInitialize()
  self:RegisterDB("AutoLockDB")
end


function AutoLock:OnEnable()
  if not AutoLock.superwow then
    chat("SuperWoW not installed.")
    -- UI kann trotzdem geladen werden, nur Features ggf. reduziert:
    -- return  -- wenn du wirklich hart abbrechen willst
  end

  -- UI initialisieren (kommt aus autolock_ui.lua)
  AutoLock.ui.InitPrioUI()

  chat("Loaded. /autolock")
end

function AutoLock:OnDisable()
  chat("Disabled")
end

function handleSlashCommands(msg)
  msg = msg or ""
  local cmd, arg = string.match(msg, "^(%S+)%s*(.*)$")
  if cmd == "config" and arg and arg ~= "" then
    if not AutoLock:LoadConfigByName(arg) then
      DEFAULT_CHAT_FRAME:AddMessage("|cffff5555AutoLock:|r Config \"" .. arg .. "\" not found.")
    end
  else
    AutoLock.ui.ShowPrioUI()
  end
end

SLASH_AUTOLOCK = "/autolock" --creating the slash command
SlashCmdList["autolock"] = handleSlashCommands --associating the function with the slash command


