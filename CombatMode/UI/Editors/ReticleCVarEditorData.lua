---------------------------------------------------------------------------------------
--  UI/Editors/ReticleCVarEditorData.lua — EDITOR — reticle CVar override data
---------------------------------------------------------------------------------------
--  What it does: Data layer for the Reticle CVar editor: row lists from
--  ReticleTargetingCVarValues minus exclusions, read/write of
--  global.reticleTargetingCVarOverrides via CVarManager getters, combat-guarded writes,
--  and row descriptions (hand-written one-liner + tooltip details first, then ConsoleGetAllCommands help text).
--  Architecture / how it works:
--    • CM.ReticleCVarEditorData helpers; Panel owns the window + live attribution.
--    • Effective values still computed in CVarManager.GetEffectiveReticleTargetingCVarValues.
--  Does not: Draw the editor chrome or hook SetCVar for source attribution.
--  Related: Constants/CVars.lua, Core/Runtime/CVarManager.lua,
--  UI/Editors/ReticleCVarEditorPanel.lua, Constants/DatabaseDefaults.lua,
--  UI/Options/Tabs/TabReticleTargeting.lua
---------------------------------------------------------------------------------------
local _, CM = ...
local L = CM.L
local _G = _G

-- WoW API
local ConsoleGetAllCommands = _G.ConsoleGetAllCommands
local GetCVar = _G.GetCVar
local InCombatLockdown = _G.InCombatLockdown
local pairs = _G.pairs
local wipe = _G.wipe
local strtrim = _G.strtrim
local tonumber = _G.tonumber
local tostring = _G.tostring
local type = _G.type
local strlower = _G.strlower

CM.ReticleCVarEditorData = CM.ReticleCVarEditorData or {}
local Data = CM.ReticleCVarEditorData

local cvarDescriptions = nil
local cachedLowerToCanonical = nil
local cachedExcludedLower = nil

local function EnsureCaches()
  if cachedLowerToCanonical and cachedExcludedLower then
    return
  end

  cachedLowerToCanonical = {}
  cachedExcludedLower = {}

  for cvar in pairs(CM.Constants.ReticleTargetingCVarValues) do
    cachedLowerToCanonical[strlower(cvar)] = cvar
  end

  local excluded = CM.Constants.ReticleTargetingCVarEditorExcluded
  if type(excluded) == "table" then
    for cvar in pairs(excluded) do
      cachedExcludedLower[strlower(cvar)] = true
    end
  end
end

function Data.CanonicalCVar(cvarName)
  if type(cvarName) ~= "string" then
    return nil
  end
  EnsureCaches()
  local map = cachedLowerToCanonical or {}
  return map[strlower(cvarName)]
end

function Data.IsTrackedCVar(cvarName)
  return Data.CanonicalCVar(cvarName) ~= nil
end

function Data.IsEditableCVar(cvarName)
  local canonical = Data.CanonicalCVar(cvarName)
  if not canonical then
    return false
  end
  EnsureCaches()
  local excluded = cachedExcludedLower or {}
  return not excluded[strlower(canonical)]
end
-- Our own wording wins; the game's help text only fills CVars not listed here. The first
-- sentence (`writtenDescriptions`) is what the table's one-line column shows; the tooltip adds
-- `writtenDetails`: what the values mean, what Combat Mode sets and why, and which feature
-- depends on it. Keep both in step with the comments in Constants/CVars.lua.
local writtenDescriptions = {
  SoftTargetForce = "Automatically makes the soft target your hard target.",
  SoftTargetMatchLocked = "Pins the soft target to your hard target while you have one.",
  SoftTargetWithLocked = "Keeps soft targeting running while you have a hard target.",
  SoftTargetEnemy = "When enemy soft targeting is on (0 off, 1 gamepad, 2 mouse and keyboard, 3 always).",
  SoftTargetEnemyArc = "How far off-centre in front of you an enemy can be soft targeted.",
  SoftTargetEnemyRange = "Furthest distance an enemy can be soft targeted.",
  SoftTargetInteract = "When soft interact is on (0 off, 1 gamepad, 2 mouse and keyboard, 3 always).",
  SoftTargetInteractArc = "How far off-centre in front of you an interactable can be picked.",
  SoftTargetInteractRange = "Furthest distance an NPC or object can be soft targeted to interact.",
  SoftTargetFriend = "When friendly soft targeting is on (0 off, 1 gamepad, 2 mouse and keyboard, 3 always).",
  SoftTargetFriendArc = "How far off-centre in front of you a friendly unit can be soft targeted.",
  SoftTargetFriendRange = "Furthest distance a friendly unit can be soft targeted.",
  SoftTargetNameplateEnemy = "Always shows the nameplate of the soft enemy target.",
  SoftTargetIconEnemy = "Draws Blizzard's icon over the soft enemy target.",
  SoftTargetIconFriend = "Draws Blizzard's icon over the soft friendly target.",
  SoftTargetIconInteract = "Draws Blizzard's icon over the soft interact target.",
  SoftTargetIconGameObject = "Draws Blizzard's icon over the soft game object target.",
}

