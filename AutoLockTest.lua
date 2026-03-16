-- AutoLockTest.lua
-- Unit tests for AutoLock addon.
-- Run in-game: /run AutoLockTests()
-- Single suite: /run AutoLockTests("toggle")

-- =============================================================
-- Micro test framework (all state local to this file)
-- =============================================================
local AL_PASS = 0
local AL_FAIL = 0
local AL_RESULTS = {}

local function T_ok(label)
  table.insert(AL_RESULTS, "|cff00cc00[PASS]|r " .. tostring(label))
  AL_PASS = AL_PASS + 1
end

local function T_fail(label, extra)
  table.insert(AL_RESULTS, "|cffff4444[FAIL]|r " .. tostring(label)
    .. (extra and (" | " .. tostring(extra)) or ""))
  AL_FAIL = AL_FAIL + 1
end

local function eq(a, b, label)
  if a == b then T_ok(label)
  else T_fail(label, "expected="..tostring(b).." got="..tostring(a)) end
end

local function is_true(v, label)
  if v then T_ok(label) else T_fail(label, "expected true") end
end

local function is_false(v, label)
  if not v then T_ok(label) else T_fail(label, "expected false") end
end

local function is_nil(v, label)
  if v == nil then T_ok(label) else T_fail(label, "expected nil, got "..tostring(v)) end
end

-- =============================================================
-- Suites stored by name
-- =============================================================
local SUITES = {}

local function def_suite(name, fn)
  SUITES[name] = fn
end

-- =============================================================
-- Suite 1: spell-enable toggle
-- =============================================================
def_suite("toggle", function()
  -- nil -> true (first click, spell starts disabled)
  local e = { enabled = nil }
  e.enabled = not (e.enabled == true)
  eq(e.enabled, true, "toggle nil->true")

  -- true -> false
  e.enabled = not (e.enabled == true)
  eq(e.enabled, false, "toggle true->false")

  -- false -> true
  e.enabled = not (e.enabled == true)
  eq(e.enabled, true, "toggle false->true")

  -- second cycle
  e.enabled = not (e.enabled == true)
  eq(e.enabled, false, "toggle true->false (2nd)")
end)

-- =============================================================
-- Suite 2: darkHarvestDots stored on cfg object
-- =============================================================
def_suite("darkHarvestDots", function()
  local cfg = { name = "Test", spells = {} }

  is_nil(cfg.darkHarvestDots, "darkHarvestDots initially nil")

  -- simulate first OnClick (nil -> true)
  if not cfg.darkHarvestDots then cfg.darkHarvestDots = {} end
  local key = "siphonLife"
  local newVal = not (cfg.darkHarvestDots[key] == true)
  cfg.darkHarvestDots[key] = newVal
  eq(cfg.darkHarvestDots.siphonLife, true, "siphonLife set to true")

  -- simulate SaveCurrentConfigSpells: only cfg.spells is rebuilt
  cfg.spells = {}
  eq(cfg.darkHarvestDots.siphonLife, true, "siphonLife survives cfg.spells = {}")

  -- uncheck (true -> false)
  newVal = not (cfg.darkHarvestDots[key] == true)
  cfg.darkHarvestDots[key] = newVal
  eq(cfg.darkHarvestDots.siphonLife, false, "siphonLife toggled to false")

  -- SetChecked arg for false: should be nil
  local setArg = cfg.darkHarvestDots.siphonLife and 1 or nil
  is_nil(setArg, "SetChecked(nil) for false")

  -- re-check (false -> true)
  newVal = not (cfg.darkHarvestDots[key] == true)
  cfg.darkHarvestDots[key] = newVal
  setArg = cfg.darkHarvestDots.siphonLife and 1 or nil
  eq(setArg, 1, "SetChecked(1) for true")
end)

