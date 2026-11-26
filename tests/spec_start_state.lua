return function(check, CM)
  local oldDB = CM.DB
  CM.DB = { global = {}, char = {} }

  -- login, reload, savedFreed, expected after the call (starting with the cursor not freed)
  local function run(label, startState, isInitialLogin, isReloadingUi, savedFreed, expected)
    CM.DB.global.mouseLookStartState = "on"
    CM.ApplyMouseLookStartState(false, false)
    CM.DB.global.mouseLookStartState = startState
    CM.DB.char.mouseLookFreed = savedFreed
    CM.ApplyMouseLookStartState(isInitialLogin, isReloadingUi)
    check(label, CM.IsMouseLookFreedByUser(), expected)
  end

  run("off after login", "off", true, false, false, true)
  run("off after loading screen", "off", false, false, false, true)
  run("on ignores saved freed cursor", "on", false, true, true, false)
  run("keep restores freed cursor on reload", "keep", false, true, true, true)
  run("keep restores Mouse Look on reload", "keep", false, true, false, false)
  run("keep restores Forever 1 on reload", "keep", false, true, 1, true)
  run("keep starts on at login", "keep", true, false, true, false)
  check("login clears the saved state", CM.DB.char.mouseLookFreed, false)

  CM.DB.global.mouseLookStartState = "off"
  CM.ApplyMouseLookStartState(false, false)
  check("freed state is saved", CM.DB.char.mouseLookFreed, true)
  CM.DB.global.mouseLookStartState = "keep"
  CM.ApplyMouseLookStartState(false, false)
  check("keep survives a loading screen", CM.IsMouseLookFreedByUser(), true)

  CM.DB.global.mouseLookStartState = "on"
  CM.ApplyMouseLookStartState(false, false)
  CM.DB = oldDB
end
