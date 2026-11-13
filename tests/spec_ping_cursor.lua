-- Exercise the real freelook predicate with held/released mouse and live bindings.

return function(check, CM, env)
  local held, shift, control, alt = true, false, false, false
  local action, queried = "TOGGLEPINGLISTENER", nil
  local windowOpen = false
  local function No()
    return false
  end
  local testCM = {
    DB = { global = {} },
    DbBool = CM.DbBool,
    Profile = function(_, callback)
      return callback()
    end,
    IsCustomLockConditionTrue = No,
    IsCustomConditionTrue = No,
    IsFeignDeathActive = No,
    IsInPetBattle = No,
    IsRadialMenuOpen = No,
    IsUnlockFrameVisible = function()
      return windowOpen
    end,
    IsVendorMountOut = No,
  }
  local testEnv = setmetatable({
    IsMouseButtonDown = function(button)
      return button == "MiddleButton" and held
    end,
    IsShiftKeyDown = function()
      return shift
    end,
    IsControlKeyDown = function()
      return control
    end,
    IsAltKeyDown = function()
      return alt
    end,
    GetBindingAction = function(key, overrides)
      queried = key
      check("honors override bindings", overrides, true)
      return action
    end,
    SpellIsTargeting = No,
    InCinematic = No,
    IsInCinematicScene = No,
  }, { __index = env })
  testEnv._G = testEnv
  local path = debug.getinfo(CM.ShouldFreeLookBeOff, "S").source:sub(2)
  local chunk = assert(loadfile(path))
  setfenv(chunk, testEnv)
  chunk("CombatMode", testCM)

  check("missing setting preserves reticle ping", testCM.ShouldFreeLookBeOff(), false)
  testCM.DB.global.unlockCursorForPing = false
  check("disabled preserves reticle ping", testCM.ShouldFreeLookBeOff(), false)
  testCM.DB.global.unlockCursorForPing = true
  check("enabled held ping unlocks", testCM.ShouldFreeLookBeOff(), true)
  check("plain middle binding", queried, "BUTTON3")
  held = false
  check("release permits normal relock", testCM.ShouldFreeLookBeOff(), false)
  windowOpen = true
  check("release respects other unlock reasons", testCM.ShouldFreeLookBeOff(), true)
  windowOpen, held = false, true
  action = "Combat Mode - Radial Menu"
  check("unrelated binding stays unchanged", testCM.ShouldFreeLookBeOff(), false)
  action = "TOGGLEPINGLISTENER"
  shift, control, alt = true, true, true
  check("modified ping unlocks", testCM.ShouldFreeLookBeOff(), true)
  check("modifier order", queried, "ALT-CTRL-SHIFT-BUTTON3")
  testCM.DB.global.unlockCursorForPing = 0
  check("Forever numeric false stays disabled", testCM.ShouldFreeLookBeOff(), false)
end
