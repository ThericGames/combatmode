-- Radial Menu slices: up to 5 actions per slot, saved as the 1st plus `more`.
return function(check, CM)
  local oldDB, oldRefresh = CM.DB, CM.RadialRefresh
  CM.DB = { global = {}, char = { radialMenu = { presetsSeeded = true, wheels = {} } } }
  CM.RadialRefresh = nil -- storage only: no secure wheel to re-store

  local wheel = { count = 4, slots = { [1] = { kind = "spell", id = 1 } } }
  CM.DB.char.radialMenu.wheels[1] = wheel

  local function ids(slot)
    local list = {}
    for _, action in ipairs(CM.RadialSlotActions(wheel.slots[slot])) do
      list[#list + 1] = tostring(action.id)
    end
    return table.concat(list, ",")
  end

  check("a one-action save reads unchanged", ids(1), "1")
  check("an empty slot has no actions", ids(2), "")

  for id = 2, 5 do
    check("append " .. id, CM.RadialAddAction(1, 1, { kind = "spell", id = id }), id)
  end
  check("a 6th action is refused", CM.RadialAddAction(1, 1, { kind = "spell", id = 6 }), nil)
  check("five actions in order", ids(1), "1,2,3,4,5")
  check("the 1st stays in the slot itself", wheel.slots[1].id, 1)

  check("make first", CM.RadialMakeFirstAction(1, 1, 3), true)
  check("make first reorders", ids(1), "3,1,2,4,5")

  check("remove the 1st", CM.RadialSetAction(1, 1, 1, nil), true)
  check("the next one is promoted", ids(1), "1,2,4,5")

  check("replace", CM.RadialSetAction(1, 1, 2, { kind = "macro", id = "Heal" }), true)
  check("replace keeps the rest", ids(1), "1,Heal,4,5")
  check("replace past the end", CM.RadialSetAction(1, 1, 5, { kind = "spell", id = 9 }), false)

  check("append to an empty slot", CM.RadialAddAction(1, 2, { kind = "item", id = 8 }), 1)
  check("one action has no extras", wheel.slots[2].more, nil)
  check("remove the last action", CM.RadialSetAction(1, 2, 1, nil), true)
  check("the slot is empty again", wheel.slots[2], nil)

  check("invalid entry refused", CM.RadialAddAction(1, 2, { kind = "spell", id = "x" }), nil)
  wheel.slots[3] =
    { kind = "spell", id = 10, more = { { kind = "bad" }, { kind = "item", id = 11 } } }
  check("invalid saved actions are skipped", ids(3), "10,11")

  local compact = CM.RadialCompact(wheel)
  check("compact keeps filled slots only", #compact, 2)
  check("compact lists every action", #compact[1], 4)

  CM.RadialSetSlot(1, 1, nil)
  check("clearing a slot drops all its actions", ids(1), "")

  -- Presets: a slice can start with several actions; ones the client lacks drop out.
  local isAvailable = CM.RadialActions.IsAvailable
  local missing = {}
  CM.RadialActions.IsAvailable = function(id)
    return not missing[id]
  end
  local function preset(key)
    for _, entry in ipairs(CM.RadialPresetList()) do
      if entry.key == key then
        wheel = entry.build()
        return wheel
      end
    end
  end

  preset("interface")
  check("Interface has 8 slices", wheel.count, 8)
  check("Interface slice 1", ids(1), "character,reputation,currency")
  check("Interface slice 2", ids(2), "talents,spellbookonly")
  check("Interface slice 7", ids(7), "groupfinder,social,guild")

  missing.legacy, missing.spellbookonly = true, true
  preset("interface")
  check("a slice with nothing available is dropped", wheel.count, 7)
  check("the later slices close up", ids(4), "gamemenu,macros,acmoptions")
  check("the spellbook falls back", ids(2), "talents,spellbook")

  missing = { readycheck = true }
  preset("misc")
  check("Misc has 5 slices", wheel.count, 5)
  check("a missing 1st action promotes the next", ids(1), "rolepoll,countdown")

  CM.RadialActions.IsAvailable = isAvailable
  CM.DB, CM.RadialRefresh = oldDB, oldRefresh
end
