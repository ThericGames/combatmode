-- tests/spec_support_lock.lua: generated support casts preserve aim and self-cast without locks.
return function(check, CM, env)
  local spells = env.C_Spell
  local oldInfo, oldSubtext = spells.GetSpellInfo, spells.GetSpellSubtext
  local oldAutoRepeat, oldLegacyRepeat = spells.IsAutoRepeatSpell, env.IsAutoRepeatSpell
  env.IsAutoRepeatSpell = false
  spells.IsAutoRepeatSpell = function()
    return false
  end
  local oldHelpful, oldHarmful = spells.IsSpellHelpful, spells.IsSpellHarmful
  local spellBook = env.C_SpellBook
  local oldFindBase = spellBook.FindBaseSpellByID
  local oldFindOverride = spellBook.FindSpellOverrideByID
  spellBook.FindBaseSpellByID = function()
    return nil
  end
  spellBook.FindSpellOverrideByID = function()
    return nil
  end
  local oldSlotInfo = CM.GetDisplayedActionSlotInfo
  spells.GetSpellInfo = function()
    return { name = "Heal" }
  end
  spells.GetSpellSubtext = function()
    return ""
  end
  spells.IsSpellHelpful = function()
    return true
  end
  spells.IsSpellHarmful = function()
    return false
  end
  CM.GetDisplayedActionSlotInfo = function()
    return "spell", 54321
  end
  local function cast()
    local text, support, selfText = CM.BuildClickCastMacroText("ACTIONBUTTON1", { support = true })
    check("built a Support Mode cast", support, true)
    return text, selfText
  end
  local oldDB = CM.DB
  CM.DB = { char = { reticleTargeting = true, autoTargetLockOnAttack = true } }
  check("default permits locks", CM.IsSupportTargetLockEnabled(), true)
  local enabled = cast()
  check("enabled auto locks", enabled:find("/focus", 1, true) ~= nil, true)
  for _, crosshair in ipairs({ false, true }) do
    CM.DB.char.supportModeCrosshairFirst = crosshair
    for _, disabled in ipairs({ true, 1 }) do
      CM.DB.char.supportModeDisableTargetLock = disabled
      local text, selfText = cast()
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
  spellBook.FindBaseSpellByID = oldFindBase
  spellBook.FindSpellOverrideByID = oldFindOverride
  CM.GetDisplayedActionSlotInfo = oldSlotInfo
  spells.GetSpellInfo, spells.GetSpellSubtext = oldInfo, oldSubtext
  spells.IsSpellHelpful, spells.IsSpellHarmful = oldHelpful, oldHarmful
  spells.IsAutoRepeatSpell, env.IsAutoRepeatSpell = oldAutoRepeat, oldLegacyRepeat
end
