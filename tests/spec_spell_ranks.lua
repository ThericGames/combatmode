-- tests/spec_spell_ranks.lua: spell list tokens and ranked cast names in
-- Core/Runtime/SpellRanks.lua.
return function(check, CM, env)
  local Ranks = CM.SpellRanks
  local spells = env.C_Spell
  local saved = { info = spells.GetSpellInfo, subtext = spells.GetSpellSubtext }
  local book = {
    [774] = { "Rejuvenation", "Rank 1" },
    [1058] = { "Rejuvenation", "Rank 2" },
    [8936] = { "Regrowth", "Rank 1" },
    [100] = { "Charge", "" },
    [200] = { "Shadowmeld", "Racial" },
  }
  spells.GetSpellInfo = function(spell)
    if book[spell] then
      return { name = book[spell][1], spellID = spell }
    end
    if spell == "Charge" then
      return { name = "Charge", spellID = 100 }
    end
    return nil
  end
  spells.GetSpellSubtext = function(spell)
    return book[spell] and book[spell][2] or ""
  end

  local exact = Ranks.ParseList("774")
  check("exact entry matches its own ID", Ranks.Matches(exact, 774), true)
  check("exact entry skips another rank", Ranks.Matches(exact, 1058), false)

  local all = Ranks.ParseList(" *774 ")
  check("All Ranks matches its own ID", Ranks.Matches(all, 774), true)
  check("All Ranks matches another rank", Ranks.Matches(all, 1058), true)
  check("All Ranks skips another spell", Ranks.Matches(all, 8936), false)

  local mixed = Ranks.ParseList("#8936, Charge, nonsense, ")
  check("# token", Ranks.Matches(mixed, 8936), true)
  check("name token", Ranks.Matches(mixed, 100), true)
  check("unlisted ID", Ranks.Matches(mixed, 774), false)
  check("non-string list is empty", Ranks.Matches(Ranks.ParseList(nil), 774), false)

  check("ranked cast name", Ranks.RankedName(1058), "Rejuvenation(Rank 2)")
  check("unranked cast name", Ranks.RankedName(100), "Charge")
  check("subtext without a number", Ranks.RankedName(200), "Shadowmeld")
  check("unknown spell has no name", Ranks.RankedName(999), nil)

  spells.GetSpellInfo = saved.info
  spells.GetSpellSubtext = saved.subtext
end
