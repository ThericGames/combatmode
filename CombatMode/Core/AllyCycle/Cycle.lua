---------------------------------------------------------------------------------------
--  Core/AllyCycle/Cycle.lua — ALLYCYCLE — secure UP/DOWN party/raid targeting
---------------------------------------------------------------------------------------
--  What it does: Secure Up/Down hard-target through group/index order. Skip Self
--  (default on) omits the player from the roster.
--  Architecture / how it works:
--    • SecureActionButton + key-up wrap; ASC/DESC headers; takeNext; restore-if-lost
--      via PlayerCanAssist (RestrictedEnv has no UnitIsUnit). Frame refs must be
--      SecureGroupHeaderTemplate.
--    • skipPlayer attribute set OOC from DB (RestrictedEnv cannot read CM.DB).
--    • Also Cycle Through (allyCycle.extraUnits CSV playerPet|partyPets → extraPlayerPet /
--      extraPartyPets attributes): the snippet walks members, then "pet", then partypet1-4 /
--      raidpet1-40 (own raidpetN skipped), backwards for Previous. CM.IsAllyCycleExtraUnit
--      and GetAllyCycleIndex use the same tokens (CollectExtraUnits).
--    • PrepareCycle / ResetAllyCycleCursor OOC only (SetAttribute is lockdown-blocked).
--    • GetAllyCycleIndex for the HUD (reuses a child scratch table); NotifyCycle on
--      advance (not restore) plays the Radial Menu's slice-aim click.
--    • CM.Profile keys: AllyCycle:GetIndex / ApplyBindings / RefreshRoster.
--    • Away members: offline or in another zone / instance are skipped (away-<unit> attributes
--      mirrored by CM.RefreshAllyCycleAvailability out of combat; distance alone never skips).
--  Does not: Own HUD chrome or click-cast prelines.
--  Related: Core/AllyCycle/{Target,HealthBar,Motion,HUD,AllyCycle}.lua, Core/ClickCasting/BindingOverrides.lua,
--  Core/Runtime/BindingQueue.lua, UI/Options/Tabs/TabAllyCycle.lua, Bindings.xml
---------------------------------------------------------------------------------------
local _, CM = ...
local L = CM.L
local _G = _G

-- WoW API
local ClearOverrideBindings = _G.ClearOverrideBindings
local CreateFrame = _G.CreateFrame
local GetBindingKey = _G.GetBindingKey
local GetNormalizedRealmName = _G.GetNormalizedRealmName
local GetRealmName = _G.GetRealmName
local InCombatLockdown = _G.InCombatLockdown
local IsInGroup = _G.IsInGroup
local IsInRaid = _G.IsInRaid
local C_Map = _G.C_Map
local C_Timer = _G.C_Timer
local PlaySound = _G.PlaySound
local SOUNDKIT = _G.SOUNDKIT
local SecureHandlerSetFrameRef = _G.SecureHandlerSetFrameRef
local SecureHandlerWrapScript = _G.SecureHandlerWrapScript
local SetOverrideBindingClick = _G.SetOverrideBindingClick
local UIParent = _G.UIParent
local UnitExists = _G.UnitExists
local UnitIsConnected = _G.UnitIsConnected
local UnitIsVisible = _G.UnitIsVisible
local UnitIsUnit = _G.UnitIsUnit
local UnitName = _G.UnitName

-- Lua stdlib
local ipairs = _G.ipairs
local select = _G.select
local tostring = _G.tostring
local type = _G.type
local wipe = _G.wipe

local BIND_UP = "Combat Mode - Ally Cycle Next"
local BIND_DOWN = "Combat Mode - Ally Cycle Previous"
local GROUPS = "1,2,3,4,5,6,7,8"
local INITIAL_CONFIG = [[
    self:SetWidth(1)
    self:SetHeight(1)
    self:EnableMouse(false)
  ]]
-- Same click as the Radial Menu aiming a slice (RadialMenu/View.lua SOUNDS.aim).
local ALLY_CYCLE_SOUND = (SOUNDKIT and SOUNDKIT.U_CHAT_SCROLL_BUTTON) or 1115

local OverrideOwner = CreateFrame("Frame", "CombatModeAllyCycleOverrideOwner", UIParent)
local CycleButton =
  CreateFrame("Button", "CombatModeAllyCycle", OverrideOwner, "SecureActionButtonTemplate")