-- =============================================================
-- Suite 3: darkHarvestDotsReady logic (pure Lua, no WoW API)
-- =============================================================
def_suite("darkHarvestDotsReady", function()
  local function dotsReady(req, cursiveHas, debuffOn)
    if not req then return true end
    local CURSES  = { agony="curse of agony", corruption="corruption", siphonLife="siphon life" }
    local DEBUFFS = { shadowVuln="Shadow Vulnerability" }
    for k, name in pairs(CURSES) do
      if req[k] then
        if not cursiveHas(name) then return false end
      end
    end
    for k, name in pairs(DEBUFFS) do
      if req[k] then
        if not debuffOn(name) then return false end
      end
    end
    return true
  end

  local YES = function(_) return true  end
  local NO  = function(_) return false end

  is_true (dotsReady(nil,  YES, YES), "nil req -> ready")
  is_true (dotsReady({},   YES, YES), "empty req -> ready")
  is_true (dotsReady({ agony=true }, YES, YES), "agony required+present")
  is_false(dotsReady({ agony=true }, NO,  YES), "agony required+missing")
  is_true (dotsReady({ agony=true, corruption=false }, YES, YES), "corruption=false skipped")
  is_true (dotsReady({ shadowVuln=true }, YES, YES), "shadowVuln required+present")
  is_false(dotsReady({ shadowVuln=true }, YES, NO),  "shadowVuln required+missing")

  local noSiphon = function(n) return n ~= "siphon life" end
  is_false(dotsReady({ agony=true, siphonLife=true }, noSiphon, YES), "siphonLife missing")

  is_true(dotsReady(
    { agony=true, corruption=true, siphonLife=true, shadowVuln=true },
    YES, YES), "all required+present")
end)

-- =============================================================
-- Suite 3b: isBlockedByDrainSoul logic (pure Lua, no WoW API)
-- A curse is ALLOWED during DS when its checkbox is checked (dots[key]==true).
-- When unchecked or no config: the curse is BLOCKED (default safe).
-- =============================================================
def_suite("isBlockedByDrainSoul", function()
  -- Simulates the corrected isBlockedByDrainSoul(key, channeling, drainSoulDots)
  local function blocked(key, channeling, dots)
    if not channeling then return false end
    if not dots then return false end         -- no config -> all allowed (default on)
    return dots[key] ~= true                  -- only explicitly unchecked = blocked
  end

  -- not channeling -> never blocked regardless of config
  is_false(blocked("agony",      false, { agony=true }),      "not channeling -> not blocked")
  is_false(blocked("corruption", false, { corruption=true }), "not channeling -> not blocked")
  is_false(blocked("siphonLife", false, { siphonLife=true }), "not channeling -> not blocked")

  -- channeling, no config -> allowed (default on)
  is_false(blocked("agony", true, nil), "channeling, nil config -> not blocked (default on)")
  is_true(blocked("agony", true, {}),   "channeling, empty config -> blocked (unchecked)")

  -- channeling + key=true (checkbox checked) -> NOT blocked (allowed)
  is_false(blocked("agony",      true, { agony=true }),      "agony checked -> allowed during DS")
  is_false(blocked("corruption", true, { corruption=true }), "corruption checked -> allowed during DS")
  is_false(blocked("siphonLife", true, { siphonLife=true }), "siphonLife checked -> allowed during DS")

  -- channeling + key=false (checkbox unchecked) -> blocked
  is_true(blocked("agony", true, { agony=false }), "agony=false -> blocked during DS")

  -- other key not checked -> blocked
  is_true(blocked("corruption", true, { agony=true }), "corruption unchecked -> blocked")

  -- all three checked -> all allowed
  local allChecked = { agony=true, corruption=true, siphonLife=true }
  is_false(blocked("agony",      true, allChecked), "all checked: agony allowed")
  is_false(blocked("corruption", true, allChecked), "all checked: corruption allowed")
  is_false(blocked("siphonLife", true, allChecked), "all checked: siphonLife allowed")

  -- shadowVuln not a DS key -> blocked (not in config)
  is_true(blocked("shadowVuln", true, allChecked), "shadowVuln not in DS config -> blocked")
end)

