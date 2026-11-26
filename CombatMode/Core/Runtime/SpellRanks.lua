---------------------------------------------------------------------------------------
--  Core/Runtime/SpellRanks.lua — RUNTIME — spell ranks and spell ID lists
---------------------------------------------------------------------------------------
--  What it does: Publishes CM.SpellRanks: a spell's rank text, its cast name with that rank,
--  and the reader for the spell list CSVs (Excluded Spells, Cast at Crosshair, Party Wheel).
--  Architecture / how it works:
--    • List tokens: "774" is that spell ID only (one rank on Forever / Classic); "*774" (All
--      Ranks) is every spell with the same name as 774. An ID, not a name, is stored, so a
--      list keeps working when the client language changes. Older name tokens still resolve.
--    • ParseList(csv) → { ids = { [id] = true }, names = { [name] = true } }; an All Ranks
--      token adds both its ID and its name. Matches(parsed, id) checks either.
--    • RankedName(id) is "Name(Rank N)" when the rank text holds a number, else the name:
--      casting by name alone would use your highest rank.
--    • Clients without ranks (Mainline) have no numbered rank text.
--  Does not: Decide which spells a list accepts, or build macros.
--  Related: UI/Options/SpellMultiSelect.lua, Core/ClickCasting/TargetingMacroBuilder.lua,
--  Core/RadialMenu/PartyWheel.lua, tests/spec_spell_ranks.lua
---------------------------------------------------------------------------------------
local _, CM = ...
local _G = _G

-- WoW API
local C_Spell = _G.C_Spell

-- Lua stdlib
local next = _G.next
local pcall = _G.pcall
local strtrim = _G.strtrim
local tonumber = _G.tonumber
local type = _G.type

local IsSecret = CM.Safe.IsSecret

local SpellRanks = {}
CM.SpellRanks = SpellRanks

local function PublicText(value)
  if type(value) == "string" and not IsSecret(value) and value ~= "" then
    return value
  end
  return nil
end

local function SpellName(spellId)
  if not (C_Spell and C_Spell.GetSpellInfo) then
    return nil
  end
  local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
  return ok and info and PublicText(info.name) or nil
end

--- Rank text of a spell ("Rank 3") on clients that have ranks (Forever, Classic), else nil.
--- Other subtexts ("Racial") come through too: see IsRanked.
function SpellRanks.Subtext(spellId)
  if not spellId then
    return nil
  end
  local getSubtext = C_Spell and C_Spell.GetSpellSubtext or _G.GetSpellSubtext
  if not getSubtext then
    return nil
  end
  local ok, text = pcall(getSubtext, spellId)
  return ok and PublicText(text) or nil
end

--- True when the spell is one rank of several (its rank text holds a number).
function SpellRanks.IsRanked(spellId)
  local subtext = SpellRanks.Subtext(spellId)
  return subtext ~= nil and subtext:find("%d") ~= nil
end

--- Name to /cast exactly this spell ID: "Name(Rank N)" for a ranked spell. nil = no name yet.
function SpellRanks.RankedName(spellId)
  local name = SpellName(spellId)
  if not name then
    return nil
  end
  if SpellRanks.IsRanked(spellId) then
    return name .. "(" .. SpellRanks.Subtext(spellId) .. ")"
  end
  return name
end

--- Parses a spell list CSV (see the header for the token forms).
function SpellRanks.ParseList(csv)
  local parsed = { ids = {}, names = {} }
  if type(csv) ~= "string" then
    return parsed
  end
  for entry in csv:gmatch("[^,]+") do
    local token = strtrim(entry)
    local allRanks = token:sub(1, 1) == "*"
    if allRanks then
      token = strtrim(token:sub(2))
    end
    if token ~= "" then
      local id = tonumber((token:gsub("^#", "")))
      if not id and C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(token)
        id = info and (info.spellID or info.spellId)
      end
      if id and id > 0 then
        parsed.ids[id] = true
        local name = allRanks and SpellName(id)
        if name then
          parsed.names[name] = true
        end
      end
    end
  end
  return parsed
end

--- True when the parsed list holds this spell ID, or All Ranks of its name.
function SpellRanks.Matches(parsed, spellId)
  if parsed.ids[spellId] then
    return true
  end
  if next(parsed.names) == nil then
    return false
  end
  local name = SpellName(spellId)
  return name ~= nil and parsed.names[name] == true
end
