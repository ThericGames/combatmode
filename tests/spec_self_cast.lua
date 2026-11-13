-- Exercise the real macro builder in an isolated client environment.
return function(check, loadedCM)
  local source = debug.getinfo(loadedCM.BuildClickCastMacroText, "S").source:sub(2)
  local id, kind, missingName = 1, "spell", false
  local excluded, cursor = false, false
  local CM = { Constants = {}, DB = { char = { reticleTargeting = true }, global = {} } }
  CM.DbBool = loadedCM.DbBool
  local env = setmetatable({
    C_Spell = {
      IsSpellHelpful = function(spell)
        return spell == 1
      end,
      IsSpellHarmful = function(spell)
        return spell == 2
      end,
      GetSpellInfo = function()
        if missingName then
          return nil
        end
        return { name = "Heal" }
      end,
      GetSpellSubtext = function()
        return "Rank 2"
      end,
    },
    C_CVar = {
      GetCVar = function()
        return "1"
      end,
    },
    strtrim = function(s)
      return s
    end,
  }, { __index = _G })
  env._G = env
  local chunk = assert(loadfile(source))
  setfenv(chunk, env)("CombatMode", CM)
  CM.GetDisplayedActionSlotInfo = function()
    return kind, id, 1
  end
  CM.GetEffectiveBarButtonFrameName = function()
    return "MultiBarBottomLeftButton1"
  end
  CM.IsExcludedFromTargetingSpell = function()
    return excluded
  end
  CM.IsCastAtCursorSpell = function()
    return cursor
  end
  local binding = "MULTIACTIONBAR1BUTTON1"
  local function build(opts)
    return CM.BuildClickCastMacroText(binding, opts)
  end
  kind = "macro"
  check("custom macro slot keeps click route", build(), "/click MultiBarBottomLeftButton1")
  kind = "spell"
  local original = build()
  check("default preserves routing", CM.ShouldSelfCastOutsideSupport(1), false)
  CM.DB.char.supportModeSelfCast = true
  check("helpful spell targets player", build(), "/cast [@player] Heal(Rank 2)")
  check(
    "support mode retains allies",
    build({ support = true }):find("@mouseover", 1, true) ~= nil,
    true
  )
  check("alternate page self cast", build({ page = 2 }), "/cast [@player] Heal(Rank 2)")
  excluded = true
  check("excluded helpful spell still self casts", build(), "/cast [@player] Heal(Rank 2)")
  cursor = true
  check("self cast precedes cursor list", build(), "/cast [@player] Heal(Rank 2)")
  excluded, cursor = false, false
  missingName = true
  check("missing spell data cannot target ally", build(), "/stopmacro")
  missingName = false
  id = 2
  check("harmful spells unchanged", CM.ShouldSelfCastOutsideSupport(id), false)
  check("harmful cast not forced to self", build():find("/cast [@player]", 1, true), nil)
  id = 1
  CM.DB.char.supportModeSelfCast = false
  check("disabling restores previous routing", build(), original)
  CM.DB.char.supportModeSelfCast = true
  CM.DB.char.reticleTargeting = false
  check("disabled reticle targeting", build(), nil)
end
