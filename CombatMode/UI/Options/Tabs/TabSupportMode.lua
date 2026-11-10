---------------------------------------------------------------------------------------
--  UI/Options/Tabs/TabSupportMode.lua — OPTIONS TAB — Support Mode
---------------------------------------------------------------------------------------
--  What it does: Support Mode keybind, key behavior (toggle / hold), support bar page,
--  Self-Cast keybind and the nameplate swap toggle. An unbound Support Mode key disables it.
--  Architecture / how it works:
--    • DB.char.supportMode* (per character). Every setter re-stores the secure key
--      (CM.ApplySupportModeBinding) and rebuilds the click-cast macros
--      (CM.RefreshClickCastMacros); both queue themselves in combat.
--    • Rows are disabled with a notice while Reticle Targeting is off (the mode needs its
--      click-cast proxies).
--  Does not: Own the secure state, build macro text or write CVars.
--  Related: Core/ClickCasting/{SupportMode,BindingOverrides,TargetingMacroBuilder}.lua,
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

local BIND_NAME = "Combat Mode - Support Mode"
local SELF_BIND_NAME = "Combat Mode - Support Mode Self Cast"

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
  if CM.ApplySupportModeBinding then
    CM.ApplySupportModeBinding()
  end
  if CM.RefreshClickCastMacros then
    CM.RefreshClickCastMacros()
  end
end

UI.Options.AddTab({
  id = "supportmode",
  label = L["Support Mode"],
  newFeatureFlag = true,
  build = function(ctx)
    ctx:Header({ text = L["SUPPORT MODE"], newFeatureFlag = true })
    ctx:Description({
      text = L["A second set of click casts for supporting your group. While Support Mode is on, helpful spells on your click-cast buttons only go to the friendly unit under the crosshair (never to yourself by accident), your main action bar shows a support page, and friendly nameplates replace enemy ones. Harmful spells keep targeting enemies."],
    })

    ctx:Keybind({
      label = L["Support Mode Keybind"],
      desc = L["Turns Support Mode on and off. Works in combat. Leave it unbound to disable the feature."],
      newFeatureFlag = true,
      get = function()
        return (GetBindingKey(BIND_NAME))
      end,
      set = function(key)
        CM.TryApplyBindingChange(L["support mode keybinding"], function()
          CM.AssignNamedKeybind(BIND_NAME, key)
          Apply()
        end)
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
    ctx:Dropdown({
      label = L["Key Behavior"],
      desc = L["Toggle: press to turn Support Mode on, press again to turn it off. Hold: Support Mode stays on only while the key is held."],
      charSpecific = true,
      newFeatureFlag = true,
      values = KEY_BEHAVIOR_VALUES,
      order = KEY_BEHAVIOR_ORDER,
      get = function()
        local behavior = CM.DB.char.supportModeKeyBehavior
        return KEY_BEHAVIOR_VALUES[behavior] and behavior or "toggle"
      end,
      set = function(value)
        CM.DB.char.supportModeKeyBehavior = value
        Apply()
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
    ctx:Dropdown({
      label = L["Support Bar Page"],
      desc = L["The main action bar page shown while Support Mode is on. Put your healing and support abilities there. Leaving Support Mode returns to page 1."],
      charSpecific = true,
      newFeatureFlag = true,
      values = PAGE_VALUES,
      order = PAGE_ORDER,
      get = function()
        local id = "p" .. (tonumber(CM.DB.char.supportModePage) or 0)
        return PAGE_VALUES[id] and id or "p0"
      end,
      set = function(value)
        CM.DB.char.supportModePage = tonumber(string.sub(value, 2)) or 0
        Apply()
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
    ctx:Keybind({
      label = L["Self-Cast Keybind"],
      desc = L["Hold this key while clicking in Support Mode to cast that click bind's helpful spell on yourself instead of the unit under the crosshair. All your click binds keep their own spells. Leave it unbound if you don't need it."],
      newFeatureFlag = true,
      get = function()
        return (GetBindingKey(SELF_BIND_NAME))
      end,
      set = function(key)
        CM.TryApplyBindingChange(L["support mode self-cast keybinding"], function()
          CM.AssignNamedKeybind(SELF_BIND_NAME, key)
          Apply()
        end)
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
    ctx:Toggle({
      label = L["Swap Nameplates"],
      desc = L["Hide enemy nameplates and show friendly player nameplates while Support Mode is on, then restore your own settings. The game only lets nameplates change out of combat, so a switch made in combat applies when combat ends."],
      charSpecific = true,
      newFeatureFlag = true,
      get = function()
        return CM.DbBool(CM.DB.char.supportModeNameplates, true)
      end,
      set = function(value)
        CM.DB.char.supportModeNameplates = value and true or false
        if CM.SyncSupportModeNameplates then
          CM.SyncSupportModeNameplates()
        end
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
  end,
})
