-- Ping actions must exist in the final registry on every supported client.
return function(Check, CM, env)
  for _, id in ipairs({ "pingattack", "pingwarning", "pingonmyway", "pingassist" }) do
    local action = CM.RadialActions.byId[id]
    Check(id .. " registered", action ~= nil, true)
    Check(id .. " is a ping", action and action.locationPing, true)
  end
  Check("primary command", CM.PingMenuBindingCommands[1], "Combat Mode - Ping Menu")
  Check("secondary command", CM.PingMenuBindingCommands[2], "Combat Mode - Ping Menu Secondary")
  local contextual = CM.Constants.ClickCastPingMacros.TOGGLEPINGLISTENER
  Check(
    "quick ping follows the cursor independently of soft targets",
    contextual,
    "/ping [@mouseover,exists]\n/stopmacro [@mouseover,exists]\n/ping"
  )
  Check(
    "the existing Click Casting action uses the ground fallback",
    CM.Constants.BlizzardActionMacros.TOGGLEPINGLISTENER,
    contextual
  )
  local oldDB, oldRefresh = CM.DB, CM.RadialRefresh
  CM.RadialRefresh = nil
  CM.DB =
    { char = { radialMenu = { presetsSeeded = true, wheels = {} }, separatePingPrimaryMouse = {} } }
  local index = CM.RadialCreateWheel(nil, "ping")
  local wheel = CM.RadialGetWheels()[index]
  Check("Ping preset is locked", wheel.locked, true)
  Check("Ping preset has four slices", CM.RadialSliceCount(wheel), 4)
  CM.RadialSetSlot(index, 1, nil)
  Check("cannot clear a Ping slot", wheel.slots[1].id, "pingattack")
  Check("cannot add a Ping slice", CM.RadialAddSlice(index), false)
  Check("cannot remove a Ping slice", CM.RadialRemoveSlice(index, 1), false)
  CM.RadialReorderSlots(index, { 4, 3, 2, 1 })
  Check("cannot reorder Ping slots", wheel.slots[1].id, "pingattack")
  CM.RadialDeleteWheel(index)
  Check("can delete the Ping preset", #CM.RadialGetWheels(), 0)
  local oldAssign, oldOverride = CM.AssignNamedKeybind, CM.OverrideDefaultButtons
  local oldGetKey, oldSetClick = env.GetBindingKey, env.SetOverrideBindingClick
  local oldSetMouse = env.SetMouselookOverrideBinding
  local oldInCombat = env.InCombatLockdown
  local primary, secondary = unpack(CM.PingMenuBindingCommands)
  local native, direct, cleared = {}, {}, {}
  env.InCombatLockdown = function()
    return false
  end
  env.GetBindingKey = function(command)
    if command == secondary then
      return "CTRL-BUTTON5", "PAD1"
    end
    return native[command]
  end
  env.SetOverrideBindingClick = function(_, _, binding, _, route)
    direct[binding] = route
  end
  env.SetMouselookOverrideBinding = function(binding, action)
    cleared[binding] = action == nil
  end
  CM.OverrideDefaultButtons = function() end
  CM.AssignNamedKeybind = function(command, binding)
    native[command] = binding ~= "" and binding or nil
  end
  CM.SetSeparatePingBinding(primary, "BUTTON2")
  Check(
    "right-click binding is visible in the panel",
    CM.GetSeparatePingBinding(primary),
    "BUTTON2"
  )
  Check(
    "right-click uses the Mouse Look binding",
    CM.GetPingMouseLookAction("BUTTON2") ~= nil,
    true
  )
  Check("right-click keeps its ordinary WoW binding", native[primary], nil)
  Check("modifier plus side button gets a route", direct["CTRL-BUTTON5"], "ping2")
  Check("second native key works for gamepad", direct.PAD1, "ping3")
  CM.SetSeparatePingBinding(primary, "SHIFT-Q")
  Check("keyboard chord gets a route", direct["SHIFT-Q"], "ping1")
  Check("rebinding clears the old Mouse Look override", cleared.BUTTON2, true)
  Check("rebinding restores the right-click slot", CM.GetPingMouseLookAction("BUTTON2"), nil)
  CM.AssignNamedKeybind, CM.OverrideDefaultButtons = oldAssign, oldOverride
  env.GetBindingKey, env.SetOverrideBindingClick = oldGetKey, oldSetClick
  env.SetMouselookOverrideBinding, env.InCombatLockdown = oldSetMouse, oldInCombat
  local oldTimer = env.C_Timer
  local oldLock, oldUnlock = CM.LockFreeLook, CM.UnlockFreeLook
  local oldCenter, oldReconcile = CM.SetCursorFreelookCentering, CM.ReconcileFreeLook
  local callbacks, restored = {}, 0
  env.C_Timer = {
    After = function(_, callback)
      callbacks[#callbacks + 1] = callback
    end,
  }
  CM.LockFreeLook = function() end
  CM.UnlockFreeLook = function() end
  CM.SetCursorFreelookCentering = function() end
  CM.ReconcileFreeLook = function()
    restored = restored + 1
  end
  local locationPing, hooks = true, {}
  local button = {
    GetAttribute = function(_, name)
      return name == "locationping" and locationPing
    end,
    HookScript = function(_, name, handler)
      hooks[name] = handler
    end,
  }
  CM.HookReticlePingButton(button)
  hooks.PreClick(button, "LeftButton", true)
  Check("press does not unlock before the release", #callbacks, 0)
  locationPing = false
  hooks.PreClick(button, "LeftButton", false)
  hooks.PostClick(button, "LeftButton", false)
  Check("ordinary Click Casting actions leave Mouse Look alone", #callbacks, 0)
  locationPing = true
  hooks.PreClick(button, "LeftButton", false)
  Check("ping temporarily releases Mouse Look", CM.locationPingActive, true)
  callbacks[1]()
  Check("a dropped click still restores Mouse Look", CM.locationPingActive, false)
  hooks.PreClick(button, "LeftButton", false)
  hooks.PostClick(button, "LeftButton", false)
  callbacks[3]()
  callbacks[2]()
  Check("PostClick restores only once", restored, 2)
  local oldCursor = env.GetCursorPosition
  local recenterCount = 0
  CM.LockFreeLook = function()
    recenterCount = recenterCount + 1
  end
  local wheelFrame = {
    GetCenter = function()
      return 250, 300
    end,
    GetEffectiveScale = function()
      return 2
    end,
  }
  env.GetCursorPosition = function()
    return 501, 600
  end
  CM.PrepareLocationPingAtReticle(wheelFrame)
  Check("a centered tap preserves mouseover", recenterCount, 0)
  env.GetCursorPosition = function()
    return 540, 600
  end
  CM.PrepareLocationPingAtReticle(wheelFrame)
  Check("releasing over a slice recenters", recenterCount, 1)
  callbacks[#callbacks]()
  env.GetCursorPosition = oldCursor
  env.C_Timer = oldTimer
  CM.LockFreeLook, CM.UnlockFreeLook = oldLock, oldUnlock
  CM.SetCursorFreelookCentering, CM.ReconcileFreeLook = oldCenter, oldReconcile
  CM.DB, CM.RadialRefresh = oldDB, oldRefresh
end
