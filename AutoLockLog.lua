-- AutoLockLog.lua — centralised chat logging for AutoLock
--
-- Usage:
--   AutoLockLog.Info("message")
--   AutoLockLog.Warning("message")
--   AutoLockLog.Error("message")
--
-- Output format:  [AutoLock][Level]: message
--   [AutoLock]  warlock purple  #9482C9
--   [Info]      blue            #00aaff
--   [Warning]   yellow          #ffff00
--   [Error]     red             #ff3333

AutoLockLog = {}

local PREFIX = "|cff9482C9[AutoLock]|r"

local function emit(levelTag, msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. levelTag .. ": " .. tostring(msg))
  end
end

function AutoLockLog.Info(msg)
  emit("|cff00aaff[Info]|r", msg)
end

function AutoLockLog.Warning(msg)
  emit("|cffffff00[Warning]|r", msg)
end

function AutoLockLog.Error(msg)
  emit("|cffff3333[Error]|r", msg)
end