local writtenDetails = {
  SoftTargetForce = "0 = never, 1 = for enemies, 2 = for friends. Combat Mode uses 0: the reticle only soft targets, and Reticle Targeting casts, click-casts and Target Lock pick the unit under the crosshair themselves. Your hard target stays what you chose (a Target Lock, an Ally Cycle pick). Any other value turns every unit you aim at into your target.",
  SoftTargetMatchLocked = '0 = off, 1 = follow your hard target, 2 = follow it only for targets you are attacking. Combat Mode uses 1. Normally the soft target is whatever is in front of you, so its circle or name can sit on a different unit than your target. With 1 it stays glued to the hard target while you have one, and aiming at another enemy does not move it.\n\nSelection Circle\'s "Hard target" and "Locked target only" modes need this at 1, otherwise Blizzard\'s circle could land on another unit. In Support Mode it also puts the friendly soft target on a locked ally, which is why Switch Target never uses it.',
  SoftTargetWithLocked = "Combat Mode uses 2 (always). SoftTargetMatchLocked decides where the soft target sits when you hold a target; this one decides whether soft selection runs at all then. With 2 it never pauses, so the Interaction HUD, the friendly soft target Support Mode casts on and the enemy picks keep updating while a hard target is held. The hard target still wins for casts.",
  SoftTargetEnemy = "Combat Mode uses 3. It has to stay on for the reticle to pick an enemy through friendly units standing in front of it. With 0, casts only reach the enemy directly under the crosshair or your hard target. Blizzard's default is 1 (gamepad only).",
  SoftTargetEnemyArc = "0 = strictly forward, 1 = wider forward arc, 2 = anywhere in front. Combat Mode uses 0 (Blizzard 2): only enemies right in front of the centred character count, which suits the crosshair and ranks stacked enemies sensibly. 1 or 2 makes distant enemies easier to catch but picks get messy in crowds. Mouse Look keeps the character facing the camera, so this follows where the reticle points.",
  SoftTargetEnemyRange = "Combat Mode uses 60 yards (Blizzard 45). The game still caps it at tab-targeting range, so very high values do nothing extra. Lower it to ignore far enemies.",
  SoftTargetInteract = "Combat Mode uses 3 (Blizzard 1, gamepad only). The Interaction HUD, the Interactable Indicator and the Interact key read the soft interact target, so this stays on even when Reticle Targeting is off and only the HUD is enabled.",
  SoftTargetInteractArc = "0 = strictly forward, 1 = wider forward arc, 2 = anywhere in front. Combat Mode uses 1 (Blizzard 0): NPCs and objects don't need precise aiming, and demanding it is annoying.",
  SoftTargetInteractRange = "Combat Mode uses 15 yards (Blizzard 10). The game also limits it by tab-targeting range and each object's own interact range.",
  SoftTargetFriend = "Combat Mode keeps it at 0, because Reticle Targeting is enemy-only and allies are handled by Ally Cycle, Support Mode and the Party Wheel. Support Mode forces it to 3 for as long as it is on: its heals fall back to @softfriend, the ally in front of you, since a friendly nameplate is not a mouseover unit in Mouse Look. Characters that had Ignore Friendlies off before 5.5.0 start with 3 here.",
  SoftTargetFriendArc = '0 = strictly forward, 1 = wider forward arc, 2 = anywhere in front. Combat Mode uses 0. Blizzard picks the soft friend from an arc in front of the character, not from the crosshair, so this decides how loose Support Mode\'s "ally in front of you" is. Only matters while SoftTargetFriend is on.',
  SoftTargetFriendRange = "Combat Mode uses 60 yards. The game caps it at tab-targeting range. Only matters while SoftTargetFriend is on (Support Mode forces it).",
  SoftTargetNameplateEnemy = "Combat Mode uses 0: the reticle already shows what you are aiming at. 1 makes Blizzard draw the nameplate for the soft enemy even when nameplates are otherwise hidden.",
  SoftTargetIconEnemy = "Combat Mode always turns it off so it doesn't stack with the reticle (use 1 to show Blizzard's icon anyway). It is not written while only the Interaction HUD is on.",
  SoftTargetIconFriend = "Combat Mode hides it (0) only while the Interactable Indicator is on, since the indicator already shows friendly targets. With the indicator off your own value is left alone, unless you set one here.",
  SoftTargetIconInteract = "Combat Mode hides it (0) only while the Interactable Indicator is on, since the indicator already shows interactables. With the indicator off your own value is left alone, unless you set one here. Blizzard's Accessibility option for interaction key icons uses it.",
  SoftTargetIconGameObject = "Combat Mode hides it (0) only while the Interactable Indicator is on, since the indicator already shows objects. With the indicator off your own value is left alone, unless you set one here.",
}

