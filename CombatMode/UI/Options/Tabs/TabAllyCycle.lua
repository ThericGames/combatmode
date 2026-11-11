---------------------------------------------------------------------------------------
--  UI/Options/Tabs/TabAllyCycle.lua — OPTIONS TAB — Ally Cycle + HUD
---------------------------------------------------------------------------------------
--  What it does: Up/Down keybinds, Skip Self, Keep Ally After Harm, and Ally HUD
--  show/side/scale/distance. Unbound keys disable.
--  Architecture / how it works:
--    • DB.global.allyCycle; onSelect/onDeselect → SetAllyCycleOptionsPreview.
--    • Skip Self → skipPlayer + ApplyAllyCycleBindings (secure attribute).
--    • Also Cycle Through (multi dropdown) → CM.SetAllyCycleExtraUnits (Your Pet / Party Pets).
--    • Keep Ally After Harm → SetAllyCycleRestoreAfterHarm + RefreshClickCastMacros.
--  Does not: Own secure roster or build click-cast macrotext.
--  Related: Core/AllyCycle/{Cycle,Target,HealthBar,Motion,HUD,AllyCycle}.lua, Constants/DatabaseDefaults.lua,
--  Core/ClickCasting/TargetingMacroBuilder.lua, UI/Options/OptionsPanel.lua
---------------------------------------------------------------------------------------
local _, CM = ...
local L = CM.L
local _G = _G

-- WoW API
local GetBindingKey = _G.GetBindingKey

local UI = CM.UI

local HUD_SIDE_VALUES = {
  TOP = L["Top"],
  BOTTOM = L["Bottom"],
}
local HUD_SIDE_ORDER = { "TOP", "BOTTOM" }

local EXTRA_UNIT_VALUES = {
  playerPet = L["Your Pet"],
  partyPets = L["Party Pets"],
}
local EXTRA_UNIT_ORDER = { "playerPet", "partyPets" }

local function ExtraUnitsSelected()
  local playerPet, partyPets = CM.GetAllyCycleExtraUnits()
  return { playerPet = playerPet, partyPets = partyPets }
end

local function ExtraUnitOn(id)
  return ExtraUnitsSelected()[id] == true
end

