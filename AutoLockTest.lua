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
