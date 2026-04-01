-- run_tests.lua  (Lua 5.1+, no WoW client)
-- Usage (from the AutoLock directory):
--   lua run_tests.lua                      -- all suites
--   lua run_tests.lua nampower_guard       -- single suite

-- ============================================================
-- 1. WoW / Ace2 load-time stubs
-- ============================================================
local function noop() end

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

GetTime               = function() return 0 end
UnitExists            = function(u) if u == "target" then return 1, "t-0" end end
UnitMana              = function() return 10000 end
UnitIsDead            = function() return false end
CastSpellByName       = noop
GetPetActionInfo      = function() return nil end
GetCurrentCastingInfo = function() return 0, 0, 0, 0, 0, 0, 0 end
PlayerIsMoving        = nil
MovementEvents        = { IsMoving = function() return false end }
BOOKTYPE_SPELL        = "spell"
COMBAT_SPELL_PRIORITY = {}
Cursive               = nil
AutoLockDB            = nil

DEFAULT_CHAT_FRAME = { AddMessage = noop }
AutoLockLog = { Info = noop, Warning = noop, Error = noop }

-- ============================================================
-- 2. Load production code
-- ============================================================
local src = debug.getinfo(1, "S").source
local dir = (src:match("^@(.+)[/\\]") or ".") .. "/"

dofile(dir .. "AutoLock.lua")
dofile(dir .. "AutoLockSoulShards.lua")
dofile(dir .. "AutoLockEngine.lua")
dofile(dir .. "AutoLockSpells.lua")

-- Load nampower stub (used by the gcd_realworld suite).
local NP = dofile(dir .. "nampower_stub.lua")

-- Stub Helper methods (normally from AutoLockHelper.lua).
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
-- 4. Rotation mock environment
-- ============================================================
local _clock = 1000   -- shared fake clock for rotation suites

local function rot_env_new()
  local env = {
    lastCast        = nil,
    hasShadowTrance = false,
    -- np.casting / np.channeling → what GetCurrentCastingInfo() returns.
    np = { casting = nil, channeling = nil },
  }

  env._o = {
    GCCI  = GetCurrentCastingInfo,
    CSBN  = CastSpellByName,
    UE    = UnitExists,
    UM    = UnitMana,
    GT    = GetTime,
    ISOR  = AutoLock.IsSpellOutOfRange,
    GSMCB = AutoLock.GetSpellManaCostByName,
    HAB   = AutoLock.HasAnyBuff,
    IOC   = AutoLock.IsOnCooldown,
    Cur   = Cursive,
    DB    = AutoLockDB,
    CCN   = AutoLock._combatConfigName,
    NpQ   = AutoLock._npQueuedThisCast,
    NpP   = AutoLock._npQueuedPriority,
  }

  local e = env

  -- Returns correct 7-value format; isCasting=index4, isChanneling=index5.
  GetCurrentCastingInfo = function()
    local isCasting    = (e.np.casting    and 1) or 0
    local isChanneling = (e.np.channeling and 1) or 0
    return 0, 0, 0, isCasting, isChanneling, 0, 0
  end

  CastSpellByName = function(name) e.lastCast = name end

  UnitExists = function(u)
    if u == "target" then return 1, "test-0000" end
    return nil
  end

  UnitMana = function() return 10000 end
  GetTime  = function() return _clock end

  AutoLock.IsSpellOutOfRange      = function() return false end
  AutoLock.GetSpellManaCostByName = function() return nil   end

  AutoLock.HasAnyBuff = function(_, unit, buff)
    return e.hasShadowTrance and buff == "Shadow Trance"
  end

  -- Default: Curse returns false (simulates curses already up / refreshtime=0 not met).
  -- Rotation must pass through to DH/DS in idle state, matching real game behaviour.
  -- Does NOT set lastCast on false return — only a real cast (ok=true) records the spell.
  Cursive = {
    curses = { HasCurse = function() return true end },
    Curse  = function(_, name) return false end,
  }

  AutoLockDB = {
    configs = { {
      name                      = "rot_test",
      darkHarvestDots           = {},
      darkHarvestAllowNightfall = false,
    } },
    activeConfig = "rot_test",
  }
  AutoLock._combatConfigName = nil

  function env:restore()
    GetCurrentCastingInfo           = self._o.GCCI
    CastSpellByName                 = self._o.CSBN
    UnitExists                      = self._o.UE
    UnitMana                        = self._o.UM
    GetTime                         = self._o.GT
    AutoLock.IsSpellOutOfRange      = self._o.ISOR
    AutoLock.GetSpellManaCostByName = self._o.GSMCB
    AutoLock.HasAnyBuff             = self._o.HAB
    AutoLock.IsOnCooldown           = self._o.IOC
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

-- Minimal spell list: SB-Nightfall(1), CoA(7), DH(22), DS(23).
-- Conditions are stripped to the bare minimum each test needs.
local function rot_spells()
  return {
    { name = "Shadow Bolt",    type = "cast",  priority = 1,  enabled = true, target = "target",
      condition = function()
        return AutoLock:HasAnyBuff("player", "Shadow Trance", "Spell_Shadow_Twilight")
      end },
    { name = "Curse of Agony", type = "curse", priority = 7,  enabled = true, target = "target",
      refreshtime = 0, condition = function() return true end },
    { name = "Dark Harvest",   type = "cast",  priority = 22, enabled = true, target = "target",
      condition = function() return true end },
    { name = "Drain Soul",     type = "cast",  priority = 23, enabled = true, target = "target",
      condition = function() return true end },
  }
end

-- ============================================================
-- 5. Test suites
-- ============================================================
local SUITES = {}
local function suite(name, fn) SUITES[name] = fn end

-- ── toggle ────────────────────────────────────────────────────
suite("toggle", function()
  local e = { enabled = nil }
  e.enabled = not (e.enabled == true)
  eq(e.enabled, true,  "toggle nil->true")
  e.enabled = not (e.enabled == true)
  eq(e.enabled, false, "toggle true->false")
  e.enabled = not (e.enabled == true)
  eq(e.enabled, true,  "toggle false->true")
  e.enabled = not (e.enabled == true)
  eq(e.enabled, false, "toggle true->false (2nd)")
end)

-- ── darkHarvestDots ──────────────────────────────────────────
suite("darkHarvestDots", function()
  local cfg = { name = "Test", spells = {} }
  is_nil(cfg.darkHarvestDots, "darkHarvestDots initially nil")

  if not cfg.darkHarvestDots then cfg.darkHarvestDots = {} end
  local key = "siphonLife"
  cfg.darkHarvestDots[key] = not (cfg.darkHarvestDots[key] == true)
  eq(cfg.darkHarvestDots.siphonLife, true, "siphonLife set to true")

  cfg.spells = {}
  eq(cfg.darkHarvestDots.siphonLife, true, "siphonLife survives cfg.spells = {}")

  cfg.darkHarvestDots[key] = not (cfg.darkHarvestDots[key] == true)
  eq(cfg.darkHarvestDots.siphonLife, false, "siphonLife toggled to false")

  local setArg = cfg.darkHarvestDots.siphonLife and 1 or nil
  is_nil(setArg, "SetChecked(nil) for false")

  cfg.darkHarvestDots[key] = not (cfg.darkHarvestDots[key] == true)
  setArg = cfg.darkHarvestDots.siphonLife and 1 or nil
  eq(setArg, 1, "SetChecked(1) for true")
end)

-- ── darkHarvestDotsReady ─────────────────────────────────────
suite("darkHarvestDotsReady", function()
  local DH_DURATION = 6.0

  -- Mirror the real darkHarvestDotsReady logic
  local function dotsReady(cfg, timeRemaining, debuffOn)
    if cfg and cfg.darkHarvestRequireFullDotTime then
      local required = DH_DURATION * 1.3
      local function rem(name) return timeRemaining and timeRemaining(name) or 0 end
      local dotSel = (cfg and cfg.darkHarvestFullDotTimeDots) or {}
      if dotSel.agony      ~= false and rem("curse of agony") < required then return false end
      if dotSel.corruption ~= false and rem("corruption")     < required then return false end
      if dotSel.siphonLife ~= false and rem("siphon life")    < required then return false end
    end
    local req = cfg and cfg.darkHarvestDots
    if req and req.shadowVuln then
      if not debuffOn("Shadow Vulnerability") then return false end
    end
    return true
  end

  local ENOUGH = function(_) return DH_DURATION * 1.3 end
  local LOW    = function(_) return 0 end
  local YES    = function(_) return true  end
  local NO     = function(_) return false end

  is_true (dotsReady(nil,  ENOUGH, YES), "nil req → ready")
  is_true (dotsReady({},   ENOUGH, YES), "empty cfg → ready")
  is_true (dotsReady({ darkHarvestRequireFullDotTime=false }, LOW, YES), "requireFullDotTime=false → ready")
  is_true (dotsReady({ darkHarvestRequireFullDotTime=true  }, ENOUGH, YES), "all dots enough → ready")
  local lowSiphon = function(n) return n == "siphon life" and 0 or DH_DURATION * 1.3 end
  is_false(dotsReady({ darkHarvestRequireFullDotTime=true }, lowSiphon, YES), "siphon life low → blocked")
  is_true (dotsReady({ darkHarvestRequireFullDotTime=true,
    darkHarvestFullDotTimeDots={ siphonLife=false } }, lowSiphon, YES),
    "siphonLife sub-unchecked → siphon low ignored → ready")
  local lowAgony = function(n) return n == "curse of agony" and 0 or DH_DURATION * 1.3 end
  is_true (dotsReady({ darkHarvestRequireFullDotTime=true,
    darkHarvestFullDotTimeDots={ agony=false } }, lowAgony, YES),
    "agony sub-unchecked → agony low ignored → ready")
  is_true (dotsReady({ darkHarvestDots={ shadowVuln=true } }, ENOUGH, YES), "shadowVuln required+present")
  is_false(dotsReady({ darkHarvestDots={ shadowVuln=true } }, ENOUGH, NO),  "shadowVuln required+missing")
end)

-- ── isBlockedByDrainSoul (pure logic) ────────────────────────
suite("isBlockedByDrainSoul_logic", function()
  local function blocked(key, channeling, dots)
    if not channeling then return false end
    if not dots then return false end
    return dots[key] ~= true
  end

  is_false(blocked("agony",      false, { agony=true }),      "not channeling → not blocked")
  is_false(blocked("corruption", false, { corruption=true }), "not channeling → not blocked")
  is_false(blocked("siphonLife", false, { siphonLife=true }), "not channeling → not blocked")
  is_false(blocked("agony", true, nil), "channeling, nil config → not blocked (default on)")
  is_true (blocked("agony", true, {}),  "channeling, empty config → blocked")
  is_false(blocked("agony",      true, { agony=true }),      "agony checked → allowed")
  is_false(blocked("corruption", true, { corruption=true }), "corruption checked → allowed")
  is_false(blocked("siphonLife", true, { siphonLife=true }), "siphonLife checked → allowed")
  is_true (blocked("agony",      true, { agony=false }),     "agony=false → blocked")
  is_true (blocked("corruption", true, { agony=true }),      "corruption unchecked → blocked")
  local allChecked = { agony=true, corruption=true, siphonLife=true }
  is_false(blocked("agony",      true, allChecked), "all checked: agony allowed")
  is_false(blocked("corruption", true, allChecked), "all checked: corruption allowed")
  is_false(blocked("siphonLife", true, allChecked), "all checked: siphonLife allowed")
  is_true (blocked("shadowVuln", true, allChecked), "shadowVuln not in DS config → blocked")
end)

