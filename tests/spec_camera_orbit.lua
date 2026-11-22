return function(check, CM, env)
  local callbacks = {}
  local override
  local keyDown = true
  local resume
  local calls = {}
  local cvars = { CursorFreelookStartDelta = "0.001", cameraViewBlendStyle = "1" }
  local testCM = {
    DB = { global = { cameraOrbitEnabled = true } },
    DbBool = CM.DbBool,
    IsMouselooking = function()
      return true
    end,
    ShouldFreeLookBeOff = function()
      return false
    end,
    SetCursorFreelookCenteringCVar = function(value)
      check("native drag disables cursor centering", value, false)
    end,
    SetCVar = function(key, value)
      cvars[key] = value
    end,
    ReconcileFreeLook = function()
      calls[#calls + 1] = "aim"
    end,
  }
  local function No()
    return false
  end
  local testEnv = setmetatable({
    C_Timer = {
      After = function(_, callback)
        resume = callback
      end,
    },
    C_CVar = {
      GetCVar = function(name)
        return cvars[name]
      end,
    },
    IsAltKeyDown = No,
    IsControlKeyDown = No,
    IsShiftKeyDown = No,
    InCombatLockdown = No,
    IsKeyDown = function(key, physical)
      return key == "F8" and physical and keyDown
    end,
    GetBindingKey = function()
      return "F8"
    end,
    GetBindingAction = function()
      return override
    end,
    ClearOverrideBindings = function()
      override = nil
    end,
    SetOverrideBinding = function(_, _, key, command)
      check("configured binding is reused", key, "F8")
      override = command
    end,
    MouselookStop = function()
      calls[#calls + 1] = "release steering"
    end,
    SaveView = function(slot)
      calls[#calls + 1] = "save " .. slot
    end,
    SetView = function(slot)
      calls[#calls + 1] = "restore " .. slot
    end,
    CreateFrame = function()
      return {
        EnableKeyboard = function() end,
        RegisterEvent = function() end,
        SetPropagateKeyboardInput = function(_, propagate)
          check("native input propagates", propagate, true)
        end,
        SetScript = function(_, event, callback)
          callbacks[event] = callback
        end,
      }
    end,
  }, { __index = env })
  testEnv._G = testEnv
  local path = debug.getinfo(CM.CanOrbitCamera, "S").source:sub(2)
  local chunk = assert(loadfile(path))
  setfenv(chunk, testEnv)
  chunk("CombatMode", testCM)

  testCM.SetCameraOrbitAvailable(true)
  check("F8 uses WoW's camera drag", override, "CAMERAORSELECTORMOVE")
  callbacks.OnKeyDown(nil, "P")
  check("other keys leave the camera alone", #calls, 0)
  callbacks.OnKeyDown({
    SetScript = function(_, event, script)
      callbacks[event] = script
    end,
  }, "F8")
  check("save view after steering releases", table.concat(calls, ","), "release steering,save 5")
  callbacks.OnUpdate()
  callbacks.OnUpdate()
  check("holding the key keeps the peek active", testCM.IsCameraOrbitActive(), true)
  keyDown = false
  callbacks.OnUpdate()
  check(
    "restore view before resuming aim",
    table.concat(calls, ","),
    "release steering,save 5,restore 5"
  )
  check("drag threshold restored", cvars.CursorFreelookStartDelta, "0.001")
  check("blend setting restored", cvars.cameraViewBlendStyle, "1")
  check("steering stays suspended while the view restores", testCM.IsCameraOrbitActive(), true)
  resume()
  check(
    "aim resumes after camera returns",
    table.concat(calls, ","),
    "release steering,save 5,restore 5,aim"
  )
  testCM.SetCameraOrbitAvailable(false)
  check("leaving reticle mode removes the native override", override, nil)
end
