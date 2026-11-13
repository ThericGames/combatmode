-- Keyboard and mouse bindings must build the same Support Mode targeting variants.

return function(check, CM)
  local build
  for index = 1, 50 do
    local name, value = debug.getupvalue(CM.ApplyGroundCastKeyOverrides, index)
    if not name then
      break
    end
    if name == "BuildModeMacroTexts" then
      build = value
      break
    end
  end
  check("mode builder available", type(build), "function")
  if not build then
    return
  end

  local originalContext = CM.GetSupportModeBuildContext
  local originalBuild = CM.BuildClickCastMacroText
  local context = { active = false }
  CM.GetSupportModeBuildContext = function()
    return context
  end
  CM.BuildClickCastMacroText = function(binding, opts)
    return { binding = binding, page = opts and opts.page, support = opts and opts.support or false }
  end

  local function Verify(label, binding, normalPage, supportPage, enabled)
    local normal, support = build(binding)
    check(label .. " normal routing", normal.support, false)
    check(label .. " normal page", normal.page, normalPage)
    check(label .. " support variant", support ~= nil, enabled)
    if support then
      check(label .. " support routing", support.support, true)
      check(label .. " support page", support.page, supportPage)
    end
  end

  Verify("main bar without page swap", "ACTIONBUTTON6", nil, nil, true)
  Verify("secondary bar without page swap", "MULTIACTIONBAR1BUTTON6", nil, nil, true)
  context.page = 2
  Verify("main bar entering support", "ACTIONBUTTON6", nil, 2, true)
  Verify("secondary bar entering support", "MULTIACTIONBAR1BUTTON6", nil, nil, true)
  context.active = true
  Verify("main bar leaving support", "ACTIONBUTTON6", 1, 2, true)
  Verify("secondary bar leaving support", "MULTIACTIONBAR1BUTTON6", nil, nil, true)
  context = nil
  Verify("support disabled", "ACTIONBUTTON6", nil, nil, false)

  CM.GetSupportModeBuildContext = originalContext
  CM.BuildClickCastMacroText = originalBuild
end
