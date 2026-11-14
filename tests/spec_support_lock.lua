-- tests/spec_support_lock.lua: generated support casts preserve aim and self-cast without locks.
return function(check, CM)
  local function upvalue(fn, wanted)
    for i = 1, 100 do
      local name, value = debug.getupvalue(fn, i)
      if name == wanted then
        return value
      end
      if not name then
        break
      end
    end
    error("Missing upvalue: " .. wanted)
  end
  local cast = upvalue(CM.BuildClickCastMacroText, "SupportCastLine")
  local spells = upvalue(cast, "C_Spell")
  local oldInfo, oldSubtext = spells.GetSpellInfo, spells.GetSpellSubtext
  spells.GetSpellInfo = function()
    return { name = "Heal" }
  end
  spells.GetSpellSubtext = function()
    return ""
  end
  local oldDB = CM.DB
  CM.DB = { char = { autoTargetLockOnAttack = true } }
  check("default permits locks", CM.IsSupportTargetLockEnabled(), true)
  local enabled = cast(123)
  check("enabled auto locks", enabled:find("/focus", 1, true) ~= nil, true)
  for _, crosshair in ipairs({ false, true }) do
    CM.DB.char.supportModeCrosshairFirst = crosshair
    for _, disabled in ipairs({ true, 1 }) do
      CM.DB.char.supportModeDisableTargetLock = disabled
      local text, selfText = cast(123)
      check("no focus target", text:find("@focus", 1, true), nil)
      check("no automatic lock", text:find("/focus", 1, true), nil)
      check("aimed ally available", text:find("@mouseover", 1, true) ~= nil, true)
      check("self cast preserved", selfText, "/cast [@player] Heal")
      check("secure macro limit", #text <= 255, true)
    end
  end
  CM.DB.char.supportModeDisableTargetLock = 0
  check("numeric zero permits locks", CM.IsSupportTargetLockEnabled(), true)
  CM.DB = oldDB
  spells.GetSpellInfo, spells.GetSpellSubtext = oldInfo, oldSubtext
end