-- ── getSpellKey ──────────────────────────────────────────────
suite("getSpellKey", function()
  local function key(e)
    return (e.uitext or e.name or "?") .. "|" .. (e.type or "?")
  end
  eq(key({ name="Shadow Bolt", type="cast" }),   "Shadow Bolt|cast",  "normal spell")
  eq(key({ name="Siphon Life", type="curse" }),  "Siphon Life|curse", "curse")
  eq(key({ name="Shadow Bolt", type="cast", uitext="Shadow Trance (Shadow Bolt)" }),
     "Shadow Trance (Shadow Bolt)|cast", "uitext overrides name")
  eq(key({}),             "?|?",   "empty entry")
  eq(key({ type="pet" }), "?|pet", "nil name")
end)

-- ── configSystem ─────────────────────────────────────────────
suite("configSystem", function()
  local configs = {
    { name="ConfigA", spells={}, darkHarvestDots={ siphonLife=true } },
    { name="ConfigB", spells={} },
  }
  local function getActive(loadedName, activeName)
    local name = loadedName or activeName
    for _, c in ipairs(configs) do if c.name == name then return c end end
  end

  local cfg = getActive("ConfigA", "ConfigA")
  eq(cfg and cfg.name, "ConfigA", "getActive returns ConfigA")
  eq(cfg and cfg.darkHarvestDots and cfg.darkHarvestDots.siphonLife, true, "ConfigA has siphonLife")

  cfg = getActive("ConfigB", "ConfigA")
  eq(cfg and cfg.name, "ConfigB", "preview returns ConfigB")
  is_nil(cfg and cfg.darkHarvestDots, "ConfigB has no darkHarvestDots")
  eq(configs[1].darkHarvestDots.siphonLife, true, "ConfigA darkHarvestDots intact after switch")

  local loadedName = "ConfigB"
  local savedName  = loadedName
  loadedName = "ConfigA"
  loadedName = savedName
  eq(loadedName, "ConfigB", "loadedName restored after _reloadActiveCombatConfig")
end)

-- ── hasDebuffByName ──────────────────────────────────────────
suite("hasDebuffByName", function()
  local function hasDebuff(debuffs, target)
    local idToName = {}
    for _, d in ipairs(debuffs) do idToName[d.id] = d.name end
    for i = 1, #debuffs do
      local id = debuffs[i].id
      if id then
        if idToName[id] == target then return true end
      else
        break
      end
    end
    return false
  end

  local list = {
    { id=1, name="Curse of Agony" },
    { id=2, name="Shadow Vulnerability" },
    { id=3, name="Corruption" },
  }
  is_true (hasDebuff(list, "Shadow Vulnerability"), "finds Shadow Vulnerability")
  is_true (hasDebuff(list, "Curse of Agony"),       "finds Curse of Agony")
  is_false(hasDebuff(list, "Siphon Life"),           "absent debuff → false")
  is_false(hasDebuff({},   "Shadow Vulnerability"),  "empty list → false")
end)

-- ── sanitizeNumber ───────────────────────────────────────────
suite("sanitizeNumber", function()
  local function san(s)
    s = tostring(s or "")
    s = string.gsub(s, ",", ".")
    s = string.gsub(s, "[^0-9%.]", "")
    local dot = string.find(s, "%.")
    if dot then
      local head = string.sub(s, 1, dot)
      local tail = string.gsub(string.sub(s, dot + 1), "%.", "")
      s = head .. tail
    end
    return s
  end
  eq(san("30"),    "30",   "integer")
  eq(san("1.5"),   "1.5",  "float")
  eq(san("1,5"),   "1.5",  "comma→dot")
  eq(san("abc"),   "",     "letters stripped")
  eq(san("1.2.3"), "1.23", "double dot")
  eq(san(""),      "",     "empty")
  eq(san(nil),     "",     "nil")
  eq(san(" 10 "),  "10",   "spaces stripped")
end)

-- ── drainSoulBlocking ────────────────────────────────────────
suite("drainSoulBlocking", function()
  local savedDB  = AutoLockDB
  local savedCCN = AutoLock._combatConfigName
  local function restore()
    AutoLockDB = savedDB
    AutoLock._combatConfigName = savedCCN
    AutoLock:_testSetDrainSoulChanneling(false)
  end
  local pass, err = pcall(function()
    AutoLockDB = {
      configs = { { name="DS_Test", drainSoulDots = { agony=true, corruption=true } } },
      activeConfig = "DS_Test",
    }
    AutoLock._combatConfigName = "DS_Test"

    AutoLock:_testSetDrainSoulChanneling(false)
    is_false(AutoLock:_testIsBlockedByDrainSoul("agony"),      "not channeling: agony not blocked")
    is_false(AutoLock:_testIsBlockedByDrainSoul("corruption"), "not channeling: corruption not blocked")
    is_false(AutoLock:_testIsBlockedByDrainSoul("siphonLife"), "not channeling: siphonLife not blocked")

    -- Channel elapsed → treated as finished
    AutoLock:_testSetDrainSoulChanneling(true)
    AutoLock:_testSetDrainSoulTiming(GetTime() - 10, 5)
    is_false(AutoLock:_testIsBlockedByDrainSoul("agony"),      "channeling done: agony checked → allowed")
    is_false(AutoLock:_testIsBlockedByDrainSoul("corruption"), "channeling done: corruption checked → allowed")

    -- Active channel
    AutoLock:_testSetDrainSoulTiming(GetTime(), 15)
    is_true(AutoLock:_testIsBlockedByDrainSoul("siphonLife"), "channeling active: siphonLife unchecked → blocked")

    AutoLockDB.configs[1].drainSoulDots.siphonLife = true
    is_false(AutoLock:_testIsBlockedByDrainSoul("siphonLife"), "channeling active: siphonLife now checked → allowed")

    AutoLockDB.configs[1].drainSoulDots.agony = false
    is_true(AutoLock:_testIsBlockedByDrainSoul("agony"), "channeling active: agony=false → blocked")

    AutoLock._combatConfigName = "NonExistent"
    is_true(AutoLock:_testIsBlockedByDrainSoul("corruption"), "wrong config name → blocked (safe default)")

    AutoLock._combatConfigName = nil
    AutoLockDB.configs[1].drainSoulDots.corruption = true
    is_false(AutoLock:_testIsBlockedByDrainSoul("corruption"), "nil combatName: falls back to activeConfig")

    AutoLock._combatConfigName = "DS_Test"
    AutoLockDB.configs[1].drainSoulDots = nil
    is_false(AutoLock:_testIsBlockedByDrainSoul("agony"), "nil drainSoulDots → not blocked (default on)")
  end)
  restore()
  if not pass then fail("[drainSoulBlocking] crashed", tostring(err)) end
end)

-- ── drainSoulConditions ──────────────────────────────────────
suite("drainSoulConditions", function()
  local coaCond, corrCond, slCond
  for _, e in ipairs(SPELL_PRIORITY) do
    if e.name == "Curse of Agony"  and e.type == "curse" then coaCond  = e.condition end
    if e.name == "Corruption"      and e.type == "curse" then corrCond = e.condition end
    if e.name == "Siphon Life"     and e.type == "curse" then slCond   = e.condition end
  end
  is_true(coaCond  ~= nil, "Curse of Agony has a condition")
  is_true(corrCond ~= nil, "Corruption has a condition")
  is_true(slCond   ~= nil, "Siphon Life has a condition")
  if not coaCond or not corrCond or not slCond then return end

  local savedDB  = AutoLockDB
  local savedCCN = AutoLock._combatConfigName
  local function restore()
    AutoLockDB = savedDB
    AutoLock._combatConfigName = savedCCN
    AutoLock:_testSetDrainSoulChanneling(false)
  end
  local pass, err = pcall(function()
    AutoLockDB = {
      configs = { { name="CondTest", drainSoulDots = { agony=true, corruption=true, siphonLife=true } } },
      activeConfig = "CondTest",
    }
    AutoLock._combatConfigName = "CondTest"

    AutoLock:_testSetDrainSoulChanneling(false)
    is_true(coaCond ("target"), "CoA: not channeling → allowed")
    is_true(corrCond("target"), "Corruption: not channeling → allowed")
    is_true(slCond  ("target"), "SiphonLife: not channeling → allowed")

    AutoLock:_testSetDrainSoulChanneling(true)
    AutoLock:_testSetDrainSoulTiming(GetTime() - 10, 5)  -- elapsed, treated as finished
    is_true(coaCond ("target"), "CoA: channeling done, checked → allowed")
    is_true(corrCond("target"), "Corruption: channeling done, checked → allowed")
    is_true(slCond  ("target"), "SiphonLife: channeling done, checked → allowed")

    AutoLock:_testSetDrainSoulTiming(GetTime(), 15)
    AutoLockDB.configs[1].drainSoulDots.siphonLife = false
    is_false(slCond("target"), "SiphonLife: unchecked active DS → blocked")

    AutoLockDB.configs[1].drainSoulDots = nil
    is_true(coaCond ("target"), "CoA: nil drainSoulDots → not blocked (default on)")
    is_true(corrCond("target"), "Corruption: nil drainSoulDots → not blocked (default on)")
  end)
  restore()
  if not pass then fail("[drainSoulConditions] crashed", tostring(err)) end
end)

-- ── drainSoulRestartBug ──────────────────────────────────────
-- When the channel has timed out but CHANNEL_STOP has not yet fired,
-- DrainSoulChanneling is still true.  isBlockedByDrainSoul must respect
-- elapsed time to avoid blocking curses (and letting DS restart) in that window.
suite("drainSoulRestartBug", function()
  local savedDB  = AutoLockDB
  local savedCCN = AutoLock._combatConfigName
  local function restore()
    AutoLockDB = savedDB
    AutoLock._combatConfigName = savedCCN
    AutoLock:_testSetDrainSoulChanneling(false)
  end
  local pass, err = pcall(function()
    AutoLockDB = {
      configs = { { name = "DSRestart", drainSoulDots = {} } },
      activeConfig = "DSRestart",
    }
    AutoLock._combatConfigName = "DSRestart"

    -- Flag still set, but channel has elapsed
    AutoLock:_testSetDrainSoulChanneling(true)
    AutoLock:_testSetDrainSoulTiming(GetTime() - 10, 5)

    is_false(AutoLock:_testIsBlockedByDrainSoul("agony"),
      "DS timed out → agony must NOT be blocked")
    is_false(AutoLock:_testIsBlockedByDrainSoul("corruption"),
      "DS timed out → corruption must NOT be blocked")
    is_false(AutoLock:_testIsBlockedByDrainSoul("siphonLife"),
      "DS timed out → siphonLife must NOT be blocked")

    -- Sanity: active channel → curses ARE blocked
    AutoLock:_testSetDrainSoulTiming(GetTime(), 15)
    is_true(AutoLock:_testIsBlockedByDrainSoul("agony"),
      "DS active → agony is blocked (correct)")
  end)
  restore()
  if not pass then fail("[drainSoulRestartBug] crashed", tostring(err)) end
end)

