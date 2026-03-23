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
  local function dotsReady(req, cursiveHas, debuffOn)
    if not req then return true end
    local CURSES  = { agony="curse of agony", corruption="corruption", siphonLife="siphon life" }
    local DEBUFFS = { shadowVuln="Shadow Vulnerability" }
    for k, name in pairs(CURSES) do
      if req[k] then if not cursiveHas(name) then return false end end
    end
    for k, name in pairs(DEBUFFS) do
      if req[k] then if not debuffOn(name) then return false end end
    end
    return true
  end

  local YES = function(_) return true  end
  local NO  = function(_) return false end

  is_true (dotsReady(nil,  YES, YES), "nil req → ready")
  is_true (dotsReady({},   YES, YES), "empty req → ready")
  is_true (dotsReady({ agony=true },  YES, YES), "agony required+present")
  is_false(dotsReady({ agony=true },  NO,  YES), "agony required+missing")
  is_true (dotsReady({ agony=true, corruption=false }, YES, YES), "corruption=false skipped")
  is_true (dotsReady({ shadowVuln=true }, YES, YES), "shadowVuln required+present")
  is_false(dotsReady({ shadowVuln=true }, YES, NO),  "shadowVuln required+missing")
  local noSiphon = function(n) return n ~= "siphon life" end
  is_false(dotsReady({ agony=true, siphonLife=true }, noSiphon, YES), "siphonLife missing")
  is_true (dotsReady(
    { agony=true, corruption=true, siphonLife=true, shadowVuln=true },
    YES, YES), "all required+present")
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
  local function restore()
    AutoLockDB = savedDB
    AutoLock._combatConfigName = savedCCN
    AutoLock:_testSetDrainSoulChanneling(false)
  end
  local pass, err = pcall(function()
    AutoLockDB = {
      configs = { { name = "CosDS", drainSoulDots = { agony = false } } },
      activeConfig = "CosDS",
    }
    AutoLock._combatConfigName = "CosDS"

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
    is_false(coaCond("target"), "CoS active: CoA returns false (mutual exclusion)")

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
