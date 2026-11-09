---------------------------------------------------------------------------------------
--  UI/Options/Tabs/TabHealingMode.lua — OPTIONS TAB — Healing Mode
---------------------------------------------------------------------------------------
--  What it does: Healing Mode keybind, key behavior (toggle / hold), healing bar page,
--  self-cast modifier and the nameplate swap toggle. An unbound key disables the feature.
--  Architecture / how it works:
--    • DB.char.healingMode* (per character). Every setter re-stores the secure key
--      (CM.ApplyHealingModeBinding) and rebuilds the click-cast macros
--      (CM.RefreshClickCastMacros); both queue themselves in combat.
--    • Rows are disabled with a notice while Reticle Targeting is off (the mode needs its
--      click-cast proxies).
--  Does not: Own the secure state, build macro text or write CVars.
--  Related: Core/ClickCasting/{HealingMode,BindingOverrides,TargetingMacroBuilder}.lua,
--  Core/Runtime/CVarManager.lua, Constants/DatabaseDefaults.lua, UI/Options/OptionsPanel.lua
---------------------------------------------------------------------------------------
local _, CM = ...
local L = CM.L
local _G = _G

-- WoW API
local GetBindingKey = _G.GetBindingKey

-- Lua stdlib
local string = _G.string
local tonumber = _G.tonumber

local UI = CM.UI

local BIND_NAME = "Combat Mode - Healing Mode"

local KEY_BEHAVIOR_VALUES = {
  toggle = L["Toggle"],
  hold = L["Hold"],
}
local KEY_BEHAVIOR_ORDER = { "toggle", "hold" }

-- Stored as "p<page>" in the dropdown; the DB keeps the number (0 = no page swap).
local PAGE_VALUES = { p0 = L["Don't swap"] }
local PAGE_ORDER = { "p0" }
for page = 2, tonumber(_G.NUM_ACTIONBAR_PAGES) or 6 do
  local id = "p" .. page
  PAGE_VALUES[id] = string.format(L["Page %d"], page)
  PAGE_ORDER[#PAGE_ORDER + 1] = id
end

local MODIFIER_VALUES = {
  NONE = L["None"],
  SHIFT = _G.SHIFT_KEY or L["Shift"],
  CTRL = _G.CTRL_KEY or L["Ctrl"],
  ALT = _G.ALT_KEY or L["Alt"],
}
local MODIFIER_ORDER = { "NONE", "SHIFT", "CTRL", "ALT" }

local function ReticleTargetingOff()
  return not CM.DB.char.reticleTargeting
end

local function ReticleTargetingNotice()
  if ReticleTargetingOff() then
    return L["Requires Reticle Targeting"]
  end
  return nil
end

--- Re-stores the secure key and rebuilds both macro texts of every click-cast button.
local function Apply()
  if CM.ApplyHealingModeBinding then
    CM.ApplyHealingModeBinding()
  end
  if CM.RefreshClickCastMacros then
    CM.RefreshClickCastMacros()
  end
end

UI.Options.AddTab({
  id = "healingmode",
  label = L["Healing Mode"],
  newFeatureFlag = true,
  build = function(ctx)
    ctx:Header({ text = L["HEALING MODE"], newFeatureFlag = true })
    ctx:Description({
      text = L["A second set of click casts for supporting your group. While Healing Mode is on, helpful spells on your click-cast buttons only go to the friendly unit under the crosshair (never to yourself by accident), your main action bar shows a healing page, and friendly nameplates replace enemy ones. Harmful spells keep targeting enemies."],
    })

    ctx:Keybind({
      label = L["Healing Mode Keybind"],
      desc = L["Turns Healing Mode on and off. Works in combat. Leave it unbound to disable the feature."],
      newFeatureFlag = true,
      get = function()
        return (GetBindingKey(BIND_NAME))
      end,
      set = function(key)
        CM.TryApplyBindingChange(L["healing mode keybinding"], function()
          CM.AssignNamedKeybind(BIND_NAME, key)
          Apply()
        end)
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
    ctx:Dropdown({
      label = L["Key Behavior"],
      desc = L["Toggle: press to turn Healing Mode on, press again to turn it off. Hold: Healing Mode stays on only while the key is held."],
      charSpecific = true,
      newFeatureFlag = true,
      values = KEY_BEHAVIOR_VALUES,
      order = KEY_BEHAVIOR_ORDER,
      get = function()
        local behavior = CM.DB.char.healingModeKeyBehavior
        return KEY_BEHAVIOR_VALUES[behavior] and behavior or "toggle"
      end,
      set = function(value)
        CM.DB.char.healingModeKeyBehavior = value
        Apply()
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
    ctx:Dropdown({
      label = L["Healing Bar Page"],
      desc = L["The main action bar page shown while Healing Mode is on. Put your healing and support abilities there. Leaving Healing Mode returns to page 1."],
      charSpecific = true,
      newFeatureFlag = true,
      values = PAGE_VALUES,
      order = PAGE_ORDER,
      get = function()
        local id = "p" .. (tonumber(CM.DB.char.healingModePage) or 0)
        return PAGE_VALUES[id] and id or "p0"
      end,
      set = function(value)
        CM.DB.char.healingModePage = tonumber(string.sub(value, 2)) or 0
        Apply()
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
    ctx:Dropdown({
      label = L["Self-Cast Modifier"],
      desc = L["Hold this key while clicking to cast the helpful spell on yourself instead. While Healing Mode is on, this replaces the click-cast actions you set for that modifier."],
      charSpecific = true,
      newFeatureFlag = true,
      values = MODIFIER_VALUES,
      order = MODIFIER_ORDER,
      get = function()
        local modifier = CM.DB.char.healingModeSelfCastModifier
        return MODIFIER_VALUES[modifier] and modifier or "NONE"
      end,
      set = function(value)
        CM.DB.char.healingModeSelfCastModifier = value
        Apply()
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
    ctx:Toggle({
      label = L["Swap Nameplates"],
      desc = L["Hide enemy nameplates and show friendly player nameplates while Healing Mode is on, then restore your own settings. The game only lets nameplates change out of combat, so a switch made in combat applies when combat ends."],
      charSpecific = true,
      newFeatureFlag = true,
      get = function()
        return CM.DbBool(CM.DB.char.healingModeNameplates, true)
      end,
      set = function(value)
        CM.DB.char.healingModeNameplates = value and true or false
        if CM.SyncHealingModeNameplates then
          CM.SyncHealingModeNameplates()
        end
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
  end,
})
