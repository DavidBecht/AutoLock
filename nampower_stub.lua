-- nampower_stub.lua
-- Simulates nampower's GetCurrentCastingInfo() / GetCastInfo() /
-- ChannelStopCastingNextTick() for offline testing via run_tests.lua.
--
-- Key findings from nampower source analysis:
--   GetCurrentCastingInfo() returns 7 values:
--     castingSpellId, visualSpellId, autoRepeatSpellId,
--     isCasting(4), isChanneling(5), pendingOnSwing, autoAttacking
--
--   GetCastInfo() returns NIL during GCD-only state (activeSpellId == 0).
--   This makes GCD-only after an instant cast UNDETECTABLE from Lua alone.
--
--   ChannelStopCastingNextTick() sets a flag that interrupts the channel
--   on nampower's next update tick (~ next frame).  Only works while
--   gCastData.channeling is true.
--
-- State machine:
--   IDLE        no cast, no GCD
--   GCD_ONLY    after instant cast; all zeros from GetCurrentCastingInfo;
--               GetCastInfo returns nil  ← the invisible state
--   CASTING     regular spell in flight; isCasting(4) = 1
--   CHANNELING  channel active;         isChanneling(5) = 1

local NP = {}

local GCD = 1.5   -- seconds; standard hasted GCD approximation

-- ── internal state ──────────────────────────────────────────────────────────

NP._state         = "IDLE"
NP._stateStart    = 0
NP._stateDuration = 0
NP._cancelFlag    = false   -- ChannelStopCastingNextTick pending

-- ── helpers ─────────────────────────────────────────────────────────────────

local function now() return GetTime() end

-- Advance state if the current phase has expired.
local function tick(np)
  if np._state == "IDLE" then return end
  local elapsed = now() - np._stateStart
  if elapsed >= np._stateDuration then
    np._state     = "IDLE"
    np._cancelFlag = false
  end
end

-- ── state transitions (call these from tests to drive the simulation) ───────

-- After an instant spell (e.g. a curse): 1.5 s GCD, no visible cast.
function NP:castInstant()
  self._state         = "GCD_ONLY"
  self._stateStart    = now()
  self._stateDuration = GCD
  self._cancelFlag    = false
end

-- After a regular direct spell (e.g. Shadow Bolt): cast + GCD overlap.
function NP:castSpell(duration)
  self._state         = "CASTING"
  self._stateStart    = now()
  self._stateDuration = duration or 2.5
  self._cancelFlag    = false
end

-- After starting a channel (e.g. Drain Soul, Dark Harvest).
function NP:startChannel(duration)
  self._state         = "CHANNELING"
  self._stateStart    = now()
  self._stateDuration = duration or 5.0
  self._cancelFlag    = false
end

-- Force-end the current state (simulates SPELLCAST_STOP / CHANNEL_STOP).
function NP:stop()
  self._state     = "IDLE"
  self._cancelFlag = false
end

-- ── nampower API surface ─────────────────────────────────────────────────────

-- Mirrors nampower's GetCurrentCastingInfo() signature.
-- Returns 7 values: castingSpellId, visualSpellId, autoRepeatSpellId,
--                   isCasting, isChanneling, pendingOnSwing, autoAttacking
-- During GCD_ONLY: ALL zeros (including isCasting and isChanneling).
-- This is the root of the GCD-after-instant-cast detection problem.
function NP:GetCurrentCastingInfo()
  tick(self)
  if self._state == "CASTING" then
    -- isCasting = 1 at index 4
    return 1, 1, 0, 1, 0, 0, 0
  elseif self._state == "CHANNELING" then
    -- isChanneling = 1 at index 5
    return 0, 1, 0, 0, 1, 0, 0
  else  -- IDLE or GCD_ONLY: indistinguishable from outside Lua
    return 0, 0, 0, 0, 0, 0, 0
  end
end

-- Returns nil when activeSpellId == 0 (IDLE and GCD_ONLY states).
-- Crucially: returns nil during the GCD window after an instant cast.
function NP:GetCastInfo()
  tick(self)
  if self._state == "IDLE" or self._state == "GCD_ONLY" then
    return nil
  end
  local elapsed   = now() - self._stateStart
  local remaining = math.max(0, self._stateDuration - elapsed)
  local gcdLeft   = math.max(0, GCD - elapsed)
  return {
    castId          = 1,
    spellId         = 1,
    isCasting       = (self._state == "CASTING")    and 1 or 0,
    isChanneling    = (self._state == "CHANNELING")  and 1 or 0,
    castRemainingMs  = remaining * 1000,
    castDurationMs   = self._stateDuration * 1000,
    gcdEndS          = self._stateStart + GCD,
    gcdRemainingMs   = gcdLeft * 1000,
  }
end

-- Sets nampower's cancelChannelNextTick flag.
-- Only works while a channel is active; sets _cancelFlag and
-- immediately ends the channel so tests can observe the effect.
function NP:ChannelStopCastingNextTick()
  tick(self)
  if self._state == "CHANNELING" then
    self._cancelFlag = true
    self._state      = "IDLE"
  end
end

-- Current state string ("IDLE", "GCD_ONLY", "CASTING", "CHANNELING").
function NP:state()
  tick(self)
  return self._state
end

-- ── global API wiring ────────────────────────────────────────────────────────
-- Call NP:install() to replace the real WoW globals with stub versions.
-- Call NP:uninstall() to restore them.

function NP:install()
  self._orig = {
    GCCI = GetCurrentCastingInfo,
    GCI  = GetCastInfo,
    CSNT = ChannelStopCastingNextTick,
  }
  local np = self
  GetCurrentCastingInfo      = function() return np:GetCurrentCastingInfo() end
  GetCastInfo                = function() return np:GetCastInfo()            end
  ChannelStopCastingNextTick = function() np:ChannelStopCastingNextTick()   end
end

function NP:uninstall()
  if not self._orig then return end
  GetCurrentCastingInfo      = self._orig.GCCI
  GetCastInfo                = self._orig.GCI
  ChannelStopCastingNextTick = self._orig.CSNT
  self._orig = nil
end

return NP
