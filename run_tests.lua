-- run_tests.lua  (Lua 5.1+, no WoW client)
-- Usage (from the AutoLock directory):
--   lua run_tests.lua                      -- all suites
--   lua run_tests.lua nampower_guard       -- single suite
--   lua run_tests.lua channeling_guard

-- ============================================================
-- 1. WoW / Ace2 load-time stubs
--    (only what AutoLock.lua touches while being parsed/loaded)
-- ============================================================
local function noop() end

-- AceLocale: key-based fallback table
-- AceAddon + everything else: minimal mixin factory
AceLibrary = function(name)
  if name == "AceLocale-2.2" then
    return {
      new = function(self)
        return setmetatable({}, { __index = function(_, k) return k end })
      end
    }
  end
  return {
    new = function(self, ...)
      return {
        RegisterEvent       = noop,
        UnregisterEvent     = noop,
        RegisterChatCommand = noop,
        Hook                = noop,
        HookScript          = noop,
      }
    end
  }
end

-- Frame stub: stores scripts/events without doing anything
local function make_frame()
  local f = { _ev = {}, _sc = {} }
  f.RegisterEvent = function(self, e) self._ev[e] = true end
  f.SetScript     = function(self, ev, fn) self._sc[ev] = fn end
  f.GetScript     = function(self, ev) return self._sc[ev] end
  f.GetFrameLevel = function() return 0 end
  f.IsVisible     = function() return false end
  f.IsShown       = function() return false end
  f.Show = noop; f.Hide = noop
  return f
end
CreateFrame = function() return make_frame() end

-- WoW globals needed at load time
GetTime               = function() return 0 end
UnitExists            = function(u) if u == "target" then return 1, "t-0" end end
UnitMana              = function() return 10000 end
CastSpellByName       = noop
GetCurrentCastingInfo = function() return nil, nil end
PlayerIsMoving        = nil
MovementEvents        = { IsMoving = function() return false end }
BOOKTYPE_SPELL        = "spell"
COMBAT_SPELL_PRIORITY = {}
Cursive               = nil
AutoLockDB            = nil

-- AutoLockLog stub (skips DEFAULT_CHAT_FRAME entirely)
DEFAULT_CHAT_FRAME = { AddMessage = noop }
AutoLockLog = {
  Info    = noop,   -- swap to `print` if you want debug output
  Warning = noop,
  Error   = noop,
}

-- ============================================================
-- 2. Load production code
--    Resolves path relative to THIS script so it works whether
--    invoked as `lua run_tests.lua` or `lua path/to/run_tests.lua`.
-- ============================================================
local src = debug.getinfo(1, "S").source
local dir = (src:match("^@(.+)[/\\]") or ".") .. "/"

dofile(dir .. "AutoLock.lua")

-- Stub Helper methods (normally from AutoLockHelper.lua).
-- rot_env_new() will override these per-test.
AutoLock.IsSpellOutOfRange      = function() return false end
AutoLock.GetSpellManaCostByName = function() return nil   end
AutoLock.HasAnyBuff             = function() return false end
AutoLock.IsOnCooldown           = function() return false end
AutoLock.HasDebuffByName        = function() return false end
AutoLock.IsTrinketReady         = function() return false end
AutoLock.BuildKnownSpellSet     = noop
AutoLock.DeleteSoulShards       = noop

-- ============================================================
-- 3. Micro test framework
-- ============================================================
local _pass, _fail = 0, 0
local _log = {}

local function ok(label)
  _pass = _pass + 1
  table.insert(_log, "[PASS] " .. label)
end
local function fail(label, info)
  _fail = _fail + 1
  table.insert(_log, "[FAIL] " .. label .. (info and ("  ← " .. info) or ""))
end

local function eq(a, b, label)
  if a == b then ok(label)
  else fail(label, "got=" .. tostring(a) .. "  want=" .. tostring(b)) end
end
local function is_nil(v, label)
  if v == nil then ok(label)
  else fail(label, "want nil  got=" .. tostring(v)) end
end
local function is_true(v, label)
  if v then ok(label) else fail(label, "want true") end
end
local function is_false(v, label)
  if not v then ok(label) else fail(label, "want false") end
end

-- ============================================================
-- 4. Mock environment (nampower stub + WoW API)
-- ============================================================
-- Controlled clock shared across tests in a suite.
local _clock = 1000