-- Key-up only: AnyUp+AnyDown would advance twice per press (skipping members).
CycleButton:RegisterForClicks("AnyUp")
CycleButton:SetAttribute("useOnKeyDown", false)
CycleButton:SetAttribute("checkselfcast", false)
CycleButton:SetAttribute("checkfocuscast", false)
CycleButton:SetAttribute("checkmouseovercast", false)
CycleButton:SetAttribute("type", "target")
CycleButton:Hide()

local function CreateGroupHeader(name, sortDir)
  local header = CreateFrame("Frame", name, UIParent, "SecureGroupHeaderTemplate")
  header:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
  header:SetSize(1, 1)
  header:SetAlpha(0)
  header:EnableMouse(false)
  header:SetAttribute("showRaid", true)
  header:SetAttribute("showParty", true)
  header:SetAttribute("showPlayer", true)
  header:SetAttribute("showSolo", true)
  header:SetAttribute("groupFilter", GROUPS)
  header:SetAttribute("groupBy", "GROUP")
  header:SetAttribute("groupingOrder", GROUPS)
  header:SetAttribute("sortMethod", "INDEX")
  header:SetAttribute("sortDir", sortDir or "ASC")
  header:SetAttribute("template", "SecureUnitButtonTemplate")
  header:SetAttribute("initialConfigFunction", INITIAL_CONFIG)
  -- SecureGroupHeaderTemplate only populates while shown.
  header:Show()
  return header
end

-- Name-filtered header → player's secure unit token (raidN / player).
local SelfHeader =
  CreateFrame("Frame", "CombatModeAllyCycleSelfHeader", UIParent, "SecureGroupHeaderTemplate")
SelfHeader:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
SelfHeader:SetSize(1, 1)
SelfHeader:SetAlpha(0)
SelfHeader:EnableMouse(false)
SelfHeader:SetAttribute("showRaid", true)
SelfHeader:SetAttribute("showParty", true)
SelfHeader:SetAttribute("showPlayer", true)
SelfHeader:SetAttribute("showSolo", true)
SelfHeader:SetAttribute("template", "SecureUnitButtonTemplate")
SelfHeader:SetAttribute("initialConfigFunction", INITIAL_CONFIG)
SelfHeader:Show()

local GroupAsc = CreateGroupHeader("CombatModeAllyCycleGroupAsc", "ASC")
local GroupDesc = CreateGroupHeader("CombatModeAllyCycleGroupDesc", "DESC")

local function EnsureSelfHeaderNameList()
  if InCombatLockdown and InCombatLockdown() then
    return
  end
  local playerName = UnitName and UnitName("player")
  if not playerName then
    return
  end
  local realmName = GetNormalizedRealmName and GetNormalizedRealmName()
  if (not realmName or realmName == "") and GetRealmName then
    realmName = GetRealmName()
  end
  local nameList = playerName
  if realmName and realmName ~= "" then
    nameList = nameList .. "," .. playerName .. "-" .. realmName
  end
  SelfHeader:SetAttribute("nameList", nameList)
  SelfHeader:Show()
end

function CM.IsAllyCycleSkipPlayer()
  local ac = CM.DB and CM.DB.global and CM.DB.global.allyCycle
  if ac and ac.skipPlayer == false then
    return false
  end
  return true
end

local IsSecret = CM.Safe.IsSecret
local PublicBool = CM.Safe.PublicBool

--- Extra units cycled after the group (`allyCycle.extraUnits`, CSV of playerPet | partyPets).
--- Returns playerPet, partyPets booleans. The secure snippet reads them as attributes.
function CM.GetAllyCycleExtraUnits()
  local ac = CM.DB and CM.DB.global and CM.DB.global.allyCycle
  local csv = ac and ac.extraUnits
  local playerPet, partyPets = false, false
  if type(csv) == "string" then
    for key in csv:gmatch("[^,]+") do
      if key == "playerPet" then
        playerPet = true
      elseif key == "partyPets" then
        partyPets = true
      end
    end
  end
  return playerPet, partyPets
end

function CM.SetAllyCycleExtraUnits(csv)
  local ac = CM.DB and CM.DB.global and CM.DB.global.allyCycle
  if not ac then
    return
  end
  ac.extraUnits = csv or ""
  CM.ResetAllyCycleCursor()
  CM.ApplyAllyCycleBindings()
end

-- Pet unit tokens, in cycle order after the group (the secure snippet builds the same ones).
local PARTY_PET_TOKENS = {}
for n = 1, 4 do
  PARTY_PET_TOKENS[n] = "partypet" .. n
