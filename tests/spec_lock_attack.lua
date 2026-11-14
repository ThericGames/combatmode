-- Lock and attack must execute BOTH commands from the same mouse/key proxy.
-- This checks generated secure actions and binding refreshes, not the WoW macro engine.
return function(check, loaded, _, root)
  local combat, housing, keyDown = false, false, "0"
  local kind, spell = "spell", 6603
  local mouse, keys, frames = {}, {}, {}
  local function noop() end
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.C_CVar = {
    GetCVar = function()
      return keyDown
    end,
  }
  env.C_ActionBar = {}
  env.C_Spell = {
    IsSpellHelpful = function(id)
      return id == 2061
    end,
    IsSpellHarmful = function(id)
      return id == 100
    end,
    GetSpellInfo = function(id)
      return { name = "Spell" .. id }
    end,
  }
  env.GetActionInfo = function()
    return kind, spell
  end
  env.GetActionBarPage = function()
    return 1
  end
  env.GetBonusBarOffset = function()
    return 0
  end
  env.IsInGroup = function()
    return true
  end
  env.strtrim = function(s)
    return s:match("^%s*(.-)%s*$")
  end
  env.InCombatLockdown = function()
    return combat
  end
  env.C_HouseEditor = {
    IsHouseEditorActive = function()
      return housing
    end,
  }
  env.GetBindingKey = function(name)
    if name == "ACTIONBUTTON1" then
      return "1", "PAD1"
    end
    if name == "ACTIONBUTTON2" then
      return "2"
    end
    if name == "Combat Mode - Toggle Focus Target" then
      return "BUTTON5"
    end
  end
  env.CreateFrame = function(_, name)
    local f = {
      GetName = function()
        return name
      end,
      RegisterForClicks = noop,
      SetAttribute = function()
        assert(not combat, "attribute change in combat")
      end,
    }
    if name then
      frames[name] = f
    end
    return f
  end
  env.ClearOverrideBindings = function(owner)
    assert(not combat, "binding clear in combat")
    for key, binding in pairs(keys) do
      if binding.owner == owner then
        keys[key] = nil
      end
    end
  end
  env.SetOverrideBindingClick = function(owner, _, key, frame)
    assert(not combat, "binding change in combat")
    keys[key] = { owner = owner, frame = frame }
  end
  env.SetOverrideBinding = function(owner, _, key, binding)
    assert(not combat, "binding change in combat")
    keys[key] = { owner = owner, binding = binding }
  end
  env.SetMouselookOverrideBinding = function(key, action)
    assert(not combat, "mouse binding change in combat")
    mouse[key] = action
  end
  local char = {
    reticleTargeting = true,
    targetLockActionButton1 = true,
    bindings = {
      left = { enabled = true, key = "BUTTON1", value = "ACTIONBUTTON1" },
      right = { enabled = true, key = "BUTTON2", value = "ACTIONBUTTON2" },
    },
  }
  local CM = {
    DB = { char = char, global = {} },
    Constants = setmetatable(
      { ButtonsToOverride = { "left", "right" } },
      { __index = loaded.Constants }
    ),
    DbBool = loaded.DbBool,
    Profile = function(_, f)
      return f()
    end,
    DebugPrint = noop,
    ClearAddonButtonCaches = noop,
    SupportModeRegisterProxy = noop,
    GetSupportModeBuildContext = function()
      return nil
    end,
    GetBindingsLocation = function()
      return "char"
    end,
    IsAllyCycleEnabled = function()
      return true
    end,
    IsAllyCycleRestoreAfterHarm = function()
      return true
    end,
    SetModeMacroText = function(f, text, support)
      assert(not combat, "macro change in combat")
      f.text, f.support = text, support
    end,
  }
  local function load(name)
    local chunk = assert(loadfile(root .. "/CombatMode/" .. name))
    setfenv(chunk, env)("CombatMode", CM)
  end
  load("Core/ClickCasting/TargetingMacroBuilder.lua")
  local function contains(text, part)
    return text and text:find(part, 1, true) ~= nil or false
  end
  local function lockCast(binding, options)
    return CM.BuildClickCastMacroText(binding or "ACTIONBUTTON1", options)
  end
  local lock = "/focus [@mouseover,harm,nodead][harm,nodead]"
  local attack = lockCast()
  check(
    "one press locks before starting attack",
    contains(attack, lock .. "\n/tar [@focus,harm,nodead]\n/startattack [harm,nodead]"),
    true
  )
  check("attack never clicks the toggle attack button", contains(attack, "/click"), false)
  check(
    "attack keeps the new target instead of restoring an ally",
    contains(attack, "/targetlasttarget"),
    false
  )
  check("slot 2 keeps its own targeting", contains(lockCast("ACTIONBUTTON2"), lock), false)
  char.targetLockActionButton1 = 0
  check("Forever false disables the feature", contains(lockCast(), lock), false)
  char.targetLockActionButton1 = 1
  check("Forever true enables the feature", contains(lockCast(), lock), true)
  spell = 100
  check("damaging spell still casts after lock", contains(lockCast(), "/click"), true)
  check("damaging spell locks", contains(lockCast(), lock), true)
  env.ElvUI_Bar1Button1 = {
    IsShown = function()
      return true
    end,
  }
  for _, down in ipairs({ "0", "1" }) do
    keyDown = down
    check("ElvUI full macro fits 255 bytes, key-down=" .. down, #lockCast() <= 255, true)
  end
  env.ElvUI_Bar1Button1 = nil
  char.excludeFromTargetingSpells = "100"
  check("excluded spell keeps normal routing", contains(lockCast(), lock), false)
  char.excludeFromTargetingSpells = nil
  char.castAtCursorSpells = "100"
  check("ground spell keeps cursor cast", lockCast(), "/cast [@cursor] Spell100")
  char.castAtCursorSpells = nil
  spell = 2061
  check("helpful spell never gets enemy lock", contains(lockCast(), lock), false)
  check(
    "Support Mode heal never gets enemy lock",
    contains(lockCast(nil, { support = true }), lock),
    false
  )
  spell = 6603
  load("Core/ClickCasting/BindingOverrides.lua")
  CM.RefreshClickCastMacros()
  CM.ApplyToggleFocusTargetBinding()
  check("left click uses the cast proxy", mouse.BUTTON1, "CLICK CombatModeClickCast1:LeftButton")
  check("left-click proxy both locks and attacks", frames.CombatModeClickCast1.text, attack)
  check("slot 1 key both locks and attacks", frames[keys["1"].frame].text, attack)
  check("second slot 1 key has same proxy", keys.PAD1.frame, keys["1"].frame)
  check(
    "dedicated target lock stays lock-only",
    contains(frames[keys.BUTTON5.frame].text, "/startattack"),
    false
  )
  char.macroInjectionClickCastOnly = true
  CM.RefreshClickCastMacros()
  check("explicit slot 1 option overrides click-cast-only for its key", keys["1"] ~= nil, true)
  check("click-cast-only still skips other keyboard slots", keys["2"], nil)
  kind = "macro"
  CM.RefreshClickCastMacros()
  check("macro slots run the real bar button", mouse.BUTTON1, "CLICK ActionButton1:LeftButton")
  check("macro key retains native binding", keys["1"].binding, "ACTIONBUTTON1")
  kind = "spell"
  CM.RefreshClickCastMacros()
  combat = true
  char.targetLockActionButton1 = false
  CM.RefreshClickCastMacros()
  check("refresh waits during combat", frames.CombatModeClickCast1.text, attack)
  combat = false
  CM.FlushPendingClickCastRefresh()
  check(
    "pending refresh removes lock after combat",
    contains(frames.CombatModeClickCast1.text, lock),
    false
  )
  check("disable clears slot 1 override in click-cast-only", keys["1"], nil)
  char.targetLockActionButton1 = true
  housing = true
  CM.RefreshClickCastMacros()
  check("housing owns keyboard bindings", keys["1"], nil)
  char.reticleTargeting = false
  CM.RefreshClickCastMacros()
  check("reticle off restores left click action", mouse.BUTTON1, "ACTIONBUTTON1")
  check("reticle off disables macro injection", lockCast(), nil)
end