-- =============================================================
-- Suite 4: GetSpellKey
-- =============================================================
def_suite("getSpellKey", function()
  local function key(e)
    return (e.uitext or e.name or "?") .. "|" .. (e.type or "?")
  end

  eq(key({ name="Shadow Bolt", type="cast" }),  "Shadow Bolt|cast",  "normal spell")
  eq(key({ name="Siphon Life", type="curse" }), "Siphon Life|curse", "curse")
  eq(key({ name="Shadow Bolt", type="cast", uitext="Shadow Trance (Shadow Bolt)" }),
     "Shadow Trance (Shadow Bolt)|cast", "uitext overrides name")
  eq(key({}),            "?|?",   "empty entry")
  eq(key({ type="pet" }), "?|pet", "nil name")
end)

-- =============================================================
-- Suite 5: config system name tracking
-- =============================================================
def_suite("configSystem", function()
  local configs = {
    { name="ConfigA", spells={}, darkHarvestDots={ siphonLife=true } },
    { name="ConfigB", spells={} },
  }

  local function getActive(loadedName, activeName)
    local name = loadedName or activeName
    for _, c in ipairs(configs) do
      if c.name == name then return c end
    end
  end

  -- normal lookup
  local cfg = getActive("ConfigA", "ConfigA")
  eq(cfg and cfg.name, "ConfigA", "getActive returns ConfigA")
  eq(cfg and cfg.darkHarvestDots and cfg.darkHarvestDots.siphonLife, true, "ConfigA has siphonLife")

  -- switch preview to ConfigB
  cfg = getActive("ConfigB", "ConfigA")
  eq(cfg and cfg.name, "ConfigB", "preview returns ConfigB")
  is_nil(cfg and cfg.darkHarvestDots, "ConfigB has no darkHarvestDots")

  -- ConfigA's darkHarvestDots must be intact
  eq(configs[1].darkHarvestDots.siphonLife, true, "ConfigA darkHarvestDots intact after switch")

  -- simulate _reloadActiveCombatConfig: savedName/restore pattern
  local loadedName = "ConfigB"
  local savedName  = loadedName    -- "ConfigB"
  loadedName = "ConfigA"           -- ApplyConfigToSpells sets _loadedConfigName = activeConfig.name
  loadedName = savedName           -- restored
  eq(loadedName, "ConfigB", "loadedName restored after _reloadActiveCombatConfig")
end)

-- =============================================================
-- Suite 6: HasDebuffByName logic (mocked SuperWoW)
-- =============================================================
def_suite("hasDebuffByName", function()
  local function hasDebuff(debuffs, target)
    local idToName = {}
    for _, d in ipairs(debuffs) do idToName[d.id] = d.name end
    for i = 1, table.getn(debuffs) do
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
  is_false(hasDebuff(list, "Siphon Life"),           "absent debuff -> false")
  is_false(hasDebuff({},   "Shadow Vulnerability"),  "empty list -> false")
end)

-- =============================================================
-- Suite 7: SanitizeNumberText logic
-- =============================================================
def_suite("sanitizeNumber", function()
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
  eq(san("1,5"),   "1.5",  "comma->dot")
  eq(san("abc"),   "",     "letters stripped")
  eq(san("1.2.3"), "1.23", "double dot")
  eq(san(""),      "",     "empty")
  eq(san(nil),     "",     "nil")
  eq(san(" 10 "),  "10",   "spaces stripped")
end)