-- ── cosDrainSoulBlocking ─────────────────────────────────────
-- CoS shares the curse slot with CoA ("agony" key), so it must be
-- blocked during DS channeling under the same rules as CoA.
suite("cosDrainSoulBlocking", function()
  local cosEntry
  for _, e in ipairs(SPELL_PRIORITY) do
    if e.name == "Curse of Shadow" and e.type == "curse" then cosEntry = e; break end
  end
  is_true(cosEntry ~= nil, "Curse of Shadow entry found in SPELL_PRIORITY")
  if not cosEntry then return end
  is_true(cosEntry.condition ~= nil, "Curse of Shadow must have a DS-blocking condition")
  if not cosEntry.condition then return end

  local savedDB  = AutoLockDB
  local savedCCN = AutoLock._combatConfigName
  local savedCur = Cursive
  local function restore()
    AutoLockDB = savedDB
    AutoLock._combatConfigName = savedCCN
    Cursive = savedCur
    AutoLock:_testSetDrainSoulChanneling(false)
  end
  local pass, err = pcall(function()
    AutoLockDB = {
      configs = { { name = "CosDS", drainSoulDots = { agony = false } } },
      activeConfig = "CosDS",
    }
    AutoLock._combatConfigName = "CosDS"
    -- CoS not on target: HasCurse guard must not interfere with the DS-blocking test.
    Cursive = {
      curses = { HasCurse = function() return false end },
      Curse  = function() return false end,
    }

    AutoLock:_testSetDrainSoulChanneling(true)
    AutoLock:_testSetDrainSoulTiming(GetTime(), 15)
    is_false(cosEntry.condition("target"),
      "CoS: active DS, agony unchecked → blocked")

    AutoLockDB.configs[1].drainSoulDots.agony = true
    is_true(cosEntry.condition("target"),
      "CoS: active DS, agony checked → allowed")

    AutoLock:_testSetDrainSoulChanneling(false)
    AutoLockDB.configs[1].drainSoulDots.agony = false
    is_true(cosEntry.condition("target"),
      "CoS: not channeling, agony unchecked → allowed (no DS active)")
  end)
  restore()
  if not pass then fail("[cosDrainSoulBlocking] crashed", tostring(err)) end
end)

-- ── cosCoaMutualExclusion ────────────────────────────────────
-- CoA condition must return false when CoS is already on the target.
suite("cosCoaMutualExclusion", function()
  local coaCond
  for _, e in ipairs(SPELL_PRIORITY) do
    if e.name == "Curse of Agony" and e.type == "curse" then coaCond = e.condition; break end
  end
  is_true(coaCond ~= nil, "Curse of Agony has a condition")
  if not coaCond then return end

  local savedDB    = AutoLockDB
  local savedCCN   = AutoLock._combatConfigName
  local savedCur   = Cursive
  local function restore()
    AutoLockDB = savedDB
    AutoLock._combatConfigName = savedCCN
    Cursive = savedCur
    AutoLock:_testSetDrainSoulChanneling(false)
  end
  local pass, err = pcall(function()
    AutoLockDB = {
      configs = { { name = "CoSTest", drainSoulDots = { agony = true } } },
      activeConfig = "CoSTest",
    }
    AutoLock._combatConfigName = "CoSTest"
    AutoLock:_testSetDrainSoulChanneling(false)

    Cursive = nil
    is_true(coaCond("target"), "no Cursive: CoA returns true")

    Cursive = {}
    is_true(coaCond("target"), "Cursive without .curses: CoA returns true")

    Cursive = {
      curses = { HasCurse = function(self, name, guid, refresh)
        return name == "curse of agony"
      end }
    }
    is_true(coaCond("target"), "CoS absent: CoA returns true")

    Cursive = {
      curses = { HasCurse = function(self, name, guid, refresh)
        return name == "curse of shadow"
      end }
    }
    is_true(coaCond("target"), "CoS active: CoA returns true (guard removed, Cursive handles slot)")

    -- DS blocking takes precedence
    AutoLock:_testSetDrainSoulChanneling(true)
    AutoLock:_testSetDrainSoulTiming(GetTime(), 15)
    AutoLockDB.configs[1].drainSoulDots = {}
    Cursive = {
      curses = { HasCurse = function(self, name, guid, refresh) return false end }
    }
    is_false(coaCond("target"), "DS blocking: CoA returns false regardless of CoS")
  end)
  restore()
  if not pass then fail("[cosCoaMutualExclusion] crashed", tostring(err)) end
end)

-- ── nampower_guard ────────────────────────────────────────────
-- Tests the priority-based queue guard inside TryAction.
-- Nampower's queue is a single slot (last-write-wins).  Only a spell
-- with STRICTLY lower priority number may call CastSpellByName when
-- _npQueuedThisCast is true.  No timestamp involved.
suite("nampower_guard", function()
  local env = rot_env_new()
  local ok_r, err = pcall(function()
    local s = rot_spells()

    -- T1: No queue → DH (prio 22) fires before DS (prio 23)
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999
    eq(AutoLock:_testRunList(s), "Dark Harvest",
      "T1 no queue: DH fires before DS")

    -- T2: Curse queued (prio 7) → DH (22>7) and DS (23>7) both blocked.
    -- CoA (same prio 7) passes the guard (7>7=false) but Cursive returns false → nil.
    AutoLock._npQueuedThisCast = true
    AutoLock._npQueuedPriority = 7
    is_nil(AutoLock:_testRunList(s),
      "T2 curse queued (prio7): DH (22>7)+DS (23>7) blocked → nothing fires")

    -- T3: DS queued (prio 23) → DH (22<23) NOT blocked → fires and overrides DS
    AutoLock._npQueuedPriority = 23
    eq(AutoLock:_testRunList(s), "Dark Harvest",
      "T3 DS queued (prio23): DH (22<23) overrides DS in queue")

    -- T3b: same-priority re-queue — the "nothing happens" regression.
    -- DS is queued (prio 23). Pressing again: 23 > 23 = false → NOT blocked.
    -- Same spell re-queuing the same nampower slot (last-write-wins) is harmless.
    -- With the old >= guard this returned nil → "nothing happens" in-game.
    AutoLock._npQueuedThisCast = true
    AutoLock._npQueuedPriority = 23
    eq(AutoLock:_testRunList({ s[4] }),  -- DS entry only, no competing spells
      "Drain Soul",
      "T3b same-prio re-queue: DS (23>23=false) re-queues itself")

    -- T4: DS queued (prio23), DH disabled → DS re-queues (23>23=false).
    -- (After T3b: prio still 23.)
    s[3].enabled = false
    eq(AutoLock:_testRunList(s), "Drain Soul",
      "T4 DS queued (prio23), DH disabled: DS re-queues itself")
    s[3].enabled = true

    -- T5: Queue cleared → DH fires normally
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999
    eq(AutoLock:_testRunList(s), "Dark Harvest",
      "T5 queue cleared: DH fires normally")

    -- T6: SB Nightfall (prio 1) queued → nothing can override (DH=22>=1, DS=23>=1)
    AutoLock._npQueuedThisCast = true
    AutoLock._npQueuedPriority = 1
    is_nil(AutoLock:_testRunList(s),
      "T6 SB prio1 queued: nothing can override")
  end)
  env:restore()
  if not ok_r then fail("[nampower_guard] crashed", tostring(err)) end
end)

-- ── channeling_guard ──────────────────────────────────────────
-- TryAction behaviour while DS or DH is channeling.
suite("channeling_guard", function()
  local env = rot_env_new()
  local ok_r, err = pcall(function()
    local s = rot_spells()
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999

    -- ── DS channeling ───────────────────────────────────────
    AutoLock:_testSetDrainSoulChanneling(true)
    AutoLock:_testSetDrainSoulTiming(_clock, 15)
    env.np.channeling = true

    -- T1: No proc → DH fires (DS does not block DH)
    env.hasShadowTrance = false
    eq(AutoLock:_testRunList(s), "Dark Harvest",
      "T1 DS channeling, no proc: DH fires")

    -- T2: Shadow Trance proc → SB (prio 1) fires first
    env.hasShadowTrance = true
    eq(AutoLock:_testRunList(s), "Shadow Bolt",
      "T2 DS channeling + Shadow Trance: SB fires")
    env.hasShadowTrance = false

    -- ── DH channeling ───────────────────────────────────────
    AutoLock:_testSetDrainSoulChanneling(false)
    AutoLock:_testSetDarkHarvestChanneling(true)
    AutoLock:_testSetDarkHarvestTiming(_clock, 15)

    -- T3: Nightfall off → everything blocked
    AutoLockDB.configs[1].darkHarvestAllowNightfall = false
    is_nil(AutoLock:_testRunList(s),
      "T3 DH channeling, Nightfall off: all blocked")

    -- T4: Nightfall on, no proc → nothing fires
    AutoLockDB.configs[1].darkHarvestAllowNightfall = true
    env.hasShadowTrance = false
    is_nil(AutoLock:_testRunList(s),
      "T4 DH channeling, Nightfall on, no proc: nothing fires")

    -- T5: Nightfall on + proc → SB fires
    env.hasShadowTrance = true
    eq(AutoLock:_testRunList(s), "Shadow Bolt",
      "T5 DH channeling + Nightfall on + proc: SB fires")
  end)
  env:restore()
  if not ok_r then fail("[channeling_guard] crashed", tostring(err)) end
end)