local function BuildDescriptionMap()
  cvarDescriptions = {}
  if not ConsoleGetAllCommands then
    return
  end

  local commands = ConsoleGetAllCommands()
  for _, info in pairs(commands or {}) do
    local cvar = info and info.command
    local canonical = cvar and Data.CanonicalCVar(cvar)
    if canonical then
      cvarDescriptions[canonical] = info.help or ""
    end
  end
end

local function GetDescription(cvar)
  local written = writtenDescriptions[cvar]
  if written then
    return written, writtenDetails[cvar]
  end
  if not cvarDescriptions then
    BuildDescriptionMap()
  end
  local descriptions = cvarDescriptions or {}
  return descriptions[cvar] or ""
end

function Data.GetOverrides()
  return CM.GetReticleTargetingCVarOverrides()
end

function Data.GetRows()
  local rows = {}
  local defaults = CM.Constants.ReticleTargetingCVarValues
  local overrides = Data.GetOverrides()

  for cvar, defaultValue in pairs(defaults) do
    if Data.IsEditableCVar(cvar) then
      local overrideValue = overrides[cvar]
      local effectiveValue = overrideValue ~= nil and overrideValue or defaultValue
      local currentValue = GetCVar(cvar) or ""
      local description, details = GetDescription(cvar)
      rows[#rows + 1] = {
        cvar = cvar,
        description = description,
        details = details,
        defaultValue = tostring(defaultValue),
        currentValue = tostring(currentValue),
        effectiveValue = tostring(effectiveValue),
        overrideValue = overrideValue ~= nil and tostring(overrideValue) or nil,
        isOverridden = overrideValue ~= nil,
      }
    end
  end

  return rows
end

local function NormalizeByDefaultType(cvar, inputValue)
  local defaultValue = CM.Constants.ReticleTargetingCVarValues[cvar]
  if defaultValue == nil then
    return nil
  end

  local trimmed = strtrim(inputValue or "")
  if trimmed == "" then
    return nil
  end

  if type(defaultValue) == "number" then
    local numberValue = tonumber(trimmed)
    if numberValue == nil then
      return nil
    end
    return numberValue
  end

  return trimmed
end

function Data.SetOverride(cvar, inputValue)
  if InCombatLockdown() then
    print(
      CM.Constants.BasePrintMsg
        .. "|cff909090: "
        .. L["cannot edit Reticle Targeting CVars while in combat."]
        .. "|r"
    )
    return false
  end

  if not Data.IsEditableCVar(cvar) then
    return false
  end

  local overrides = Data.GetOverrides()
  local canonical = Data.CanonicalCVar(cvar)
  if not canonical then
    return false
  end
  local normalized = NormalizeByDefaultType(canonical, inputValue)
  if normalized == nil then
    overrides[canonical] = nil
  else
    overrides[canonical] = normalized
  end

  if CM.DB and CM.DB.char and CM.DB.char.reticleTargeting then
    CM.ConfigReticleTargeting("combatmode")
  end
  return true
end

--- Clears every account-wide reticle CVar override so effective values match
--- `CM.Constants.ReticleTargetingCVarValues` again.
function Data.ClearAllOverrides()
  if InCombatLockdown() then
    print(
      CM.Constants.BasePrintMsg
        .. "|cff909090: "
        .. L["cannot reset Reticle Targeting CVars while in combat."]
        .. "|r"
    )
    return false
  end

  wipe(Data.GetOverrides())

  if CM.DB and CM.DB.char and CM.DB.char.reticleTargeting then
    CM.ConfigReticleTargeting("combatmode")
  end
  return true
end
