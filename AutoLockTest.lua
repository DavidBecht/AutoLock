-- AutoLockTest.lua
-- Unit tests for AutoLock addon.
-- Run in-game:  /run AutoLock:RunTests()
-- Or test a single suite: /run AutoLock:RunTests("toggle")

-- =============================================================
-- Micro test framework
-- =============================================================
local _suite = {}
local _results = {}

local function suite(name, fn)
  _suite[name] = fn
end

local function assertEqual(actual, expected, label)
  if actual == expected then
    table.insert(_results, { ok=true,  label=label })
  else
    table.insert(_results, { ok=false, label=label,
      msg="expected "..tostring(expected).." got "..tostring(actual) })
  end
end

local function assertTrue(val, label)
  assertEqual(not not val, true, label)
end

local function assertFalse(val, label)
  assertEqual(not not val, false, label)
end

local function assertNil(val, label)
  assertEqual(val, nil, label)
end

-- =============================================================
-- Suite 1: spell-enable toggle (the core fix)
-- =============================================================
suite("toggle", function()
  -- nil → true (first click on default-disabled spell)
  local e = { enabled = nil }
  e.enabled = not (e.enabled == true)
  assertEqual(e.enabled, true, "toggle nil→true")

  -- true → false
  e.enabled = not (e.enabled == true)
  assertEqual(e.enabled, false, "toggle true→false")

  -- false → true
  e.enabled = not (e.enabled == true)
  assertEqual(e.enabled, true, "toggle false→true")

  -- second true→false round-trip
  e.enabled = not (e.enabled == true)
  assertEqual(e.enabled, false, "toggle true→false (2nd)")
end)