local function rot_env_new()
  local env = {
    lastCast        = nil,
    hasShadowTrance = false,
    -- np.casting / np.channeling → what GetCurrentCastingInfo() returns.
    np = { casting = nil, channeling = nil },
  }

  -- Save everything we will replace
  env._o = {
    GCCI  = GetCurrentCastingInfo,
    CSBN  = CastSpellByName,
    UE    = UnitExists,
    UM    = UnitMana,
    GT    = GetTime,
    ISOR  = AutoLock.IsSpellOutOfRange,
    GSMCB = AutoLock.GetSpellManaCostByName,
    HAB   = AutoLock.HasAnyBuff,
    Cur   = Cursive,
    DB    = AutoLockDB,
    CCN   = AutoLock._combatConfigName,
    NpQ   = AutoLock._npQueuedThisCast,
    NpP   = AutoLock._npQueuedPriority,
  }

  local e = env  -- upvalue for closures

  -- Nampower stub: reads from env.np
  GetCurrentCastingInfo = function()
    return e.np.casting or nil, e.np.channeling or nil
  end

  -- Record what was cast (type "cast" and "curse" both write here)
  CastSpellByName = function(name) e.lastCast = name end

  -- Target always present with a stable GUID
  UnitExists = function(u)
    if u == "target" then return 1, "test-0000" end
    return nil
  end

  UnitMana = function() return 10000 end
  GetTime  = function() return _clock end

  -- In-range, zero mana cost (skip Life Tap path entirely)
  AutoLock.IsSpellOutOfRange      = function() return false end
  AutoLock.GetSpellManaCostByName = function() return nil   end

  -- Shadow Trance controlled via env.hasShadowTrance
  AutoLock.HasAnyBuff = function(_, unit, buff)
    return e.hasShadowTrance and buff == "Shadow Trance"
  end

  -- Cursive: all curses already present (HasCurse=true) so
  -- darkHarvestDotsReady passes; Curse() records the cast and returns true.
  Cursive = {
    curses = { HasCurse = function() return true end },
    Curse  = function(_, name) e.lastCast = name; return true end,
  }

  -- Minimal DB: no dot requirements for DH; Nightfall off by default
  AutoLockDB = {
    configs = { {
      name                      = "rot_test",
      darkHarvestDots           = {},
      darkHarvestAllowNightfall = false,
    } },
    activeConfig = "rot_test",
  }
  AutoLock._combatConfigName = nil   -- use activeConfig fallback

  function env:restore()
    GetCurrentCastingInfo           = self._o.GCCI
    CastSpellByName                 = self._o.CSBN
    UnitExists                      = self._o.UE
    UnitMana                        = self._o.UM
    GetTime                         = self._o.GT
    AutoLock.IsSpellOutOfRange      = self._o.ISOR
    AutoLock.GetSpellManaCostByName = self._o.GSMCB
    AutoLock.HasAnyBuff             = self._o.HAB
    Cursive                         = self._o.Cur
    AutoLockDB                      = self._o.DB
    AutoLock._combatConfigName      = self._o.CCN
    AutoLock._npQueuedThisCast      = self._o.NpQ
    AutoLock._npQueuedPriority      = self._o.NpP
    AutoLock:_testSetDrainSoulChanneling(false)
    AutoLock:_testSetDarkHarvestChanneling(false)
  end

  return env
end

-- Minimal sorted spell list: [SB-Nightfall=1, DH=22, DS=23].
-- No curses in this list — the tests focus on the DH/DS/SB guard logic,
-- not on whether Cursive fires correctly.  Simplified conditions ensure
-- each test controls exactly one variable at a time.
local function rot_spells()
  return {
    { name = "Shadow Bolt",  type = "cast", priority = 1,  enabled = true, target = "target",
      condition = function()
        return AutoLock:HasAnyBuff("player", "Shadow Trance", "Spell_Shadow_Twilight")
      end },
    { name = "Dark Harvest", type = "cast", priority = 22, enabled = true, target = "target",
      condition = function() return true end },
    { name = "Drain Soul",   type = "cast", priority = 23, enabled = true, target = "target",
      condition = function() return true end },
  }
end

-- ============================================================
-- 5. Test suites
-- ============================================================
local SUITES = {}
local function suite(name, fn) SUITES[name] = fn end