-- =============================================================
-- Suite 8: isBlockedByDrainSoul – real function, controlled state
-- Uses test hooks added in AutoLock.lua.
-- =============================================================
def_suite("drainSoulBlocking", function()
  local savedDB          = AutoLockDB
  local savedCombatName  = AutoLock._combatConfigName

  local function restore()
    AutoLockDB                 = savedDB
    AutoLock._combatConfigName = savedCombatName
    AutoLock:_testSetDrainSoulChanneling(false)
  end

  local ok, err = pcall(function()
    AutoLockDB = {
      configs = { { name="DS_Test", drainSoulDots = { agony=true, corruption=true } } },
      activeConfig = "DS_Test",
    }
    AutoLock._combatConfigName = "DS_Test"

    -- Not channeling -> never blocked regardless of config
    AutoLock:_testSetDrainSoulChanneling(false)
    is_false(AutoLock:_testIsBlockedByDrainSoul("agony"),      "not channeling: agony not blocked")
    is_false(AutoLock:_testIsBlockedByDrainSoul("corruption"), "not channeling: corruption not blocked")
    is_false(AutoLock:_testIsBlockedByDrainSoul("siphonLife"), "not channeling: siphonLife not blocked")

    -- Channeling + key checked -> allowed (not blocked)
    AutoLock:_testSetDrainSoulChanneling(true)
    AutoLock:_testSetDrainSoulTiming(GetTime() - 10, 5)  -- elapsed, so channeling is "finished"
    is_false(AutoLock:_testIsBlockedByDrainSoul("agony"),      "channeling: agony checked -> allowed")
    is_false(AutoLock:_testIsBlockedByDrainSoul("corruption"), "channeling: corruption checked -> allowed")

    -- Active channel (not yet finished)
    AutoLock:_testSetDrainSoulTiming(GetTime(), 15)
    is_true (AutoLock:_testIsBlockedByDrainSoul("siphonLife"), "channeling: siphonLife unchecked -> blocked")

    -- Check siphonLife -> now allowed
    AutoLockDB.configs[1].drainSoulDots.siphonLife = true
    is_false(AutoLock:_testIsBlockedByDrainSoul("siphonLife"), "channeling: siphonLife now checked -> allowed")

    -- Uncheck agony (false) -> blocked
    AutoLockDB.configs[1].drainSoulDots.agony = false
    is_true(AutoLock:_testIsBlockedByDrainSoul("agony"), "channeling: agony=false -> blocked")

    -- Wrong combat config name -> blocked (safe default, config not found)
    AutoLock._combatConfigName = "NonExistent"
    is_true(AutoLock:_testIsBlockedByDrainSoul("corruption"), "wrong config name -> blocked (safe default)")

    -- nil combatConfigName falls back to activeConfig
    AutoLock._combatConfigName = nil
    AutoLockDB.configs[1].drainSoulDots.corruption = true
    is_false(AutoLock:_testIsBlockedByDrainSoul("corruption"), "nil combatName: falls back to activeConfig")

    -- nil drainSoulDots on config -> not blocked (default on)
    AutoLock._combatConfigName = "DS_Test"
    AutoLockDB.configs[1].drainSoulDots = nil
    is_false(AutoLock:_testIsBlockedByDrainSoul("agony"), "nil drainSoulDots -> not blocked (default on)")
  end)

  restore()
  if not ok then T_fail("[drainSoulBlocking] crashed", tostring(err)) end
end)