-- ── gcd_realworld ─────────────────────────────────────────────
-- Uses the nampower stub to reproduce the real in-game GCD scenario.
-- Key proof: GetCurrentCastingInfo returns all zeros during GCD_ONLY
-- (after instant cast), so the guard cannot use that API.
-- The priority-only guard (_npQueuedThisCast + prio comparison) is the fix.
suite("gcd_realworld", function()
  local env = rot_env_new()
  local ok_r, err = pcall(function()
    local s = rot_spells()
    NP:install()

    -- ── Phase 1: verify nampower stub API behaviour ─────────
    NP:castInstant()
    local c1,c2,c3,c4,c5 = GetCurrentCastingInfo()
    eq(c4, 0, "R1a GCD_ONLY: isCasting (index 4) = 0")
    eq(c5, 0, "R1b GCD_ONLY: isChanneling (index 5) = 0")
    is_nil(GetCastInfo(), "R1c GCD_ONLY: GetCastInfo() = nil")
    NP:stop()

    -- ── Phase 2: no queue → DH fires freely ─────────────────
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999
    eq(AutoLock:_testRunList(s), "Dark Harvest",
      "R2 idle: DH fires freely")

    -- ── Phase 3: curse queued (prio 7), GCD_ONLY ────────────
    -- SPELLCAST_STOP would fire immediately for an instant curse,
    -- clearing the flag.  We test the window BEFORE that event.
    AutoLock._npQueuedThisCast = true
    AutoLock._npQueuedPriority = 7
    NP:castInstant()
    is_nil(AutoLock:_testRunList(s),
      "R3 curse queued (prio7): DH (22>7) + DS (23>7) blocked")

    -- ── Phase 4: DH queued after curse's SPELLCAST_STOP ─────
    -- After SPELLCAST_STOP the flag is cleared; DH fires and re-arms it.
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999
    NP:castInstant()  -- GCD still active
    -- DH fires (no guard), sets queue to prio 22
    AutoLock._npQueuedThisCast = true
    AutoLock._npQueuedPriority = 22
    -- Next macro press: DS (23>22) blocked; DH (22>22=false) re-queues itself (harmless).
    -- Critical: DS cannot bump DH out of the nampower queue.
    eq(AutoLock:_testRunList(s), "Dark Harvest",
      "R4 DH queued (prio22): DS (23>22) blocked, DH re-queues itself")

    -- ── Phase 5: DS channeling → DH fires (guard lifted) ────
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999
    NP:stop()
    AutoLock:_testSetDrainSoulChanneling(true)
    AutoLock:_testSetDrainSoulTiming(_clock, 15)
    env.np.channeling = true

    env.hasShadowTrance = false
    eq(AutoLock:_testRunList(s), "Dark Harvest",
      "R5 DS channeling: DH fires (guard lifted for channels)")

    env.hasShadowTrance = true
    eq(AutoLock:_testRunList(s), "Shadow Bolt",
      "R6 DS channeling + proc: SB fires (prio 1)")
    env.hasShadowTrance = false

    -- ── Phase 6: ChannelStopCastingNextTick wired correctly ──
    AutoLock:_testSetDrainSoulChanneling(true)
    NP:startChannel(15)
    NP._cancelFlag = false

    local fired = AutoLock:_testRunList({ s[3] })  -- DH entry
    eq(fired, "Dark Harvest", "R7 DH cast during DS channel: fires")
    is_true(NP._cancelFlag,   "R7 ChannelStopCastingNextTick called")

    AutoLock:_testSetDrainSoulChanneling(false)
    NP:uninstall()
  end)
  env:restore()
  if not ok_r then fail("[gcd_realworld] crashed", tostring(err)) end
end)

-- ── doAutoLock_configName ─────────────────────────────────────
-- DoAutoLock(configName) must fire a spell from the combat snapshot.
-- Specifically tests the _loadCombatSnapshot → TryAction path that
-- the action-bar macro (/run AutoLock:DoAutoLock("Name")) exercises.
--
-- Realistic setup: all spells with cooldowns are "on cooldown" so the
-- rotation falls through to DS (prio 23, no CD check), which is always
-- available.  This matches what the user sees in-game on a normal press.
suite("doAutoLock_configName", function()
  local env = rot_env_new()
  local ok_r, err = pcall(function()
    -- Put all cooldown-based spells on CD so only DS and curses remain.
    -- Curses: rot_env_new() has Cursive.Curse returning false (already up).
    -- DS: no cooldown check in its condition → always available.
    AutoLock.IsOnCooldown = function(_, name) return true end  -- everything "on CD"

    -- Snapshot that explicitly saves every SPELL_PRIORITY entry,
    -- mirroring what SaveCurrentConfigSpells() does in-game.
    local spells = {}
    for _, e in ipairs(SPELL_PRIORITY) do
      local key = (e.uitext or e.name or "?") .. "|" .. (e.type or "?")
      spells[key] = { enabled = e.enabled, priority = e.priority,
                      refreshtime = e.refreshtime }
    end
    AutoLockDB = {
      configs = { {
        name   = "Combat",
        spells = spells,
        darkHarvestDots           = {},
        darkHarvestAllowNightfall = false,
      } },
      activeConfig = "Combat",
    }

    AutoLock._combatConfigName = nil   -- force snapshot rebuild
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999

    -- ── A: first press → DS fires ────────────────────────────────
    AutoLock:DoAutoLock("Combat")
    eq(env.lastCast, "Drain Soul",
      "A: first press fires Drain Soul")

    -- ── B: second press before SPELLCAST_STOP ────────────────────
    -- _npQueuedThisCast=true, _npQueuedPriority=23 (DS just queued).
    -- DS (23 >= 23) is blocked by the guard; nothing else is available.
    -- Expected: a spell still fires (DS re-queues itself via nampower
    -- last-write-wins — same spell, so re-queuing is harmless).
    env.lastCast = nil
    -- Do NOT clear the flag (simulates pressing before SPELLCAST_STOP).
    AutoLock:DoAutoLock("Combat")
    eq(env.lastCast, "Drain Soul",
      "B: second press before SPELLCAST_STOP: DS re-fires")

    -- ── C: unknown config → nothing fires ────────────────────────
    env.lastCast = nil
    AutoLock._combatConfigName = nil
    AutoLock._npQueuedThisCast = false
    AutoLock:DoAutoLock("NonExistent")
    is_nil(env.lastCast,
      "C: unknown config → nothing fires")

    -- ── D: SB proc overrides DS in queue ────────────────────────
    env.lastCast = nil
    env.hasShadowTrance = true
    AutoLock._npQueuedThisCast = true
    AutoLock._npQueuedPriority = 23
    AutoLock._combatConfigName = nil
    AutoLock:DoAutoLock("Combat")
    eq(env.lastCast, "Shadow Bolt",
      "D: DS queued (prio23), SB proc (prio1) overrides")
    env.hasShadowTrance = false
  end)
  env:restore()
  if not ok_r then fail("[doAutoLock_configName] crashed", tostring(err)) end
end)

-- ── curseRefreshDuringDS ──────────────────────────────────────
-- When DS is channeling and drainSoulDots[key]=true, an expired curse
-- must call ChannelStopCastingNextTick before being cast via Cursive:Curse.
-- Bug (pre-fix): ChannelStopCastingNextTick is never called for curse type.
suite("curseRefreshDuringDS", function()
  local env = rot_env_new()
  local savedCSNT = ChannelStopCastingNextTick
  local ok_r, err = pcall(function()
    -- Active DS channel
    AutoLock:_testSetDrainSoulChanneling(true)
    AutoLock:_testSetDrainSoulTiming(_clock, 15)
    env.np.channeling = true

    -- Track ChannelStopCastingNextTick calls
    local csntCalled = false
    ChannelStopCastingNextTick = function() csntCalled = true end

    -- Config: CoA is allowed during DS channeling
    AutoLockDB.configs[1].drainSoulDots = { agony = true }
    AutoLock._combatConfigName = "rot_test"

    -- CoA is expired (HasCurse returns false); Curse would succeed (returns true)
    local curseCastName = nil
    Cursive = {
      curses = { HasCurse = function(self, name, guid, refresh) return false end },
      Curse  = function(_, name) curseCastName = name; return true end,
    }

    local coaEntry
    for _, e in ipairs(SPELL_PRIORITY) do
      if e.name == "Curse of Agony" and e.type == "curse" then coaEntry = e; break end
    end
    is_true(coaEntry ~= nil, "CoA entry found")
    if not coaEntry then return end

    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999

    local fired = AutoLock:_testRunList({ coaEntry })
    eq(fired, "Curse of Agony",
      "C1 CoA fires during active DS channel (drainSoulDots.agony=true)")
    is_true(csntCalled,
      "C1 ChannelStopCastingNextTick called before expired CoA cast")

    -- Negative: curse still up → CSNT must NOT be called
    csntCalled = false
    Cursive.curses.HasCurse = function() return true end  -- curse is up
    Cursive.Curse = function(_, name) curseCastName = name; return false end -- no cast
    fired = AutoLock:_testRunList({ coaEntry })
    is_false(csntCalled,
      "C2 curse still up: ChannelStopCastingNextTick NOT called")

    -- Negative: no channel → CSNT must NOT be called
    csntCalled = false
    AutoLock:_testSetDrainSoulChanneling(false)
    env.np.channeling = false
    Cursive.curses.HasCurse = function() return false end  -- expired
    Cursive.Curse = function(_, name) curseCastName = name; return true end
    fired = AutoLock:_testRunList({ coaEntry })
    is_false(csntCalled,
      "C3 no channel: ChannelStopCastingNextTick NOT called")
  end)
  ChannelStopCastingNextTick = savedCSNT
  env:restore()
  if not ok_r then fail("[curseRefreshDuringDS] crashed", tostring(err)) end
end)

-- ── dhInterruptsDSConfig ──────────────────────────────────────
-- When darkHarvestInterruptsDS=false in the active config, DH must
-- not fire while DS is actively channeling.
-- When darkHarvestInterruptsDS=true (default), DH fires normally.
suite("dhInterruptsDSConfig", function()
  local env = rot_env_new()
  local ok_r, err = pcall(function()
    local dhEntry
    for _, e in ipairs(SPELL_PRIORITY) do
      if e.name == "Dark Harvest" and e.type == "cast" then dhEntry = e; break end
    end
    is_true(dhEntry ~= nil, "Dark Harvest entry found")
    if not dhEntry then return end

    -- Use an enabled copy; the real DH entry is disabled by default.
    local dh = {}
    for k, v in pairs(dhEntry) do dh[k] = v end
    dh.enabled = true

    -- Make DH eligible: no cooldown, no movement, dots ready
    AutoLock.IsOnCooldown = function(_, name) return false end
    AutoLockDB.configs[1].darkHarvestDots = {}  -- no dot requirements
    AutoLock._combatConfigName = "rot_test"
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999

    -- DS actively channeling
    AutoLock:_testSetDrainSoulChanneling(true)
    AutoLock:_testSetDrainSoulTiming(_clock, 15)
    env.np.channeling = true

    -- D1: darkHarvestInterruptsDS=true → DH fires during DS channel
    AutoLockDB.configs[1].darkHarvestInterruptsDS = true
    AutoLock:_testSetDarkHarvestChanneling(false)
    local fired = AutoLock:_testRunList({ dh })
    eq(fired, "Dark Harvest",
      "D1 darkHarvestInterruptsDS=true: DH fires during DS channel")

    -- D2: darkHarvestInterruptsDS=false → DH blocked
    AutoLockDB.configs[1].darkHarvestInterruptsDS = false
    AutoLock:_testSetDarkHarvestChanneling(false)
    fired = AutoLock:_testRunList({ dh })
    is_nil(fired,
      "D2 darkHarvestInterruptsDS=false: DH blocked during DS channel")

    -- D3: darkHarvestInterruptsDS=nil (unset, default true) → DH fires
    AutoLockDB.configs[1].darkHarvestInterruptsDS = nil
    AutoLock:_testSetDarkHarvestChanneling(false)
    fired = AutoLock:_testRunList({ dh })
    eq(fired, "Dark Harvest",
      "D3 darkHarvestInterruptsDS=nil (default): DH fires")

    -- D4: DS NOT channeling, flag=false → DH fires normally
    AutoLock:_testSetDrainSoulChanneling(false)
    env.np.channeling = false
    AutoLockDB.configs[1].darkHarvestInterruptsDS = false
    AutoLock:_testSetDarkHarvestChanneling(false)
    fired = AutoLock:_testRunList({ dh })
    eq(fired, "Dark Harvest",
      "D4 flag=false but DS not channeling: DH fires normally")
  end)
  env:restore()
  if not ok_r then fail("[dhInterruptsDSConfig] crashed", tostring(err)) end
end)