-- ── nampower_guard ────────────────────────────────────────────
-- Tests the priority-based GCD-queue guard inside TryAction.
-- After a spell is queued, _npQueuedPriority stores its priority.
-- During the GCD (casting=true, channeling=nil), only spells with
-- a STRICTLY lower priority number (= higher priority) may fire.
suite("nampower_guard", function()
  local env = rot_env_new()
  local s   = rot_spells()

  -- T1: No GCD active — DH (prio 22) fires before DS (prio 23)
  AutoLock._npQueuedThisCast = false
  AutoLock._npQueuedPriority = 99999
  env.np.casting    = nil
  env.np.channeling = nil
  eq(AutoLock:_testRunList(s), "Dark Harvest",
    "T1 no GCD: DH (22) fires before DS (23)")

  -- T2: Curse queued (prio 7), GCD active.
  --   DH: 22 >= 7 → BLOCKED.  DS: 23 >= 7 → BLOCKED.
  --   SB: condition fails (no proc) → skipped.
  --   Expected: nil (nothing fires).
  AutoLock._npQueuedThisCast = true
  AutoLock._npQueuedPriority = 7
  env.np.casting    = true
  env.np.channeling = nil
  is_nil(AutoLock:_testRunList(s),
    "T2 curse-GCD (prio7): DH+DS both blocked, nothing fires")

  -- T3: DS queued (prio 23), GCD active.
  --   DH: 22 < 23 → NOT blocked → fires and overrides DS in queue.
  AutoLock._npQueuedPriority = 23
  eq(AutoLock:_testRunList(s), "Dark Harvest",
    "T3 DS-queued (prio23): DH (22<23) overrides DS in queue")

  -- T4: DS queued (prio 23), DH disabled.
  --   DS: 23 >= 23 → BLOCKED.  Expected: nil.
  s[2].enabled = false
  is_nil(AutoLock:_testRunList(s),
    "T4 DS-queued, DH disabled: DS (23>=23) itself blocked")
  s[2].enabled = true

  -- T5: GCD over (casting=nil, queue cleared) — DH fires again.
  AutoLock._npQueuedThisCast = false
  AutoLock._npQueuedPriority = 99999
  env.np.casting = nil
  eq(AutoLock:_testRunList(s), "Dark Harvest",
    "T5 after GCD ends: DH fires normally")

  -- T6: SB Nightfall queued (prio 1), GCD active — nothing can override prio 1.
  AutoLock._npQueuedThisCast = true
  AutoLock._npQueuedPriority = 1
  env.np.casting = true
  is_nil(AutoLock:_testRunList(s),
    "T6 SB-prio1 queued: nothing can override (DH=22>=1, DS=23>=1)")

  env:restore()
end)

-- ── channeling_guard ──────────────────────────────────────────
-- Tests TryAction behaviour while a spell channel is active.
--
-- DS channeling: np returns (casting=nil, channeling=true).
--   The priority guard's inner condition is `casting and not channeling`
--   → false, so the guard NEVER fires during a channel.
--   DH and SB evaluate freely.
--
-- DH channeling: the dedicated DH-channel guard in TryAction blocks
--   ALL spells unless the entry is the Nightfall SB AND
--   darkHarvestAllowNightfall is true in the config.
suite("channeling_guard", function()
  local env = rot_env_new()
  local s   = rot_spells()
  -- Priority guard starts disarmed; all blocking comes from channel guards.
  AutoLock._npQueuedThisCast = false
  AutoLock._npQueuedPriority = 99999

  -- ── DS channeling ─────────────────────────────────────────
  AutoLock:_testSetDrainSoulChanneling(true)
  AutoLock:_testSetDrainSoulTiming(_clock, 15)  -- 15s remaining
  env.np.casting    = nil
  env.np.channeling = true   -- nampower: channel active

  -- T1: No proc — DS channeling does NOT block DH; DH fires.
  --   (The DH-channel guard only checks DarkHarvestChanneling, not DS.)
  env.hasShadowTrance = false
  eq(AutoLock:_testRunList(s), "Dark Harvest",
    "T1 DS channeling, no proc: DH fires (DS does not block DH)")

  -- T2: Shadow Trance proc present — SB (prio 1) fires first.
  env.hasShadowTrance = true
  eq(AutoLock:_testRunList(s), "Shadow Bolt",
    "T2 DS channeling + Shadow Trance: SB fires (prio 1 beats DH 22)")
  env.hasShadowTrance = false

  -- ── DH channeling ─────────────────────────────────────────
  AutoLock:_testSetDrainSoulChanneling(false)
  AutoLock:_testSetDarkHarvestChanneling(true)
  AutoLock:_testSetDarkHarvestTiming(_clock, 15)

  -- T3: Nightfall off — DH-channel guard blocks everything → nil.
  AutoLockDB.configs[1].darkHarvestAllowNightfall = false
  is_nil(AutoLock:_testRunList(s),
    "T3 DH channeling, Nightfall=off: SB+DH+DS all blocked")

  -- T4: Nightfall on, no proc — SB condition fails → nil.
  AutoLockDB.configs[1].darkHarvestAllowNightfall = true
  env.hasShadowTrance = false
  is_nil(AutoLock:_testRunList(s),
    "T4 DH channeling, Nightfall=on, no proc: nothing fires")

  -- T5: Nightfall on + proc — SB is the only spell allowed through.
  env.hasShadowTrance = true
  eq(AutoLock:_testRunList(s), "Shadow Bolt",
    "T5 DH channeling + Nightfall=on + proc: SB fires")

  env:restore()
end)

-- ============================================================
-- 6. Runner
-- ============================================================
local filter = arg and arg[1]

for name, fn in pairs(SUITES) do
  if not filter or filter == name then
    local ok_run, err = pcall(fn)
    if not ok_run then
      fail("[suite:" .. name .. " crashed]", tostring(err))
    end
  end
end

print("")
for _, msg in ipairs(_log) do print(msg) end

print(string.format("\n%d passed, %d failed", _pass, _fail))
if _fail > 0 then os.exit(1) end
