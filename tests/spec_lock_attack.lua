-- Exercise the Click Casting entry point without a bar slot or Target Lock setting.
return function(Check, CM)
  local original = CM.SetModeMacroText
  local frame, normal, support
  CM.SetModeMacroText = function(proxy, normalText, supportText)
    frame, normal, support = proxy, normalText, supportText
  end

  CM.SetNewBinding({ enabled = true, key = "BUTTON1", value = "LOCKANDATTACK" })
  local baseFrame = frame
  local macro = normal
  CM.SetNewBinding({ enabled = true, key = "SHIFT-BUTTON2", value = "LOCKANDATTACK" })
  local modifierFrame = frame
  Check("modifier slot runs the same macro", normal, macro)
  CM.SetNewBinding({ enabled = true, key = "BUTTON4", value = "LOCKANDATTACK" })
  local firstSideFrame = frame
  Check("button 4 has its own proxy", firstSideFrame ~= modifierFrame, true)
  Check("button 4 runs the same macro", normal, macro)
  CM.SetNewBinding({ enabled = true, key = "BUTTON5", value = "LOCKANDATTACK" })
  Check("button 5 has its own proxy", frame ~= firstSideFrame, true)
  Check("button 5 runs the same macro", normal, macro)
  CM.SetModeMacroText = original

  Check(
    "base and modifier slots use distinct proxies",
    baseFrame ~= nil and modifierFrame ~= baseFrame,
    true
  )
  Check(
    "aimed living enemy takes priority over the existing enemy lock",
    macro,
    table.concat({
      "/clearfocus [@focus,dead]",
      "/tar [@mouseover,harm,nodead][@focus,harm,nodead]",
      "/focus [harm,nodead]",
      "/startattack [harm,nodead]",
    }, "\n")
  )
  Check("Support Mode keeps its ally focus", support, CM.Constants.Macros.CM_StartAttack)
end
