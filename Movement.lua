-- ========= MovementEvents (Vanilla-kompatibel, fixe OnUpdate + Chat-Logs) =========
MovementEvents = MovementEvents or {}
do
  local listeners = { PLAYER_MOVING = {}, PLAYER_STOPPED = {} }

  local function Log(msg)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[Move]|r "..tostring(msg)) end
  end

  function MovementEvents:Register(eventName, fn)
    local list = listeners[eventName]
    if list then table.insert(list, fn) end
  end

  function MovementEvents:Unregister(eventName, fn)
    local list = listeners[eventName]; if not list then return end
    local n = table.getn(list)
    for i = 1, n do
      if list[i] == fn then table.remove(list, i); break end
    end
  end

  local function Fire(eventName, a1, a2, a3, a4)
    local list = listeners[eventName]; if not list then return end
    local n = table.getn(list); if n == 0 then return end
    for i = 1, n do
      local fn = list[i]
      if fn then
        local ok, err = pcall(function() return fn(a1, a2, a3, a4) end)
        if not ok and DEFAULT_CHAT_FRAME then
          DEFAULT_CHAT_FRAME:AddMessage("|cffff5555MovementEvents error:|r "..tostring(err))
        end
      end
    end
  end

  -- Polling über Map-Position
  local f = CreateFrame("Frame")
  local lastX, lastY, lastMoveAt
  local lastTick = 0
  local TICK = 0.10
  local EPS = 0.00005
  local STOP_GRACE = 0.10
  local moving = false

  local function EnsureMap()
    if SetMapToCurrentZone then SetMapToCurrentZone() end
  end

  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:RegisterEvent("ZONE_CHANGED")
  f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  f:RegisterEvent("ZONE_CHANGED_INDOORS")
  f:SetScript("OnEvent", function()
    EnsureMap()
    local x, y = GetPlayerMapPosition("player")
    lastX, lastY = x, y
    lastTick = GetTime()
    -- Log("init pos "..tostring(x)..","..tostring(y))
  end)

  f:SetScript("OnUpdate", function()
    local now = GetTime()
    if now - lastTick < TICK then return end
    lastTick = now

    local x, y = GetPlayerMapPosition("player")
    if not x or not y then EnsureMap(); return end
    -- Log("check pos") -- zum Testen einkommentieren
	
    if lastX and lastY then
      local dx, dy = x - lastX, y - lastY
      local moved = (dx*dx + dy*dy) > (EPS*EPS)
	  -- print(moved)

      if moved then
        lastMoveAt = now
        if not moving then
          moving = true
          Fire("PLAYER_MOVING")
          -- Log("moving")
					-- print("moving")
        end
      else
        if moving and lastMoveAt and (now - lastMoveAt) > STOP_GRACE then
          moving = false
          Fire("PLAYER_STOPPED")
          -- Log("stopped")
					-- print("stopped")
        end
      end
    end

    lastX, lastY = x, y
  end)

  function MovementEvents:IsMoving()
    --if moving then
    --  print("is_moving: true")
    --else
    --  print("is_moving: false")
    --end
    return moving
  end
  MovementEvents._Fire = Fire
end

-- Beispiel-Nutzung:
-- function hello()
--   if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffhello() aufgerufen|r") end
-- 
--   MovementEvents:Register("PLAYER_MOVING", function()
--     if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("moving") end
--   end)
-- 
--   MovementEvents:Register("PLAYER_STOPPED", function()
--     if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("stopped") end
--   end)
-- 
--   -- einmaliger Statusdump:
--   if DEFAULT_CHAT_FRAME then
--     DEFAULT_CHAT_FRAME:AddMessage("IsMoving="..tostring(MovementEvents:IsMoving()))
--   end
-- end
-- /run hello()   -- nicht vergessen aufzurufen