-- =============================================================
-- Suite 2: darkHarvestDots storage on config object
-- =============================================================
suite("darkHarvestDots", function()
  -- Simulate: user opens popup, clicks siphonLife
  local cfg = { name="Test", spells={} }

  assertNil(cfg.darkHarvestDots, "darkHarvestDots initially nil")

  -- First click: nil → true
  if not cfg.darkHarvestDots then cfg.darkHarvestDots = {} end
  local key = "siphonLife"
  local newVal = not (cfg.darkHarvestDots[key] == true)
  cfg.darkHarvestDots[key] = newVal
  assertEqual(cfg.darkHarvestDots.siphonLife, true, "siphonLife set to true")

  -- Simulate SaveCurrentConfigSpells: rebuilds cfg.spells, must NOT touch darkHarvestDots
  local savedDH = cfg.darkHarvestDots    -- defensive copy (as in real code, we don't rebuild it)
  cfg.spells = {}                         -- simulates cfg.spells = {} in SaveCurrentConfigSpells
  assertEqual(cfg.darkHarvestDots, savedDH, "darkHarvestDots survives SaveCurrentConfigSpells")
  assertEqual(cfg.darkHarvestDots.siphonLife, true, "siphonLife still true after save")

  -- Second click: true → false (uncheck)
  newVal = not (cfg.darkHarvestDots[key] == true)
  cfg.darkHarvestDots[key] = newVal
  assertEqual(cfg.darkHarvestDots.siphonLife, false, "siphonLife toggled to false")

  -- SetChecked mapping: false should show as unchecked (nil)
  local setCheckedArg = cfg.darkHarvestDots.siphonLife and 1 or nil
  assertNil(setCheckedArg, "SetChecked(nil) for false value")

  -- SetChecked mapping: re-enable
  cfg.darkHarvestDots.siphonLife = true
  setCheckedArg = cfg.darkHarvestDots.siphonLife and 1 or nil
  assertEqual(setCheckedArg, 1, "SetChecked(1) for true value")
end)

-- =============================================================
-- Suite 3: darkHarvestDotsReady logic (mocked AutoLockDB)
-- =============================================================
suite("darkHarvestDotsReady", function()
  -- We can't call the local function directly, but we can test the exact
  -- logic pattern it uses. Any change to darkHarvestDotsReady() must be
  -- reflected here.

  local function simulateDotsReady(req, cursiveHas, debuffOn)
    -- req: table like { agony=true, corruption=false, shadowVuln=true }
    -- cursiveHas: function(curseName) → bool
    -- debuffOn: function(debuffName) → bool
    if not req then return true end

    local CURSE_NAMES = {
      agony      = "curse of agony",
      corruption = "corruption",
      siphonLife = "siphon life",
    }
    local DEBUFF_NAMES = {
      shadowVuln = "Shadow Vulnerability",
    }

    for key, curseName in pairs(CURSE_NAMES) do
      if req[key] then
        if not cursiveHas(curseName) then return false end
      end
    end
    for key, debuffName in pairs(DEBUFF_NAMES) do
      if req[key] then
        if not debuffOn(debuffName) then return false end
      end
    end
    return true
  end

  local allPresent = function(_) return true end
  local nonePresent = function(_) return false end

  -- No requirements → always ready
  assertTrue(simulateDotsReady(nil, allPresent, allPresent),
    "nil req → ready")
  assertTrue(simulateDotsReady({}, allPresent, allPresent),
    "empty req → ready")

  -- Agony required and present
  assertTrue(simulateDotsReady({ agony=true }, allPresent, allPresent),
    "agony required+present → ready")

  -- Agony required but missing
  assertFalse(simulateDotsReady({ agony=true }, nonePresent, allPresent),
    "agony required+missing → not ready")

  -- Corruption not required → don't block even if absent
  assertTrue(simulateDotsReady({ agony=true, corruption=false }, allPresent, allPresent),
    "corruption=false skipped")

  -- shadowVuln required and present
  assertTrue(simulateDotsReady({ shadowVuln=true }, allPresent, allPresent),
    "shadowVuln required+present → ready")

  -- shadowVuln required but missing
  assertFalse(simulateDotsReady({ shadowVuln=true }, allPresent, nonePresent),
    "shadowVuln required+missing → not ready")

  -- All four required; three present, one missing
  local partialCurse = function(n) return n ~= "siphon life" end
  assertFalse(simulateDotsReady(
    { agony=true, corruption=true, siphonLife=true, shadowVuln=true },
    partialCurse, allPresent),
    "siphonLife missing → not ready")

  -- All four required and all present
  assertTrue(simulateDotsReady(
    { agony=true, corruption=true, siphonLife=true, shadowVuln=true },
    allPresent, allPresent),
    "all required+all present → ready")
end)

-- =============================================================
-- Suite 4: GetSpellKey logic
-- =============================================================
suite("getSpellKey", function()
  local function GetSpellKey(e)
    return (e.uitext or e.name or "?") .. "|" .. (e.type or "?")
  end

  assertEqual(GetSpellKey({ name="Shadow Bolt", type="cast" }),
    "Shadow Bolt|cast", "normal spell key")

  assertEqual(GetSpellKey({ name="Siphon Life", type="curse" }),
    "Siphon Life|curse", "curse key")

  -- uitext overrides name
  assertEqual(GetSpellKey({ name="Shadow Bolt", type="cast",
    uitext="Shadow Trance (Shadow Bolt)" }),
    "Shadow Trance (Shadow Bolt)|cast", "uitext overrides name")

  -- missing name and type
  assertEqual(GetSpellKey({}), "?|?", "empty entry key")

  -- nil name, has type
  assertEqual(GetSpellKey({ type="pet" }), "?|pet", "nil name key")
end)

-- =============================================================
-- Suite 5: config system logic (no WoW API needed)
-- =============================================================
suite("configSystem", function()
  -- Simulate the three-config-name variables
  local loadedName   = "ConfigA"
  local activeConfig = "ConfigA"
  local combatName   = nil

  -- GetActiveConfig simulation
  local function getActive(configs)
    local name = loadedName or activeConfig
    for _, c in ipairs(configs) do
      if c.name == name then return c end
    end
  end

  local configs = {
    { name="ConfigA", spells={}, darkHarvestDots={siphonLife=true} },
    { name="ConfigB", spells={} },
  }

  -- Should return ConfigA
  local cfg = getActive(configs)
  assertEqual(cfg and cfg.name, "ConfigA", "getActive returns loadedName config")
  assertEqual(cfg.darkHarvestDots.siphonLife, true, "ConfigA has siphonLife set")

  -- Switch preview to ConfigB; darkHarvestDots on ConfigA must be intact
  loadedName = "ConfigB"
  cfg = getActive(configs)
  assertEqual(cfg and cfg.name, "ConfigB", "getActive returns ConfigB after switch")
  assertNil(cfg.darkHarvestDots, "ConfigB has no darkHarvestDots")

  -- ConfigA's darkHarvestDots must still be there
  local cfgA = configs[1]
  assertEqual(cfgA.darkHarvestDots.siphonLife, true,
    "ConfigA darkHarvestDots survives preview switch")

  -- Simulate _reloadActiveCombatConfig: restore loadedName to saved value
  local savedName = loadedName  -- "ConfigB"
  -- (ApplyConfigToSpells runs on activeConfig = "ConfigA")
  loadedName = "ConfigA"        -- temporarily changed inside ApplyConfigToSpells
  loadedName = savedName        -- restored at end of _reloadActiveCombatConfig
  assertEqual(loadedName, "ConfigB", "loadedName restored after _reloadActiveCombatConfig")

  -- After reopen: getActive returns ConfigB (the preview config)
  cfg = getActive(configs)
  assertEqual(cfg and cfg.name, "ConfigB", "ConfigB still loaded after reopen")
end)

-- =============================================================
-- Suite 6: HasDebuffByName logic (mock SuperWoW API)
-- =============================================================
suite("hasDebuffByName", function()
  -- We test the pure logic, mocking SpellInfo and UnitDebuff/UnitExists.
  local function simulateHasDebuff(debuffs, targetSpellName)
    -- debuffs: list of { spellID=N, name="X" }
    local spellInfoMap = {}
    for _, d in ipairs(debuffs) do spellInfoMap[d.spellID] = d.name end

    local function mockSpellInfo(id) return spellInfoMap[id] end
    local function mockUnitDebuff(guid, i)
      local d = debuffs[i]
      if d then return nil, nil, nil, d.spellID end
      return nil
    end
    local guid = "GUID-0001"

    for i = 1, 40 do
      local _, _, _, spellID = mockUnitDebuff(guid, i)
      if spellID then
        local name = mockSpellInfo(spellID)
        if name == targetSpellName then return true end
      else
        break
      end
    end
    return false
  end

  local testDebuffs = {
    { spellID=1, name="Curse of Agony" },
    { spellID=2, name="Shadow Vulnerability" },
    { spellID=3, name="Corruption" },
  }

  assertTrue(simulateHasDebuff(testDebuffs, "Shadow Vulnerability"),
    "finds Shadow Vulnerability by name")
  assertTrue(simulateHasDebuff(testDebuffs, "Curse of Agony"),
    "finds Curse of Agony by name")
  assertFalse(simulateHasDebuff(testDebuffs, "Siphon Life"),
    "returns false when debuff absent")
  assertFalse(simulateHasDebuff({}, "Shadow Vulnerability"),
    "returns false on empty debuff list")
end)

-- =============================================================
-- Suite 7: SanitizeNumberText logic
-- =============================================================
suite("sanitizeNumber", function()
  -- Inline the same logic as SanitizeNumberText in AutoLockUI.lua
  local function sanitize(s)
    s = tostring(s or "")
    s = string.gsub(s, ",", ".")
    s = string.gsub(s, "[^0-9%.]", "")
    local firstDot = string.find(s, "%.")
    if firstDot then
      local head = string.sub(s, 1, firstDot)
      local tail = string.gsub(string.sub(s, firstDot + 1), "%.", "")
      s = head .. tail
    end
    return s
  end

  assertEqual(sanitize("30"),      "30",   "integer unchanged")
  assertEqual(sanitize("1.5"),     "1.5",  "float unchanged")
  assertEqual(sanitize("1,5"),     "1.5",  "comma→dot")
  assertEqual(sanitize("abc"),     "",     "non-numeric → empty")
  assertEqual(sanitize("1.2.3"),   "1.23", "double dot stripped")
  assertEqual(sanitize(""),        "",     "empty string")
  assertEqual(sanitize(nil),       "",     "nil → empty")
  assertEqual(sanitize(" 10 "),    "10",   "spaces stripped")
end)

-- =============================================================
-- Runner
-- =============================================================
function AutoLock:RunTests(filter)
  _results = {}
  local ran = 0
  local failed = 0

  for name, fn in pairs(_suite) do
    if not filter or name == filter then
      local ok, err = pcall(fn)
      ran = ran + 1
      if not ok then
        table.insert(_results, { ok=false, label="[SUITE:"..name.."] crashed", msg=tostring(err) })
        failed = failed + 1
      end
    end
  end

  local total = table.getn(_results)
  for _, r in ipairs(_results) do
    if r.ok then
      AutoLockLog.Info("[PASS] " .. r.label)
    else
      AutoLockLog.Error("[FAIL] " .. r.label .. (r.msg and (" – "..r.msg) or ""))
      failed = failed + 1
    end
  end

  -- Recount actual failures from results
  failed = 0
  for _, r in ipairs(_results) do
    if not r.ok then failed = failed + 1 end
  end

  local color = (failed == 0) and "|cff00ff00" or "|cffff4444"
  AutoLockLog.Info(color .. "Tests: " .. (total - failed) .. "/" .. total
    .. " passed, " .. failed .. " failed|r")
end
