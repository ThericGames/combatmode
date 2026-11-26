-- tests/spec_support_lock.lua: Auto Lock Allies off drops only the Support Mode ally auto-lock;
-- a manual lock keeps priority and the self-cast text is unchanged.
return function(check, CM, env)
  local spells = env.C_Spell
  local spellBook = env.C_SpellBook
  local saved = {}
  local function swap(owner, key, value)
    saved[#saved + 1] = { owner, key, owner[key] }
    owner[key] = value
  end
  local function nothing()
    return nil
  end
  local function no()
    return false
  end
  swap(env, "IsAutoRepeatSpell", false)
  swap(spells, "IsAutoRepeatSpell", no)
  swap(spells, "IsSpellHarmful", no)
  swap(spells, "IsSpellHelpful", function()
    return true
  end)
  swap(spells, "GetSpellInfo", function()
    return { name = "Heal" }
  end)
  swap(spells, "GetSpellSubtext", function()
    return ""
  end)
  swap(spellBook, "FindBaseSpellByID", nothing)
  swap(spellBook, "FindSpellOverrideByID", nothing)
  swap(CM, "GetDisplayedActionSlotInfo", function()
    return "spell", 54321
  end)
  swap(CM, "DB", { char = { reticleTargeting = true, autoTargetLockOnAttack = true } })

  local function cast()
    local text, support, selfText = CM.BuildClickCastMacroText("ACTIONBUTTON1", { support = true })
    check("built a Support Mode cast", support, true)
    return text, selfText
  end

  check("unset option still auto locks", cast():find("/focus", 1, true) ~= nil, true)
  for _, crosshair in ipairs({ false, true }) do
    CM.DB.char.supportModeCrosshairFirst = crosshair
    for _, off in ipairs({ false, 0 }) do
      CM.DB.char.supportModeAutoTargetLock = off
      local text, selfText = cast()
      check("no automatic lock", text:find("/focus", 1, true), nil)
      check("manual lock still honored", text:find("@focus,help,nodead", 1, true) ~= nil, true)
      check("aimed ally available", text:find("@mouseover", 1, true) ~= nil, true)
      check("self cast preserved", selfText, "/cast [@player] Heal")
      check("secure macro limit", #text <= 255, true)
    end
    CM.DB.char.supportModeAutoTargetLock = 1
    check("numeric one auto locks", cast():find("/focus", 1, true) ~= nil, true)
  end

  for i = #saved, 1, -1 do
    local entry = saved[i]
    entry[1][entry[2]] = entry[3]
  end
end