-- =============================================================
-- Suite 9: drainSoulConditions – condition functions in
-- SPELL_PRIORITY for CoA / Corruption / Siphon Life must
-- delegate to isBlockedByDrainSoul correctly.
-- =============================================================
def_suite("drainSoulConditions", function()
  -- Locate the three entries in SPELL_PRIORITY
  local coaCond, corrCond, slCond
  for _, e in ipairs(SPELL_PRIORITY) do
    if e.name == "Curse of Agony"  and e.type == "curse" then coaCond  = e.condition end
    if e.name == "Corruption"      and e.type == "curse" then corrCond = e.condition end
    if e.name == "Siphon Life"     and e.type == "curse" then slCond   = e.condition end
  end

  is_true(coaCond  ~= nil, "Curse of Agony has a condition function")
  is_true(corrCond ~= nil, "Corruption has a condition function")
  is_true(slCond   ~= nil, "Siphon Life has a condition function")
  if not coaCond or not corrCond or not slCond then return end

  local savedDB         = AutoLockDB
  local savedCombatName = AutoLock._combatConfigName

  local function restore()
    AutoLockDB                 = savedDB
    AutoLock._combatConfigName = savedCombatName
    AutoLock:_testSetDrainSoulChanneling(false)
  end

  local ok, err = pcall(function()
    AutoLockDB = {
      configs = { { name="CondTest", drainSoulDots = { agony=true, corruption=true, siphonLife=true } } },
      activeConfig = "CondTest",
    }
    AutoLock._combatConfigName = "CondTest"

    -- Not channeling -> all conditions return true (spells always allowed)
    AutoLock:_testSetDrainSoulChanneling(false)
    is_true(coaCond ("target"), "CoA cond: not channeling -> allowed (returns true)")
    is_true(corrCond("target"), "Corruption cond: not channeling -> allowed (returns true)")
    is_true(slCond  ("target"), "SiphonLife cond: not channeling -> allowed (returns true)")

    -- Channeling + all checked -> all conditions return true (renewal allowed)
    AutoLock:_testSetDrainSoulChanneling(true)
    AutoLock:_testSetDrainSoulTiming(GetTime() - 10, 5)  -- elapsed, treat as finished
    is_true(coaCond ("target"), "CoA cond: channeling, checked -> allowed (returns true)")
    is_true(corrCond("target"), "Corruption cond: channeling, checked -> allowed (returns true)")
    is_true(slCond  ("target"), "SiphonLife cond: channeling, checked -> allowed (returns true)")

    -- Active channel: uncheck siphonLife -> blocked
    AutoLock:_testSetDrainSoulTiming(GetTime(), 15)
    AutoLockDB.configs[1].drainSoulDots.siphonLife = false
    is_false(slCond("target"), "SiphonLife cond: unchecked -> blocked (returns false)")

    -- No drainSoulDots at all -> all allowed (default on)
    AutoLockDB.configs[1].drainSoulDots = nil
    is_true(coaCond ("target"), "CoA cond: nil drainSoulDots -> not blocked (default on)")
    is_true(corrCond("target"), "Corruption cond: nil drainSoulDots -> not blocked (default on)")
  end)

  restore()
  if not ok then T_fail("[drainSoulConditions] crashed", tostring(err)) end
end)

-- =============================================================
-- Suite 10: drainSoulRestartBug
-- Reproduces the race condition where DS restarts instead of
-- refreshing curses after the channel finishes.
--
-- Root cause: isBlockedByDrainSoul checks only DrainSoulChanneling
-- (boolean), while drainSoulChannelingFinished() also uses elapsed
-- time. When the channel has timed out but the CHANNEL_STOP event
-- has not yet fired, DrainSoulChanneling is still true →
--   • curses are blocked (isBlockedByDrainSoul = true)
--   • DS condition passes (drainSoulChannelingFinished = true)
-- → DS fires again instead of refreshing the expired curses.
-- =============================================================
def_suite("drainSoulRestartBug", function()
  local savedDB         = AutoLockDB
  local savedCombatName = AutoLock._combatConfigName

  local function restore()
    AutoLockDB                 = savedDB
    AutoLock._combatConfigName = savedCombatName
    AutoLock:_testSetDrainSoulChanneling(false)
  end

  local ok, err = pcall(function()
    -- All curses unchecked (blocked during DS) — the config the user chose
    AutoLockDB = {
      configs = { { name = "DSRestartTest", drainSoulDots = {} } },
      activeConfig = "DSRestartTest",
    }
    AutoLock._combatConfigName = "DSRestartTest"

    -- Simulate: DS channel flag still set but has elapsed (event not yet fired)
    AutoLock:_testSetDrainSoulChanneling(true)
    AutoLock:_testSetDrainSoulTiming(GetTime() - 10, 5)  -- started 10s ago, 5s duration -> done 5s ago

    -- BUG: isBlockedByDrainSoul ignores elapsed time, still returns true
    -- → curses are blocked even though DS has finished → DS fires again
    -- These assertions FAIL until isBlockedByDrainSoul respects drainSoulChannelingFinished()
    is_false(AutoLock:_testIsBlockedByDrainSoul("agony"),
      "drainSoulRestartBug: DS timed out -> agony must NOT be blocked")
    is_false(AutoLock:_testIsBlockedByDrainSoul("corruption"),
      "drainSoulRestartBug: DS timed out -> corruption must NOT be blocked")
    is_false(AutoLock:_testIsBlockedByDrainSoul("siphonLife"),
      "drainSoulRestartBug: DS timed out -> siphonLife must NOT be blocked")

    -- Sanity: channel still active (time remaining) → curses ARE blocked
    AutoLock:_testSetDrainSoulTiming(GetTime(), 15)  -- just started, 15s duration
    is_true(AutoLock:_testIsBlockedByDrainSoul("agony"),
      "drainSoulRestartBug: DS active -> agony is blocked (correct)")
  end)

  restore()
  if not ok then T_fail("[drainSoulRestartBug] crashed", tostring(err)) end
end)