local function ToggleExtraUnit(id)
  local set = ExtraUnitsSelected()
  set[id] = not set[id]
  local keys = {}
  for _, key in ipairs(EXTRA_UNIT_ORDER) do
    if set[key] then
      keys[#keys + 1] = key
    end
  end
  CM.SetAllyCycleExtraUnits(table.concat(keys, ","))
end

local function ExtraUnitsSummary()
  local set = ExtraUnitsSelected()
  local names = {}
  for _, key in ipairs(EXTRA_UNIT_ORDER) do
    if set[key] then
      names[#names + 1] = EXTRA_UNIT_VALUES[key]
    end
  end
  return #names > 0 and table.concat(names, ", ") or L["Off"]
end

local function ApplyHud()
  if CM.ApplyAllyCycleHUDLayout then
    CM.ApplyAllyCycleHUDLayout()
  end
  if CM.RefreshAllyCycleHUD then
    CM.RefreshAllyCycleHUD()
  end
end

local function AllyCycleDb()
  if not CM.DB.global.allyCycle then
    CM.DB.global.allyCycle = {
      showHud = true,
      hudSide = "BOTTOM",
      scale = 1.0,
      padding = 24,
      skipPlayer = true,
      extraUnits = "playerPet",
      restoreAllyAfterHarm = false,
      restoreAllyAfterHarmSet = false,
    }
  end
  return CM.DB.global.allyCycle
end

UI.Options.AddTab({
  id = "allycycle",
  label = L["Ally Cycle"],
  newFeatureFlag = true,
  onSelect = function()
    if CM.SetAllyCycleOptionsPreview then
      CM.SetAllyCycleOptionsPreview(true)
    end
  end,
  onDeselect = function()
    if CM.SetAllyCycleOptionsPreview then
      CM.SetAllyCycleOptionsPreview(false)
    end
  end,
  build = function(ctx)
    ctx:Header({ text = L["ALLY CYCLE"] })

    ctx:Description({
      text = L["Seamless combat and support by allowing helpful spells to target allies, while harmful spells remain focused on the hostile crosshair target."],
    })

    ctx:Keybind({
      label = L["Ally Cycle - Next"],
      desc = L["Target the next group member."],
      get = function()
        return GetBindingKey(CM.AllyCycleBindUp or "Combat Mode - Ally Cycle Next")
      end,
      set = function(key)
        CM.TryApplyBindingChange(L["ally cycle next keybinding"], function()
          CM.AssignNamedKeybind(CM.AllyCycleBindUp or "Combat Mode - Ally Cycle Next", key)
          if CM.ApplyAllyCycleBindings then
            CM.ApplyAllyCycleBindings()
          end
          if CM.RefreshClickCastMacros then
            CM.RefreshClickCastMacros()
          end
        end)
      end,
    })
    ctx:Keybind({
      label = L["Ally Cycle - Previous"],
      desc = L["Target the previous group member."],
      get = function()
        return GetBindingKey(CM.AllyCycleBindDown or "Combat Mode - Ally Cycle Previous")
      end,
      set = function(key)
        CM.TryApplyBindingChange(L["ally cycle previous keybinding"], function()
          CM.AssignNamedKeybind(CM.AllyCycleBindDown or "Combat Mode - Ally Cycle Previous", key)
          if CM.ApplyAllyCycleBindings then
            CM.ApplyAllyCycleBindings()
          end
          if CM.RefreshClickCastMacros then
            CM.RefreshClickCastMacros()
          end
        end)
      end,
    })
    ctx:Toggle({
      label = L["Skip Self"],
      desc = L["Skip yourself when cycling through group members."],
      get = function()
        return CM.IsAllyCycleSkipPlayer and CM.IsAllyCycleSkipPlayer()
      end,
      set = function(value)
        AllyCycleDb().skipPlayer = value and true or false
        if CM.ApplyAllyCycleBindings then
          CM.ApplyAllyCycleBindings()
        end
      end,
    })
    ctx:Dropdown({
      label = L["Also Cycle Through"],
      desc = L["Adds pets after the group members: your own pet, and the pets of everyone else in your party or raid."],
      multi = true,
      newFeatureFlag = true,
      values = EXTRA_UNIT_VALUES,
      order = EXTRA_UNIT_ORDER,
      isOn = ExtraUnitOn,
      toggle = ToggleExtraUnit,
      summary = ExtraUnitsSummary,
      get = ExtraUnitsSummary,
    })
    ctx:Toggle({
      label = L["Keep Ally After Harm"],
      desc = L["After a harmful spell targets the reticle enemy, restore the previous ally. On by default for Healer specs until changed."],
      get = function()
        return CM.IsAllyCycleRestoreAfterHarm and CM.IsAllyCycleRestoreAfterHarm()
      end,
      set = function(value)
        if CM.SetAllyCycleRestoreAfterHarm then
          CM.SetAllyCycleRestoreAfterHarm(value)
        end
        if CM.RefreshClickCastMacros then
          CM.RefreshClickCastMacros()
        end
      end,
      disabled = function()
        return CM.DB.char.autoTargetLockOnAttack == true
      end,
      watermarkWhenDisabled = function()
        if CM.DB.char.autoTargetLockOnAttack == true then
          return L["Disabled while Auto Target Lock is on"]
        end
        return nil
      end,
    })

    ctx:Gap()
    ctx:Header({ text = L["ALLY HUD"] })
    ctx:Description(L["A HUD displaying the group member Ally Cycle has selected."])

    ctx:Toggle({
      label = L["Ally HUD"],
      desc = L["Show a unit frame for the currently selected group member."],
      get = function()
        return AllyCycleDb().showHud ~= false
      end,
      set = function(value)
        AllyCycleDb().showHud = value
        ApplyHud()
      end,
    })
    ctx:Dropdown({
      label = L["Position"],
      desc = L["Where the Ally HUD sits relative to the crosshair."],
      values = HUD_SIDE_VALUES,
      order = HUD_SIDE_ORDER,
      get = function()
        return AllyCycleDb().hudSide or "BOTTOM"
      end,
      set = function(value)
        AllyCycleDb().hudSide = value
        ApplyHud()
      end,
    })
    ctx:Slider({
      label = L["Scale"],
      desc = L["Scales the size of the Ally HUD."],
      min = 0.5,
      max = 1.5,
      step = 0.05,
      default = 1,
      get = function()
        return AllyCycleDb().scale or 1
      end,
      set = function(value)
        AllyCycleDb().scale = value
        ApplyHud()
      end,
    })
    ctx:Slider({
      label = L["Distance"],
      desc = L["Distance between the Ally HUD and the crosshair."],
      min = 0,
      max = 128,
      step = 1,
      default = 24,
      get = function()
        local v = AllyCycleDb().padding
        if v == nil then
          v = 24
        end
        return v
      end,
      set = function(value)
        AllyCycleDb().padding = value
        ApplyHud()
      end,
    })
  end,
})