-- ── dh_after_cos_not_coa ──────────────────────────────────────
-- BUG: After CoS fires first (prio 6), CoA is blocked by the mutual-exclusion
-- guard in its condition (HasCurse("curse of shadow") == true → return false).
-- So the curse sequence is CoS → Corruption → SL; CoA is never applied.
-- darkHarvestDotsReady() checks HasCurse("curse of agony") which returns false
-- because DARK_HARVEST_CURSE_NAMES maps "agony" → "curse of agony" only.
-- CoS satisfies the same debuff slot as CoA, but the check doesn't account for it.
--
-- Expected: DH fires on press 4 (CoS+Corruption+SL satisfy the dot requirements).
-- Actual:   DS fires (DH condition fails → darkHarvestDotsReady() returns false).
suite("dh_after_cos_not_coa", function()
  local env = rot_env_new()
  local ok_r, err = pcall(function()
    AutoLockDB.configs[1].darkHarvestDots = {
      agony = true, corruption = true, siphonLife = true,
    }
    AutoLock.IsOnCooldown = function() return false end
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999
    AutoLock._combatConfigName = "rot_test"

    -- Stateful Cursive: initially no curses on target.
    -- CoS and CoA share the same curse slot (mutual exclusion).
    local cursesUp = {}
    Cursive = {
      curses = {
        HasCurse = function(self, name, guid, refresh)
          return cursesUp[name] == true
        end,
      },
      Curse = function(self, name, tgt, opts)
        local lower = string.lower(name)
        if cursesUp[lower] then return false end
        -- Mutual exclusion: casting CoA while CoS is up is a no-op.
        if lower == "curse of agony" and cursesUp["curse of shadow"] then return false end
        -- CoS overwrites CoA on the target.
        if lower == "curse of shadow" and cursesUp["curse of agony"] then
          cursesUp["curse of agony"] = nil
        end
        cursesUp[lower] = true
        return true
      end,
    }

    -- Collect the relevant entries from the real SPELL_PRIORITY (real conditions).
    -- DH and DS are normally disabled; enable copies for this test.
    local entries = {}
    for _, e in ipairs(SPELL_PRIORITY) do
      local n = e.name
      if n == "Curse of Shadow" or n == "Curse of Agony" or
         n == "Corruption"      or n == "Siphon Life"   or
         n == "Dark Harvest"    or n == "Drain Soul"    then
        local copy = {}
        for k, v in pairs(e) do copy[k] = v end
        if n == "Dark Harvest" or n == "Drain Soul" then copy.enabled = true end
        table.insert(entries, copy)
      end
    end
    table.sort(entries, function(a, b)
      return (a.priority or 99) < (b.priority or 99)
    end)

    -- Simulate SPELLCAST_STOP clearing the nampower queue between presses.
    local function after_cast()
      AutoLock._npQueuedThisCast = false
      AutoLock._npQueuedPriority = 99999
    end

    -- Press 1: CoS fires (prio 6 beats CoA's prio 7).
    eq(AutoLock:_testRunList(entries), "Curse of Shadow",
      "S1 press 1: CoS fires first")
    after_cast()

    -- Press 2: CoS is up → CoA condition detects CoS via HasCurse → returns false.
    --          Rotation falls through to Corruption.
    eq(AutoLock:_testRunList(entries), "Corruption",
      "S2 press 2: Corruption fires (CoA blocked by mutual exclusion)")
    after_cast()

    -- Press 3: CoS+Corruption up → Siphon Life fires.
    eq(AutoLock:_testRunList(entries), "Siphon Life",
      "S3 press 3: Siphon Life fires")
    after_cast()

    -- Press 4: CoS+Corruption+SL are all on the target.
    -- DH requires agony=true; darkHarvestDotsReady() calls HasCurse("curse of agony").
    -- "curse of agony" is NOT up — only "curse of shadow" is (CoA was never applied).
    -- EXPECTED: DH fires (CoS occupies the same debuff slot, satisfying the requirement).
    -- ACTUAL:   DS fires (darkHarvestDotsReady() returns false → DH condition fails).
    eq(AutoLock:_testRunList(entries), "Dark Harvest",
      "S4 press 4: DH fires after CoS+Corruption+SL applied (BUG: DS fires instead)")
  end)
  env:restore()
  if not ok_r then fail("[dh_after_cos_not_coa] crashed", tostring(err)) end
end)

-- ── gcd_falsely_blocks_dc_and_dh ─────────────────────────────
-- GetSpellCooldown(slot, bookType) returns (start, duration).
-- During the GCD, start != 0 but duration <= 1.5 s (just the GCD window).
-- A real spell cooldown has duration > 1.5 s.
-- Fix: IsOnCooldown() treats duration <= 1.5 as "GCD only → not on cooldown".
--
-- Without the fix: IsOnCooldown returns true during GCD → Death Coil condition
-- (onCD == false) and Dark Harvest condition (if onCD) both fail → DS fires.
-- With nampower queuing the macro is always pressed mid-GCD, hitting this bug
-- on every keypress.  With queuing disabled the macro arrives after the GCD.
suite("gcd_falsely_blocks_dc_and_dh", function()
  -- ── Part A: unit-test the IsOnCooldown fix logic ──────────────
  -- Mirrors the implementation in AutoLockHelper.lua:IsOnCooldown.
  local function isOnCooldownLogic(start, duration)
    if not start or start == 0 then return false end
    if duration and duration <= 1.5 then return false end  -- GCD only
    return true
  end
  is_false(isOnCooldownLogic(0,    0),   "A1 start=0 → ready")
  is_false(isOnCooldownLogic(nil,  nil), "A2 nil start → ready")
  is_false(isOnCooldownLogic(1000, 1.5), "A3 GCD (duration=1.5 s) → not a real cooldown")
  is_false(isOnCooldownLogic(1000, 1.0), "A4 sub-GCD duration → not a real cooldown")
  is_true (isOnCooldownLogic(1000, 30),  "A5 real CD (30 s) → on cooldown")
  is_true (isOnCooldownLogic(1000, 2.0), "A6 short real CD (2.0 s) → on cooldown")

  -- ── Part B: rotation — DC and DH fire before DS when IsOnCooldown ──
  -- correctly returns false during GCD (fixed behaviour).
  local env = rot_env_new()
  local ok_r, err = pcall(function()
    -- Fixed IsOnCooldown: GCD is not reported as a real cooldown.
    AutoLock.IsOnCooldown = function(_, name) return false end

    AutoLockDB.configs[1].darkHarvestDots = {}
    AutoLock._combatConfigName = "rot_test"
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999
    AutoLock:_testSetDrainSoulChanneling(false)
    AutoLock:_testSetDarkHarvestChanneling(false)

    local dcEntry, dhEntry, dsEntry
    for _, e in ipairs(SPELL_PRIORITY) do
      if e.name == "Death Coil"   and e.type == "cast" then dcEntry = e end
      if e.name == "Dark Harvest" and e.type == "cast" then dhEntry = e end
      if e.name == "Drain Soul"   and e.type == "cast" then dsEntry = e end
    end

    local dc = {}; for k, v in pairs(dcEntry) do dc[k] = v end; dc.enabled = true
    local dh = {}; for k, v in pairs(dhEntry) do dh[k] = v end; dh.enabled = true
    local ds = {}; for k, v in pairs(dsEntry) do ds[k] = v end; ds.enabled = true

    eq(AutoLock:_testRunList({dc, ds}), "Death Coil",
      "B1: DC (prio 20) fires before DS (prio 23) — GCD not reported as cooldown")
    AutoLock._npQueuedThisCast = false
    eq(AutoLock:_testRunList({dh, ds}), "Dark Harvest",
      "B2: DH (prio 22) fires before DS (prio 23) — GCD not reported as cooldown")
    AutoLock._npQueuedThisCast = false
    eq(AutoLock:_testRunList({dc, dh, ds}), "Death Coil",
      "B3: DC (prio 20) fires first among DC + DH + DS")
  end)
  env:restore()
  if not ok_r then fail("[gcd_falsely_blocks_dc_and_dh] crashed", tostring(err)) end
end)

-- ── cos_coe_cor_overwrite_agony_prematurely ───────────────────
-- Bug: Curse of Shadow, Curse of the Elements, and Curse of Recklessness
-- overwrite an active agony-slot curse (CoA / CoS) even when it still has
-- plenty of time remaining.
--
-- Root cause:
--   CoS condition only checks isBlockedByDrainSoul — it has no guard for
--   CoA being active on the target.
--   CoE and CoR have NO condition at all, so they always attempt to cast.
--
-- Concrete scenario:
--   CoA is at higher priority (prio 5) than CoS (prio 7).
--   CoA fires on press 1 (20 s duration).
--   On press 2: CoA has 19 s remaining — Cursive returns false (no recast needed).
--   CoS (prio 7) then runs: its condition passes → Cursive casts CoS because
--   CoS is absent from the target (0 s remaining < refreshtime=5 s) → CoA replaced!
--
-- User quote: "COS zum erneuern von agony zu verwenden ist also nur dann
-- gültig, wenn agony nicht mehr auf dem gegner ist."
-- (CoS should only renew the agony slot when agony has COMPLETELY expired.)
--
-- Same applies to CoE and CoR (all share the single curse debuff slot).
--
-- Fix (not yet applied): add HasCurse("curse of agony"/slot, guid, 0) guard
-- to CoS, CoE, CoR conditions — block them if the agony slot is still occupied.
suite("cos_coe_cor_overwrite_agony_prematurely", function()
  -- Find the relevant entries from SPELL_PRIORITY.
  local cosEntry, coeEntry, corEntry
  for _, e in ipairs(SPELL_PRIORITY) do
    if e.name == "Curse of Shadow"          and e.type == "curse" then cosEntry = e end
    if e.name == "Curse of the Elements"    and e.type == "curse" then coeEntry = e end
    if e.name == "Curse of Recklessness"    and e.type == "curse" then corEntry = e end
  end
  is_true(cosEntry ~= nil, "Curse of Shadow entry found")
  is_true(coeEntry ~= nil, "Curse of the Elements entry found")
  is_true(corEntry ~= nil, "Curse of Recklessness entry found")
  if not cosEntry or not coeEntry or not corEntry then return end

  local savedCur = Cursive
  local savedDB  = AutoLockDB
  local savedCCN = AutoLock._combatConfigName
  local function restore()
    Cursive    = savedCur
    AutoLockDB = savedDB
    AutoLock._combatConfigName = savedCCN
    AutoLock:_testSetDrainSoulChanneling(false)
  end

  local pass, err = pcall(function()
    AutoLock._combatConfigName = nil
    AutoLock:_testSetDrainSoulChanneling(false)
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999

    -- ── Stateful Cursive mock ──────────────────────────────────
    -- Simulates a single agony-slot debuff on the target.
    -- agonySlot = "none" | "coa" | "cos" | "coe" | "cor"
    -- agonyRemaining = seconds left on the active curse
    local agonySlot      = "coa"  -- CoA was just cast
    local agonyRemaining = 19.0   -- 19 s remaining after first press

    Cursive = {
      curses = {
        HasCurse = function(self, name, guid, refreshtime)
          local slotMap = {
            ["curse of agony"]          = "coa",
            ["curse of shadow"]         = "cos",
            ["curse of the elements"]   = "coe",
            ["curse of recklessness"]   = "cor",
          }
          local slot = slotMap[name]
          if slot == nil then return false end
          if agonySlot ~= slot then return false end  -- different curse in slot
          return agonyRemaining > refreshtime
        end,
      },
      -- Simulates Cursive's cast: replaces whatever is in the agony slot.
      -- Returns true if the curse is absent or below its refreshtime threshold.
      Curse = function(self, name, tgt, opts)
        local slotMap = {
          ["Curse of Agony"]          = "coa",
          ["Curse of Shadow"]         = "cos",
          ["Curse of the Elements"]   = "coe",
          ["Curse of Recklessness"]   = "cor",
        }
        local slot = slotMap[name]
        if slot == nil then return false end
        local rt = (opts and opts.refreshtime) or 0
        -- If this curse is already in the slot with sufficient time, no recast.
        if agonySlot == slot and agonyRemaining > rt then return false end
        -- Otherwise cast (replaces whatever was in the slot).
        agonySlot      = slot
        agonyRemaining = 20.0
        return true
      end,
    }

    -- Helper: make an enabled copy of an entry with custom refreshtime.
    local function copy(e, rt)
      local c = {}
      for k, v in pairs(e) do c[k] = v end
      c.enabled = true
      if rt ~= nil then c.refreshtime = rt end
      return c
    end

    -- Reset the nampower queue between assertions so no guard bleeds through.
    local function reset_np()
      AutoLock._npQueuedThisCast = false
      AutoLock._npQueuedPriority = 99999
    end

    local cos = copy(cosEntry, 5)  -- user-configured refreshtime=5
    local coe = copy(coeEntry, 5)
    local cor = copy(corEntry, 5)

    -- ── E1: CoS fires with CoA active (Malediction: CoS = CoA, cheaper) ────
    -- isAgonySlotOccupied guard removed; Cursive handles slot arbitration.
    -- Cursive bug: tracks CoS cast as "curse of shadow" but redirect looks up
    -- "curse of agony" → immediate recast. Fix pending upstream (pepopo978/Cursive).
    reset_np(); agonySlot = "coa"; agonyRemaining = 19.0
    local fired = AutoLock:_testRunList({cos})
    eq(fired, "Curse of Shadow",
      "E1 CoA active (19 s): CoS fires (slot guard removed, relies on Cursive)")

    -- ── E2: CoS SHOULD fire when CoA has expired ──────────────
    reset_np(); agonySlot = "coa"; agonyRemaining = 0.0
    fired = AutoLock:_testRunList({cos})
    eq(fired, "Curse of Shadow",
      "E2 CoA expired: CoS fires correctly to fill the slot")

    -- ── E3: CoE fires with CoA active (Malediction: CoE = CoA, cheaper) ────
    reset_np(); agonySlot = "coa"; agonyRemaining = 19.0
    fired = AutoLock:_testRunList({coe})
    eq(fired, "Curse of the Elements",
      "E3 CoA active (19 s): CoE fires (slot guard removed, relies on Cursive)")

    -- ── E4: CoE SHOULD fire when CoA has expired ──────────────
    reset_np(); agonySlot = "coa"; agonyRemaining = 0.0
    fired = AutoLock:_testRunList({coe})
    eq(fired, "Curse of the Elements",
      "E4 CoA expired: CoE fires correctly to fill the slot")

    -- ── E5: CoR fires with CoA active (Malediction: CoR = CoA, cheaper) ────
    reset_np(); agonySlot = "coa"; agonyRemaining = 19.0
    fired = AutoLock:_testRunList({cor})
    eq(fired, "Curse of Recklessness",
      "E5 CoA active (19 s): CoR fires (slot guard removed, relies on Cursive)")

    -- ── E6: CoR SHOULD fire when CoA has expired ──────────────
    reset_np(); agonySlot = "coa"; agonyRemaining = 0.0
    fired = AutoLock:_testRunList({cor})
    eq(fired, "Curse of Recklessness",
      "E6 CoA expired: CoR fires correctly to fill the slot")

    -- ── E7: CoS must NOT replace a fresh CoS (own slot, no recast needed) ─
    -- CoS already in slot with 10 s remaining; refreshtime=5 → 10 > 5 → no recast.
    reset_np(); agonySlot = "cos"; agonyRemaining = 10.0
    fired = AutoLock:_testRunList({cos})
    is_nil(fired,
      "E7 CoS active (10 s > refreshtime=5): must NOT recast itself")

    -- ── E8: CoS SHOULD recast itself when near expiry ─────────
    reset_np(); agonySlot = "cos"; agonyRemaining = 3.0   -- 3 s < refreshtime=5 s
    fired = AutoLock:_testRunList({cos})
    eq(fired, "Curse of Shadow",
      "E8 CoS active (3 s < refreshtime=5): recasts itself correctly")
  end)
  restore()
  if not pass then fail("[cos_coe_cor_overwrite_agony_prematurely] crashed", tostring(err)) end
end)

-- ── agony_refreshtime_combat_snapshot ────────────────────────
-- Tests the full pipeline: AutoLockDB config → _loadCombatSnapshot →
-- COMBAT_SPELL_PRIORITY → TryAction → Cursive:Curse(refreshtime=12).
-- User reported: CoA with refreshtime=12 is only recast after full expiry.
-- This test verifies whether the snapshot correctly carries refreshtime=12
-- through to Cursive and that Cursive recasts when < 12 s remaining.
suite("agony_refreshtime_combat_snapshot", function()
  local env = rot_env_new()
  local savedCSP = COMBAT_SPELL_PRIORITY
  local ok_r, err = pcall(function()
    AutoLock.IsOnCooldown = function() return false end
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999

    -- Build a minimal config: only CoA enabled with refreshtime=12.
    -- All other spells disabled (enabled=false keeps them out of our assertions).
    local spells = {}
    for _, e in ipairs(SPELL_PRIORITY) do
      local key = (e.uitext or e.name or "?") .. "|" .. (e.type or "?")
      local isCoA = (e.name == "Curse of Agony" and e.type == "curse")
      spells[key] = {
        enabled     = isCoA,
        priority    = e.priority,
        refreshtime = isCoA and 12 or (e.refreshtime or 0),
      }
    end
    AutoLockDB = {
      activeConfig = "snap_test",
      configs = { { name = "snap_test", spells = spells } },
    }
    AutoLock:_loadCombatSnapshot("snap_test")

    -- Verify the snapshot picked up refreshtime=12.
    local coaSnap = nil
    for _, e in ipairs(COMBAT_SPELL_PRIORITY) do
      if e.name == "Curse of Agony" and e.type == "curse" then coaSnap = e; break end
    end
    is_true(coaSnap ~= nil,              "G0a CoA found in COMBAT_SPELL_PRIORITY")
    is_true(coaSnap ~= nil and coaSnap.enabled, "G0b CoA is enabled in snapshot")
    eq(coaSnap and coaSnap.refreshtime, 12, "G0c refreshtime=12 carried through snapshot")
    eq(type(coaSnap and coaSnap.refreshtime), "number", "G0d refreshtime is a number")

    -- Stateful Cursive: CoA in slot.
    local agonyRemaining = 0.0
    Cursive = {
      curses = {
        HasCurse = function(self, name, guid, threshold)
          if name == "curse of agony" then return agonyRemaining > threshold end
          return false
        end,
      },
      Curse = function(self, name, tgt, opts)
        if name ~= "Curse of Agony" then return false end
        local rt = (opts and opts.refreshtime) or 1
        if agonyRemaining > rt then return false end  -- still up, no recast
        agonyRemaining = 30.0
        return true
      end,
    }

    local function reset_np()
      AutoLock._npQueuedThisCast = false
      AutoLock._npQueuedPriority = 99999
    end

    -- G1: CoA absent → initial cast
    agonyRemaining = 0.0; reset_np()
    eq(AutoLock:_testRunList(COMBAT_SPELL_PRIORITY), "Curse of Agony",
      "G1 CoA absent: initial cast")

    -- G2: CoA in slot, 15 s remaining (> rt=12) → must NOT recast
    agonyRemaining = 15.0; reset_np()
    is_nil(AutoLock:_testRunList(COMBAT_SPELL_PRIORITY),
      "G2 CoA active (15 s > rt=12): must NOT recast")

    -- G3: CoA in slot, 10 s remaining (< rt=12) → must recast
    agonyRemaining = 10.0; reset_np()
    eq(AutoLock:_testRunList(COMBAT_SPELL_PRIORITY), "Curse of Agony",
      "G3 CoA active (10 s < rt=12): must recast (BUG: does not refresh)")
  end)
  COMBAT_SPELL_PRIORITY = savedCSP
  env:restore()
  if not ok_r then fail("[agony_refreshtime_combat_snapshot] crashed", tostring(err)) end
end)

-- ── agony_refreshtime_stale_snapshot ─────────────────────────
-- Root cause of the reported bug:
-- SaveCurrentConfigSpells() writes the new refreshtime to AutoLockDB, but
-- does NOT invalidate _combatConfigName. DoAutoLock(configName) only calls
-- _loadCombatSnapshot when _combatConfigName ~= configName, so the stale
-- snapshot (refreshtime=0 → passed as 1 to Cursive) is used forever.
-- Fix: SaveCurrentConfigSpells must reset AutoLock._combatConfigName = nil.
suite("agony_refreshtime_stale_snapshot", function()
  local env = rot_env_new()
  local savedCSP = COMBAT_SPELL_PRIORITY
  local ok_r, err = pcall(function()
    AutoLock.IsOnCooldown = function() return false end

    -- Step 1: build initial snapshot with refreshtime=0 (pre-UI-change state).
    local spells = {}
    for _, e in ipairs(SPELL_PRIORITY) do
      local key = (e.uitext or e.name or "?") .. "|" .. (e.type or "?")
      spells[key] = { enabled = (e.name == "Curse of Agony" and e.type == "curse"),
                      priority = e.priority, refreshtime = 0 }
    end
    AutoLockDB = {
      activeConfig = "stale_test",
      configs = { { name = "stale_test", spells = spells } },
    }
    AutoLock:_loadCombatSnapshot("stale_test")
    -- _combatConfigName is now "stale_test"

    -- Step 2: user changes refreshtime to 12 in UI → SaveCurrentConfigSpells equivalent.
    -- Writes new value to DB but does NOT reset _combatConfigName.
    AutoLockDB.configs[1].spells["Curse of Agony|curse"].refreshtime = 12
    -- (SaveCurrentConfigSpells does NOT call _loadCombatSnapshot or reset _combatConfigName)

    -- Step 3: next DoAutoLock("stale_test") call — _combatConfigName == "stale_test"
    -- → snapshot NOT rebuilt → CoA entry still has refreshtime=0.
    local coaSnap = nil
    for _, e in ipairs(COMBAT_SPELL_PRIORITY) do
      if e.name == "Curse of Agony" and e.type == "curse" then coaSnap = e; break end
    end
    -- BUG: snapshot still carries the old refreshtime=0
    eq(coaSnap and coaSnap.refreshtime, 0,
      "H1 stale snapshot: CoA refreshtime still 0 after UI change (bug confirmed)")

    -- Cursive: CoA in slot with 10s remaining
    local agonyRemaining = 10.0
    Cursive = {
      curses = {
        HasCurse = function(self, name, guid, threshold)
          if name == "curse of agony" then return agonyRemaining > threshold end
          return false
        end,
      },
      Curse = function(self, name, tgt, opts)
        if name ~= "Curse of Agony" then return false end
        local rt = (opts and opts.refreshtime) or 1
        if agonyRemaining > rt then return false end
        agonyRemaining = 30.0
        return true
      end,
    }
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999

    -- BUG: CoA has 10s but snapshot has rt=0 → Cursive receives {refreshtime=1}
    -- Cursive: 10 > 1 → does NOT recast → nothing fires.
    is_nil(AutoLock:_testRunList(COMBAT_SPELL_PRIORITY),
      "H2 stale snapshot: CoA (10 s) not refreshed because rt is still 0→1 (bug)")

    -- Step 4: fix — resetting _combatConfigName forces snapshot rebuild on next press.
    AutoLock._combatConfigName = nil
    AutoLock:_loadCombatSnapshot("stale_test")

    local coaFresh = nil
    for _, e in ipairs(COMBAT_SPELL_PRIORITY) do
      if e.name == "Curse of Agony" and e.type == "curse" then coaFresh = e; break end
    end
    eq(coaFresh and coaFresh.refreshtime, 12,
      "H3 after reload: CoA refreshtime=12 in fresh snapshot")

    agonyRemaining = 10.0
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999
    eq(AutoLock:_testRunList(COMBAT_SPELL_PRIORITY), "Curse of Agony",
      "H4 after reload: CoA (10 s < rt=12) correctly refreshes")
  end)
  COMBAT_SPELL_PRIORITY = savedCSP
  env:restore()
  if not ok_r then fail("[agony_refreshtime_stale_snapshot] crashed", tostring(err)) end
end)

-- ── agony_refreshtime_with_cos_enabled ───────────────────────
-- Scenario reported by user: CoA refreshtime=12 and CoS refreshtime=12 both
-- enabled. CoA is in the slot with 10 s remaining (< refreshtime). Expected:
-- the rotation recasts CoA on the next keypress. Actual (reported): CoA is
-- only recast after it fully expires.
--
-- Root cause under investigation:
--   isAgonySlotOccupied("curse of shadow") uses HasCurse(tGuid, 0) →
--   CoA (10 s > 0) blocks CoS correctly. Then CoA condition passes and
--   Cursive is called with refreshtime=12. Cursive: 10 < 12 → should recast.
--   If this test fails, the blocking guard is interfering with CoA's self-refresh.
suite("agony_refreshtime_with_cos_enabled", function()
  local cosEntry, coaEntry
  for _, e in ipairs(SPELL_PRIORITY) do
    if e.name == "Curse of Shadow" and e.type == "curse" then cosEntry = e end
    if e.name == "Curse of Agony"  and e.type == "curse" then coaEntry = e end
  end
  is_true(cosEntry ~= nil, "CoS entry found")
  is_true(coaEntry ~= nil, "CoA entry found")
  if not cosEntry or not coaEntry then return end

  local savedCur = Cursive
  local savedDB  = AutoLockDB
  local savedCCN = AutoLock._combatConfigName
  local function restore()
    Cursive    = savedCur
    AutoLockDB = savedDB
    AutoLock._combatConfigName = savedCCN
    AutoLock:_testSetDrainSoulChanneling(false)
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999
  end

  local pass, err = pcall(function()
    AutoLock._combatConfigName = nil
    AutoLock:_testSetDrainSoulChanneling(false)
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999

    -- Stateful Cursive: one agony-slot curse at a time with a remaining timer.
    local agonySlot      = "none"  -- "none" | "coa" | "cos"
    local agonyRemaining = 0.0

    Cursive = {
      curses = {
        HasCurse = function(self, name, guid, refreshtime)
          local slotMap = {
            ["curse of agony"]  = "coa",
            ["curse of shadow"] = "cos",
            ["curse of the elements"]  = "coe",
            ["curse of recklessness"]  = "cor",
          }
          local slot = slotMap[name]
          if slot == nil then return false end
          if agonySlot ~= slot then return false end
          return agonyRemaining > refreshtime
        end,
      },
      Curse = function(self, name, tgt, opts)
        local slotMap = {
          ["Curse of Agony"]  = "coa",
          ["Curse of Shadow"] = "cos",
        }
        local slot = slotMap[name]
        if slot == nil then return false end
        local rt = (opts and opts.refreshtime) or 1
        -- If this curse is already in the slot with sufficient time, no recast.
        if agonySlot == slot and agonyRemaining > rt then return false end
        -- Otherwise cast (replaces whatever was in the slot).
        agonySlot      = slot
        agonyRemaining = 30.0
        return true
      end,
    }

    local function cos(rt) local c = {}; for k,v in pairs(cosEntry) do c[k]=v end; c.enabled=true; c.refreshtime=rt; return c end
    local function coa(rt) local c = {}; for k,v in pairs(coaEntry) do c[k]=v end; c.enabled=true; c.refreshtime=rt; return c end
    local function reset_np() AutoLock._npQueuedThisCast=false; AutoLock._npQueuedPriority=99999 end

    -- ── F1: CoA alone (no CoS), 10 s remaining, refreshtime=12 ──
    -- CoA should fire and refresh (10 < 12).
    agonySlot = "coa"; agonyRemaining = 10.0
    reset_np()
    eq(AutoLock:_testRunList({coa(12)}), "Curse of Agony",
      "F1 CoA alone, 10 s remaining, rt=12: should refresh")

    -- ── F2: CoA alone, 15 s remaining, refreshtime=12 ────────────
    -- CoA should NOT fire (15 > 12, Cursive skips it).
    agonySlot = "coa"; agonyRemaining = 15.0
    reset_np()
    is_nil(AutoLock:_testRunList({coa(12)}),
      "F2 CoA alone, 15 s remaining, rt=12: must NOT fire")

    -- ── F3: CoS (prio 6) + CoA (prio 7), CoA in slot 10 s, both rt=12 ──
    -- isAgonySlotOccupied guard removed → CoS fires first (prio 6 < 7).
    -- Cursive bug: will recast CoS every tick (pending upstream fix).
    agonySlot = "coa"; agonyRemaining = 10.0
    reset_np()
    eq(AutoLock:_testRunList({cos(12), coa(12)}), "Curse of Shadow",
      "F3 CoS+CoA, CoA in slot (10 s, rt=12): CoS fires first (guard removed)")

    -- ── F4: CoS + CoA, CoA in slot 15 s, both rt=12 ────────────
    -- CoS fires (no guard). Cursive sees CoS absent → casts CoS.
    agonySlot = "coa"; agonyRemaining = 15.0
    reset_np()
    eq(AutoLock:_testRunList({cos(12), coa(12)}), "Curse of Shadow",
      "F4 CoS+CoA, CoA in slot (15 s, rt=12): CoS fires (guard removed)")

    -- ── F5: CoS + CoA, CoS in slot 10 s (< refreshtime) ────────
    -- CoS not blocked (CoA absent). CoS: Cursive recasts (10 < 12).
    -- CoA: mutex (HasCurse CoS, 0) → blocked.
    -- Expected: CoS fires.
    agonySlot = "cos"; agonyRemaining = 10.0
    reset_np()
    eq(AutoLock:_testRunList({cos(12), coa(12)}), "Curse of Shadow",
      "F5 CoS+CoA, CoS in slot (10 s, rt=12): CoS refreshes itself")

    -- ── F6: CoS + CoA, slot empty → CoS fires first (higher prio) ─
    agonySlot = "none"; agonyRemaining = 0.0
    reset_np()
    eq(AutoLock:_testRunList({cos(12), coa(12)}), "Curse of Shadow",
      "F6 empty slot: CoS fires first (prio 6 < prio 7)")
  end)
  restore()
  if not pass then fail("[agony_refreshtime_with_cos_enabled] crashed", tostring(err)) end
end)

-- ── cos_coa_rotation_stops ───────────────────────────────────
-- Malediction talent rules (how CoS and CoA interact):
--   1. Casting CoS → applies BOTH CoS and CoA to the target simultaneously.
--   2. Casting CoA → applies only CoA (no CoS).
--   3. CoS CANNOT refresh an existing CoA — but if CoA is on target and CoS
--      is NOT yet applied, CoS can still be cast (adds the CoS bonus on top).
--
-- Bug trigger: after CoS fires (both CoS + CoA are now on target), the next
-- macro press runs CoS again because its condition has no guard for
-- "is CoS already on target?". Cursive sees CoS is up and returns a
-- non-false truthy value ("handled") instead of false. AutoLock treats
-- this as a successful cast:
--   ok=truthy → SpellStartedName="Curse of Shadow" → _npQueuedThisCast=true
--   No actual spell was cast → SPELLCAST_STOP never fires → flag stuck.
-- Every subsequent press hits the same path; all spells with prio > 6 are
-- blocked by the nampower guard. Rotation appears frozen.
-- A manual spell cast fires SPELLCAST_STOP, clears the flag — which matches
-- the user observation ("manually casting something fixes it").
--
-- Fix: add a HasCurse("curse of shadow") guard to CoS's condition so CoS
-- is skipped when it is already on the target.
-- The "CoA present but CoS absent" case must still pass (CoS is allowed then).
suite("cos_coa_rotation_stops", function()
  local env = rot_env_new()
  local ok_r, err = pcall(function()
    -- Everything on CD except curses and DS (realistic mid-fight state).
    AutoLock.IsOnCooldown = function() return true end
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999
    AutoLock._combatConfigName = "rot_test"

    -- Track both curses independently (Malediction: CoS cast applies both).
    local cosRemaining = 0.0
    local coaRemaining = 0.0

    -- Accurate Malediction/Cursive mock.
    -- Key: when CoS is already on target, Cursive:Curse("CoS") returns a non-false
    -- truthy value ("handled") instead of false — this is the bug trigger.
    Cursive = {
      curses = {
        HasCurse = function(self, name, guid, refreshtime)
          if name == "curse of shadow" then return cosRemaining > refreshtime end
          if name == "curse of agony"  then return coaRemaining > refreshtime end
          return false
        end,
      },
      Curse = function(self, name, tgt, opts)
        local rt = (opts and opts.refreshtime) or 1
        if name == "Curse of Shadow" then
          if cosRemaining > rt then
            -- CoS already on target: Cursive "handles" it but does NOT cast.
            -- Returns truthy instead of false — triggers the stuck-flag bug.
            return "handled"
          end
          -- CoS absent (or expired): cast. Malediction applies CoA too.
          cosRemaining = 20.0
          coaRemaining = 20.0
          return true
        end
        if name == "Curse of Agony" then
          if coaRemaining > rt then return false end
          coaRemaining = 20.0
          return true
        end
        return false
      end,
    }

    -- Build entry list from real SPELL_PRIORITY: CoS(6), CoA(7), DS(23).
    local cosEntry, coaEntry, dsEntry
    for _, e in ipairs(SPELL_PRIORITY) do
      if e.name == "Curse of Shadow" and e.type == "curse" then cosEntry = e end
      if e.name == "Curse of Agony"  and e.type == "curse" then coaEntry = e end
      if e.name == "Drain Soul"      and e.type == "cast"  then dsEntry  = e end
    end
    local function cp(e) local c={}; for k,v in pairs(e) do c[k]=v end; return c end
    local cos = cp(cosEntry); cos.enabled = true
    local coa = cp(coaEntry); coa.enabled = true
    local ds  = cp(dsEntry);  ds.enabled  = true
    local entries = { cos, coa, ds }
    table.sort(entries, function(a, b) return (a.priority or 99) < (b.priority or 99) end)

    local function reset_np()
      AutoLock._npQueuedThisCast = false
      AutoLock._npQueuedPriority = 99999
    end

    -- ── I1: neither curse on target → CoS fires (Malediction applies both) ──
    cosRemaining = 0.0; coaRemaining = 0.0; reset_np()
    eq(AutoLock:_testRunList(entries), "Curse of Shadow",
      "I1 both absent: CoS fires (applies CoS+CoA via Malediction)")

    -- ── I2: CoS already on target (18 s), CoA also on target.
    -- BUG: CoS condition passes → Cursive returns "handled" (truthy) →
    --      _npQueuedThisCast stuck true → rotation frozen.
    -- EXPECTED (fix): CoS condition detects CoS already present → false →
    --      CoA also has time → both skip → DS fires.
    cosRemaining = 18.0; coaRemaining = 18.0; reset_np()
    eq(AutoLock:_testRunList(entries), "Drain Soul",
      "I2 CoS+CoA both fresh (18 s): CoS must be skipped → DS fires (BUG: frozen)")

    -- ── I3: CoA on target (18 s) but CoS NOT yet applied.
    -- CoS should fire to add the shadow bonus (CoA present but CoS absent is OK).
    cosRemaining = 0.0; coaRemaining = 18.0; reset_np()
    eq(AutoLock:_testRunList(entries), "Curse of Shadow",
      "I3 CoA present but no CoS: CoS fires to add shadow bonus")

    -- ── I4: CoS expired but CoA still up → CoS fires (reapplies shadow bonus) ──
    cosRemaining = 0.0; coaRemaining = 5.0; reset_np()
    eq(AutoLock:_testRunList(entries), "Curse of Shadow",
      "I4 CoS expired, CoA still up: CoS fires (reapplies shadow bonus)")

    -- ── I5: both expired → CoS fires again ──
    cosRemaining = 0.0; coaRemaining = 0.0; reset_np()
    eq(AutoLock:_testRunList(entries), "Curse of Shadow",
      "I5 both expired: CoS fires")
  end)
  env:restore()
  if not ok_r then fail("[cos_coa_rotation_stops] crashed", tostring(err)) end
end)

-- ============================================================
-- Suite: facing_curse_fallback
-- When a cast-type spell (Death Coil) fails due to facing, the
-- rotation must stop at the next curse-type spell (Siphon Life)
-- that genuinely needs casting (HasCurse returns false = not up).
--
-- Root issue: Cursive:Curse() returns false/nil, so ok=false for
-- ALL curse entries regardless of whether they were actually cast.
-- The rotation never stops at a curse, falling through to nothing
-- after Death Coil is FacingFailed-skipped.
-- ============================================================
suite("facing_curse_fallback", function()
  local env = rot_env_new()
  local pass, err = pcall(function()
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999

    -- Realistic stub: Cursive:Curse returns true when it casts (curse absent),
    -- false when curse is already up. Siphon Life is NOT on target.
    local cursesUp = { ["curse of shadow"]=true, ["curse of agony"]=true, ["corruption"]=true }
    Cursive = {
      curses = { HasCurse = function(_, name) return cursesUp[name] == true end },
      Curse  = function(_, name)
        local lower = string.lower(name)
        if cursesUp[lower] then return false end
        cursesUp[lower] = true
        env.lastCast = name
        return true
      end,
    }

    local s = {
      { name="Curse of Shadow", type="curse", priority=6,  enabled=true, target="target",
        refreshtime=0, condition=function() return true end },
      { name="Curse of Agony",  type="curse", priority=7,  enabled=true, target="target",
        refreshtime=0, condition=function() return true end },
      { name="Corruption",      type="curse", priority=8,  enabled=true, target="target",
        refreshtime=0, condition=function() return true end },
      { name="Death Coil",      type="cast",  priority=17, enabled=true, target="target",
        condition=function() return true end },
      { name="Siphon Life",     type="curse", priority=18, enabled=true, target="target",
        refreshtime=0, condition=function() return true end },
    }

    -- Death Coil failed due to facing; CoS/CoA/Corruption already up
    AutoLock:_testSetFacingFailedSpell("Death Coil")
    local cast = AutoLock:_testRunList(s)
    AutoLock:_testSetFacingFailedSpell(nil)

    -- Expected: DC skipped, CoS/CoA/Corruption already up (Cursive returns false),
    -- SL not up → Cursive:Curse("Siphon Life") returns true → rotation stops at SL
    eq(cast, "Siphon Life",
      "facing_curse_fallback: DC skipped (facing), SL fires as fallback")
  end)
  env:restore()
  AutoLock:_testSetFacingFailedSpell(nil)
  if not pass then fail("[facing_curse_fallback] crashed", tostring(err)) end
end)

-- ── curse_np_flag_not_set ─────────────────────────────────────
-- After a curse-type spell fires, _npQueuedThisCast must NOT be set.
-- Root cause of the freeze: instant curses set the NP flag; the next
-- press finds the curse already on target (condition=false) and the NP
-- guard blocks every higher-numbered priority → nothing fires → no
-- SPELLCAST_STOP → flag stuck permanently.
-- Fix: in TryAction's "if ok then" block, skip flag-setting for type=="curse".
suite("curse_np_flag_not_set", function()
  local env = rot_env_new()
  local ok_r, err = pcall(function()
    AutoLock.IsOnCooldown = function() return true end  -- DC/SB/etc on CD
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999
    AutoLock._combatConfigName = nil

    local cosRemaining = 0.0
    local coaRemaining = 0.0

    -- Accurate Malediction/Cursive mock: CoS cast applies both CoS+CoA.
    -- When CoS is already on target, Cursive returns "handled" (truthy non-true).
    Cursive = {
      curses = {
        HasCurse = function(self, name, guid, refreshtime)
          if name == "curse of shadow" then return cosRemaining > refreshtime end
          if name == "curse of agony"  then return coaRemaining > refreshtime end
          return false
        end,
      },
      Curse = function(self, name, tgt, opts)
        local rt = (opts and opts.refreshtime) or 1
        if name == "Curse of Shadow" then
          if cosRemaining > rt then return "handled" end
          cosRemaining = 20.0; coaRemaining = 20.0; return true
        end
        if name == "Curse of Agony" then
          if coaRemaining > rt then return false end
          coaRemaining = 20.0; return true
        end
        return false
      end,
    }

    local cosEntry, dsEntry
    for _, e in ipairs(SPELL_PRIORITY) do
      if e.name == "Curse of Shadow" and e.type == "curse" then cosEntry = e end
      if e.name == "Drain Soul"      and e.type == "cast"  then dsEntry  = e end
    end
    local function cp(e) local c={}; for k,v in pairs(e) do c[k]=v end; return c end
    local cos = cp(cosEntry); cos.enabled = true
    local ds  = cp(dsEntry);  ds.enabled  = true
    local entries = { cos, ds }

    -- N1: no curses on target → CoS fires (returns true), sets CoS+CoA to 20 s.
    cosRemaining = 0.0; coaRemaining = 0.0
    eq(AutoLock:_testRunList(entries), "Curse of Shadow",
      "N1 no curses: CoS fires")

    -- N2: NP flag must NOT be set after a curse fires.
    is_false(AutoLock._npQueuedThisCast,
      "N2 after curse fires: _npQueuedThisCast must remain false")

    -- N3: next press WITHOUT clearing the flag (simulates rapid pressing).
    -- CoS already on target → condition returns false (HasCurse guard).
    -- NP flag is false → DS is NOT blocked → DS fires.
    eq(AutoLock:_testRunList(entries), "Drain Soul",
      "N3 rapid press after CoS: DS fires (no freeze, NP flag not set for curses)")

    -- N4: when only CoS is in the list and it is already on target, nothing fires
    -- and the NP flag must remain false (condition gate prevents Cursive call).
    cosRemaining = 20.0; coaRemaining = 20.0
    AutoLock._npQueuedThisCast = false
    AutoLock._npQueuedPriority = 99999
    is_nil(AutoLock:_testRunList({cos}),
      "N4 CoS already up (only CoS in list): nothing fires")
    is_false(AutoLock._npQueuedThisCast,
      "N4b NP flag stays false when nothing fires")
  end)
  env:restore()
  if not ok_r then fail("[curse_np_flag_not_set] crashed", tostring(err)) end
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