-- =============================================================
-- Suite 11: Curse of Shadow DS blocking
-- CoS has no DS-blocking condition → it gets cast during DS channeling →
-- that INTERRUPTS the DS channel → DrainSoulChanneling becomes false →
-- on the next press isBlockedByDrainSoul("agony") returns false →
-- Curse of Agony is no longer blocked. Fix: CoS needs the same DS
-- blocking condition as CoA (they share the curse slot / agony key).
-- =============================================================
def_suite("cosDrainSoulBlocking", function()
  -- Locate CoS entry
  local cosEntry
  for _, e in ipairs(SPELL_PRIORITY) do
    if e.name == "Curse of Shadow" and e.type == "curse" then
      cosEntry = e
      break
    end
  end
  is_true(cosEntry ~= nil, "Curse of Shadow entry found in SPELL_PRIORITY")
  if not cosEntry then return end

  -- CoS must have a condition to block during DS (currently nil → FAILS)
  is_true(cosEntry.condition ~= nil, "Curse of Shadow must have a DS-blocking condition")
  if not cosEntry.condition then return end

  local savedDB         = AutoLockDB
  local savedCombatName = AutoLock._combatConfigName

  local function restore()
    AutoLockDB                 = savedDB
    AutoLock._combatConfigName = savedCombatName
    AutoLock:_testSetDrainSoulChanneling(false)
  end

  local ok, err = pcall(function()
    AutoLockDB = {
      configs = { { name = "CosDS", drainSoulDots = { agony = false } } },
      activeConfig = "CosDS",
    }
    AutoLock._combatConfigName = "CosDS"

    -- DS active, agony unchecked → CoS must be blocked too (same curse slot)
    AutoLock:_testSetDrainSoulChanneling(true)
    AutoLock:_testSetDrainSoulTiming(GetTime(), 15)
    is_false(cosEntry.condition("target"),
      "CoS: active DS, agony unchecked -> blocked (prevents DS interrupt)")

    -- DS active, agony checked → CoS allowed
    AutoLockDB.configs[1].drainSoulDots.agony = true
    is_true(cosEntry.condition("target"),
      "CoS: active DS, agony checked -> allowed")

    -- Not channeling → always allowed
    AutoLock:_testSetDrainSoulChanneling(false)
    AutoLockDB.configs[1].drainSoulDots.agony = false
    is_true(cosEntry.condition("target"),
      "CoS: not channeling, agony unchecked -> allowed (no DS active)")
  end)

  restore()
  if not ok then T_fail("[cosDrainSoulBlocking] crashed", tostring(err)) end
end)