end
local RAID_PET_TOKENS = {}
for n = 1, 40 do
  RAID_PET_TOKENS[n] = "raidpet" .. n
end

local extraScratch = {}

-- Existing extra-unit tokens for the enabled kinds: "pet" first, then others' pets. In a raid the
-- player's own raidpetN is left out (it is "pet").
local function CollectExtraUnits(dest)
  wipe(dest)
  local playerPet, partyPets = CM.GetAllyCycleExtraUnits()
  if not (playerPet or partyPets) then
    return dest
  end
  if playerPet and UnitExists("pet") then
    dest[#dest + 1] = "pet"
  end
  if partyPets then
    local raid = IsInRaid and IsInRaid()
    local tokens = raid and RAID_PET_TOKENS or PARTY_PET_TOKENS
    for i = 1, #tokens do
      local token = tokens[i]
      if UnitExists(token) then
        local isOwn = raid and UnitIsUnit and PublicBool(UnitIsUnit(token, "pet")) == true
        if not isOwn then
          dest[#dest + 1] = token
        end
      end
    end
  end
  return dest
end

--- True when `unit` (e.g. "target") is one of the enabled extra units.
function CM.IsAllyCycleExtraUnit(unit)
  if not unit or not UnitIsUnit then
    return false
  end
  local extras = CollectExtraUnits(extraScratch)
  for i = 1, #extras do
    if PublicBool(UnitIsUnit(extras[i], unit)) == true then
      return true
    end
  end
  return false
end

-- OOC only: SetAttribute on this button is lockdown-blocked.
function CycleButton:PrepareCycle()
  if InCombatLockdown and InCombatLockdown() then
    return
  end
  if not UnitExists("target") then
    return
  end
  local skipPlayer = CM.IsAllyCycleSkipPlayer()
  if skipPlayer and UnitIsUnit and UnitIsUnit("target", "player") then
    return
  end
  local children = { GroupAsc:GetChildren() }
  for _, child in ipairs(children) do
    local unit = child.GetAttribute and child:GetAttribute("unit")
    if unit and UnitExists(unit) and UnitIsUnit and UnitIsUnit(unit, "target") then
      local isSelf = unit == "player" or UnitIsUnit(unit, "player")
      if not skipPlayer or not isSelf then
        self:SetAttribute("lastUnit", unit)
      end
      return
    end
  end
  -- Target is not a group member: it may be one of the extra units (pets).
  local extras = CollectExtraUnits(extraScratch)
  for _, token in ipairs(extras) do
    if UnitIsUnit and PublicBool(UnitIsUnit(token, "target")) == true then
      self:SetAttribute("lastUnit", token)
      return
    end
  end
end

if SecureHandlerSetFrameRef then
  SecureHandlerSetFrameRef(CycleButton, "selfHeader", SelfHeader)
  SecureHandlerSetFrameRef(CycleButton, "groupAsc", GroupAsc)
  SecureHandlerSetFrameRef(CycleButton, "groupDesc", GroupDesc)
end

if SecureHandlerWrapScript then
  SecureHandlerWrapScript(
    CycleButton,
    "OnClick",
    CycleButton,
    [[
      if down then
        return false
      end

      self:CallMethod("PrepareCycle")

      local mode = SecureCmdOptionParse("[group:raid] raid;[group:party] party;solo")
      -- Solo still cycles your pet(s) when Also Cycle Through is on (the headers show you alone).
      if mode == "solo" and not (self:GetAttribute("extraPlayerPet") or self:GetAttribute("extraPartyPets")) then
        self:SetAttribute("unit", nil)
        self:SetAttribute("lastUnit", nil)
        return
      end

      local selfHeader = self:GetFrameRef("selfHeader")
      local selfMember = selfHeader and selfHeader:GetChildren()
      local selfUnit = selfMember and selfMember:GetAttribute("unit")

      local goDown = button == "RightButton"
      local header = goDown and self:GetFrameRef("groupDesc") or self:GetFrameRef("groupAsc")
      local lastUnit = self:GetAttribute("lastUnit")

      local signature = mode .. "|" .. (selfUnit or "")
      local asc = self:GetFrameRef("groupAsc")
      if asc then
        for slot = 1, 40 do
          local member = asc:GetFrameRef("child" .. slot)
          local unit = member and member:GetAttribute("unit")
          if unit and UnitExists(unit) then
            signature = signature .. ";" .. unit
          end
        end
      end
      -- Extra units (pets) cycled after the group; flags are mirrored from the DB out of combat.
      local playerPet = self:GetAttribute("extraPlayerPet")
      local partyPets = self:GetAttribute("extraPartyPets")
      if playerPet and UnitExists("pet") then
        signature = signature .. ";pet"
      end
      if partyPets then
        for n = 1, 40 do
          if mode == "raid" or n <= 4 then
            local token = (mode == "raid" and "raidpet" or "partypet") .. n
            if UnitExists(token) then
              signature = signature .. ";" .. token
            end
          end
        end
      end
      if mode ~= self:GetAttribute("mode") or signature ~= self:GetAttribute("rosterSignature") then
        lastUnit = nil
      end
      self:SetAttribute("mode", mode)
      self:SetAttribute("rosterSignature", signature)

      local firstUnit = nil
      local chosen = nil
      local takeNext = false

      -- RestrictedEnv: no UnitIsUnit. Restore lastUnit if target is gone / not assistable.
      if lastUnit and UnitExists(lastUnit) and not self:GetAttribute("away-" .. lastUnit)
        and (not UnitExists("target") or not PlayerCanAssist("target"))
      then
        chosen = lastUnit
      end

      local skipPlayer = self:GetAttribute("skipPlayer") ~= false

      if not chosen and header then
        -- Order: group members (slots 1-40), then "pet", then others' pets (41 slots). Previous
        -- (goDown) walks it backwards: pets 41..1, then the DESC header's members.
        for k = 1, 81 do
          local pet = 0
          if goDown then
            if k <= 41 then
              pet = 42 - k
            end
          elseif k > 40 then
            pet = k - 40
          end
          local unit = nil
          if pet == 0 then
            local member = header:GetFrameRef("child" .. (goDown and (k - 41) or k))
            unit = member and member:GetAttribute("unit")
          elseif pet == 1 then
            if playerPet then
              unit = "pet"
            end
          elseif partyPets then
            local n = pet - 1
            if mode == "raid" then
              if not (selfUnit and selfUnit == "raid" .. n) then
                unit = "raidpet" .. n
              end
            elseif n <= 4 then
              unit = "partypet" .. n
            end
          end
          local isSelf = unit == "player" or (selfUnit and unit == selfUnit)
          if unit and UnitExists(unit) and not (skipPlayer and isSelf) then
            -- away-<unit>: offline / in another zone or instance (set out of combat by
            -- CM.RefreshAllyCycleAvailability). A skipped lastUnit still moves the cursor on.
            local away = self:GetAttribute("away-" .. unit)
            if away then
              self:CallMethod("DebugCycle", "skipped " .. unit)
            end
            if not away and not firstUnit then
              firstUnit = unit
            end
            if takeNext and not away then
              chosen = unit
              break
            end
            if lastUnit and unit == lastUnit then
              takeNext = true
            end
          end
        end
      end

      if not chosen then
        chosen = firstUnit
      end

      self:CallMethod("DebugCycle", "chose " .. (chosen or "nobody"))

      if chosen and UnitExists(chosen) then
        local advanced = (not lastUnit) or (chosen ~= lastUnit)
        self:SetAttribute("unit", chosen)
        self:SetAttribute("lastUnit", chosen)
        if advanced then
          self:CallMethod("NotifyCycle", goDown and "down" or "up")
        end
      else
        self:SetAttribute("unit", nil)
        self:SetAttribute("lastUnit", nil)
      end
    ]]
  )
end

-- Debug Mode only: what the secure snippet saw / picked on the last press.
function CycleButton:DebugCycle(text)
  CM.DebugPrint("Ally Cycle press: " .. tostring(text))
end

function CycleButton:NotifyCycle(direction)
  if PlaySound and CM.IsSoundEnabled("soundAllyCycle") then
    PlaySound(ALLY_CYCLE_SOUND, "Master", true)
  end
  if CM.NotifyAllyCycleHUD then
    CM.NotifyAllyCycleHUD(direction)
  end
end

local function RefreshAllyCycleRosterImpl()
  EnsureSelfHeaderNameList()
  if SelfHeader and not SelfHeader:IsShown() then
    SelfHeader:Show()
  end
  if GroupAsc and not GroupAsc:IsShown() then
    GroupAsc:Show()
  end
  if GroupDesc and not GroupDesc:IsShown() then
    GroupDesc:Show()
  end
  if CM.RefreshAllyCycleAvailability then
    CM.RefreshAllyCycleAvailability()
  end
  CM.DebugPrint("Ally Cycle roster refreshed")
end

function CM.RefreshAllyCycleRoster()
  return CM.Profile("AllyCycle:RefreshRoster", RefreshAllyCycleRosterImpl)
end

function CM.FlushPendingAllyCycleRoster()
  CM.RefreshAllyCycleRoster()
end

local rosterKids = {}

local function PackInto(dest, ...)
  local n = select("#", ...)
  for i = 1, n do
    dest[i] = select(i, ...)
  end
  for i = n + 1, #dest do
    dest[i] = nil
  end
end

local function CollectHeaderChildren(header)
  if not header then
    if wipe then
      wipe(rosterKids)
    end
    return rosterKids
  end
  PackInto(rosterKids, header:GetChildren())
  return rosterKids
end

local function IsPlayerUnit(unit)
  if not unit then
    return false
  end
  if unit == "player" then
    return true
  end
  if not UnitIsUnit then
    return false
  end
  return PublicBool(UnitIsUnit(unit, "player")) == true
end

-- Members the cycle skips: offline, or in another zone / instance. The restricted snippet cannot
-- call UnitIsConnected / UnitIsVisible / map APIs, and attributes on the secure button cannot change
-- in combat, so this runs here and is mirrored to `away-<unit>` attributes out of combat only.
-- Distance alone never flags anyone (an ally far away at the pull must stay cycle-able once they
-- arrive mid-fight): "not visible" only counts together with being on another map.
local awayUnits = {} -- unit token -> true while flagged (mirrors the away-<unit> attributes)
local seenUnits = {}
local pendingAvailability = false

local lastLoggedAway = {}

local function Show(v)
  if v == nil then
    return "nil"
  end
  if IsSecret(v) then
    return "secret"
  end
  return tostring(v)
end

-- Debug Mode only: what the availability check saw for `unit`, printed when it changes.
local function DebugLogAway(unit, connected, visible, theirs, mine, away)
  if not (CM.DB and CM.DB.global and CM.DB.global.debugMode) then
    return
  end
  local line = "connected="
    .. Show(connected)
    .. " visible="
    .. Show(visible)
    .. " map="
    .. Show(theirs)
    .. " myMap="
    .. Show(mine)
    .. " away="
    .. tostring(away)
  if lastLoggedAway[unit] ~= line then
    lastLoggedAway[unit] = line
    CM.DebugPrint("Ally Cycle " .. unit .. " (" .. Show(UnitName(unit)) .. "): " .. line)
  end
end

local function IsMemberAway(unit)
  if IsPlayerUnit(unit) then
    return false
  end
  local connected = UnitIsConnected and UnitIsConnected(unit)
  local visible = UnitIsVisible and UnitIsVisible(unit)
  local getMap = C_Map and C_Map.GetBestMapForUnit
  local theirs, mine
  if getMap then
    theirs, mine = getMap(unit), getMap("player")
  end
  local away = false
  if PublicBool(connected) == false then
    away = true
  elseif PublicBool(visible) == false and getMap then
    -- Secret / unknown results fail soft (available).
    if not (IsSecret(theirs) or IsSecret(mine) or mine == nil) then
      away = theirs ~= mine
    end
  end
  DebugLogAway(unit, connected, visible, theirs, mine, away)
  return away
end

local function SetMemberAway(unit, away)
  if (awayUnits[unit] or false) == away then
    return false
  end
  awayUnits[unit] = away or nil
  CycleButton:SetAttribute("away-" .. unit, away or nil)
  CM.DebugPrint(
    "Ally Cycle flag away-"
      .. unit
      .. " = "
      .. tostring(away)
      .. " (button reads "
      .. tostring(CycleButton:GetAttribute("away-" .. unit))
      .. ")"
  )
  return true
end

function CM.RefreshAllyCycleAvailability()
  if InCombatLockdown and InCombatLockdown() then
    pendingAvailability = true
    return
  end
  pendingAvailability = false
  if not GroupAsc then
    return
  end
  local changed = false
  wipe(seenUnits)
  local children = CollectHeaderChildren(GroupAsc)
  for _, child in ipairs(children) do
    local unit = child.GetAttribute and child:GetAttribute("unit")
    if unit then
      seenUnits[unit] = true
      local exists = UnitExists(unit)
      local away = (IsSecret(exists) or exists) and IsMemberAway(unit) or false
      if SetMemberAway(unit, away) then
        changed = true
      end
    end
  end
  for unit in pairs(awayUnits) do
    if not seenUnits[unit] and SetMemberAway(unit, false) then
      changed = true
    end
  end
  if changed and CM.RefreshAllyCycleHUD then
    CM.RefreshAllyCycleHUD()
  end
end

-- Another member's zone / connection can change with no event (walking through a portal in an
-- instance, a delayed disconnect), so recheck about once a second while grouped and out of combat.
if C_Timer and C_Timer.NewTicker then
  C_Timer.NewTicker(1, function()
    if
      pendingAvailability
      or (IsInGroup and IsInGroup() and not (InCombatLockdown and InCombatLockdown()))
    then
      CM.RefreshAllyCycleAvailability()
    end
  end)
end

local function GetAllyCycleIndexImpl(unit)
  unit = unit or "target"
  local total = 0
  local current = nil
  if not GroupAsc then
    return nil, 0
  end
  local skipSelf = CM.IsAllyCycleSkipPlayer()
  local children = CollectHeaderChildren(GroupAsc)
  for _, child in ipairs(children) do
    local slot = child.GetAttribute and child:GetAttribute("unit")
    if slot then
      local exists = UnitExists(slot)
      if IsSecret(exists) or exists then
        if (not skipSelf or not IsPlayerUnit(slot)) and not awayUnits[slot] then
          total = total + 1
          if unit and UnitIsUnit and PublicBool(UnitIsUnit(slot, unit)) == true then
            current = total
          end
        end
      end
    end
  end
  -- Extra units (pets) count after the group, in cycle order.
  local extras = CollectExtraUnits(extraScratch)
  for _, token in ipairs(extras) do
    total = total + 1
    if unit and UnitIsUnit and PublicBool(UnitIsUnit(token, unit)) == true then
      current = total
    end
  end
  return current, total
end

function CM.GetAllyCycleIndex(unit)
  return CM.Profile("AllyCycle:GetIndex", GetAllyCycleIndexImpl, unit)
end

function CM.ResetAllyCycleCursor()
  if InCombatLockdown and InCombatLockdown() then
    return
  end
  CycleButton:SetAttribute("lastUnit", nil)
end

function CM.IsAllyCycleEnabled()
  if not GetBindingKey then
    return false
  end
  return (GetBindingKey(BIND_UP) or GetBindingKey(BIND_DOWN)) and true or false
end

local function ApplyAllyCycleBindingsImpl()
  CycleButton:SetAttribute("skipPlayer", CM.IsAllyCycleSkipPlayer())
  local playerPet, partyPets = CM.GetAllyCycleExtraUnits()
  CycleButton:SetAttribute("extraPlayerPet", playerPet)
  CycleButton:SetAttribute("extraPartyPets", partyPets)
  ClearOverrideBindings(OverrideOwner)
  if not CM.IsAllyCycleEnabled() then
    CM.DebugPrint("Ally Cycle bindings cleared (unbound)")
    if CM.RefreshAllyCycleHUD then
      CM.RefreshAllyCycleHUD()
    end
    return
  end
  CM.RefreshAllyCycleRoster()
  local upKey = GetBindingKey(BIND_UP)
  if upKey then
    SetOverrideBindingClick(OverrideOwner, false, upKey, CycleButton:GetName(), "LeftButton")
  end
  local downKey = GetBindingKey(BIND_DOWN)
  if downKey then
    SetOverrideBindingClick(OverrideOwner, false, downKey, CycleButton:GetName(), "RightButton")
  end
  CM.DebugPrint(
    "Ally Cycle bindings applied up=" .. tostring(upKey) .. " down=" .. tostring(downKey)
  )
  if CM.RefreshAllyCycleHUD then
    CM.RefreshAllyCycleHUD()
  end
end

function CM.ApplyAllyCycleBindings()
  if InCombatLockdown() then
    if CM.TryApplyBindingChange then
      CM.TryApplyBindingChange(L["ally cycle bindings"], function()
        CM.ApplyAllyCycleBindings()
      end)
    end
    return
  end
  return CM.Profile("AllyCycle:ApplyBindings", ApplyAllyCycleBindingsImpl)
end

CM.AllyCycleBindUp = BIND_UP
CM.AllyCycleBindDown = BIND_DOWN

function _G.CombatMode_AllyCycleUp() end
function _G.CombatMode_AllyCycleDown() end