-- =============================================================
-- Suite 12: Curse of Shadow / Curse of Agony mutual exclusivity
-- CoA condition must return false when CoS is already on the target,
-- because only one curse can be active at a time. Without this guard
-- CoA would overwrite CoS on every other macro press.
-- =============================================================
def_suite("cosCoaMutualExclusion", function()
  local coaCond
  for _, e in ipairs(SPELL_PRIORITY) do
    if e.name == "Curse of Agony" and e.type == "curse" then
      coaCond = e.condition
      break
    end
  end
  is_true(coaCond ~= nil, "Curse of Agony has a condition function")
  if not coaCond then return end

  local savedDB         = AutoLockDB
  local savedCombatName = AutoLock._combatConfigName
  local savedCursive    = Cursive

  local function restore()
    AutoLockDB                 = savedDB
    AutoLock._combatConfigName = savedCombatName
    Cursive                    = savedCursive
    AutoLock:_testSetDrainSoulChanneling(false)
  end

  local ok, err = pcall(function()
    AutoLockDB = {
      configs = { { name = "CoSTest", drainSoulDots = { agony = true } } },
      activeConfig = "CoSTest",
    }
    AutoLock._combatConfigName = "CoSTest"
    AutoLock:_testSetDrainSoulChanneling(false)

    -- No Cursive: CoS check skipped, CoA allowed
    Cursive = nil
    is_true(coaCond("target"), "no Cursive: CoA condition returns true")

    -- Cursive present but no .curses table: CoA allowed
    Cursive = {}
    is_true(coaCond("target"), "Cursive without .curses: CoA condition returns true")

    -- Cursive present, CoS NOT on target -> CoA allowed
    Cursive = {
      curses = {
        HasCurse = function(self, name, guid, refresh)
          return name == "curse of agony"  -- only CoA on target (e.g. first-ever cast)
        end
      }
    }
    is_true(coaCond("target"), "CoS absent: CoA condition returns true")

    -- Cursive present, CoS IS on target -> CoA blocked (don't overwrite)
    Cursive = {
      curses = {
        HasCurse = function(self, name, guid, refresh)
          return name == "curse of shadow"
        end
      }
    }
    is_false(coaCond("target"), "CoS active: CoA condition returns false (mutual exclusion)")

    -- DS blocking takes precedence even when CoS is absent
    AutoLock:_testSetDrainSoulChanneling(true)
    AutoLock:_testSetDrainSoulTiming(GetTime(), 15)
    AutoLockDB.configs[1].drainSoulDots = {}  -- agony unchecked
    Cursive = {
      curses = {
        HasCurse = function(self, name, guid, refresh) return false end
      }
    }
    is_false(coaCond("target"), "DS blocking: CoA condition returns false regardless of CoS")
  end)

  restore()
  if not ok then T_fail("[cosCoaMutualExclusion] crashed", tostring(err)) end
end)

-- =============================================================
-- Runner (global, no dependency on AutoLock object)
-- =============================================================
function AutoLockTests(filter)
  AL_PASS    = 0
  AL_FAIL    = 0
  AL_RESULTS = {}

  for name, fn in pairs(SUITES) do
    if not filter or name == filter then
      local ok, err = pcall(fn)
      if not ok then
        T_fail("[suite:"..name.."] crashed", tostring(err))
      end
    end
  end

  for _, msg in ipairs(AL_RESULTS) do
    DEFAULT_CHAT_FRAME:AddMessage("|cff9482C9[AutoLock]|r " .. msg)
  end

  local total = AL_PASS + AL_FAIL
  local color = (AL_FAIL == 0) and "|cff00ff00" or "|cffff4444"
  DEFAULT_CHAT_FRAME:AddMessage("|cff9482C9[AutoLock]|r " .. color
    .. "Tests: " .. AL_PASS .. "/" .. total .. " passed, "
    .. AL_FAIL .. " failed|r")
end
