---------------------------------------------------------------------------------------
--  UI/Options/Tabs/TabSupportMode.lua — OPTIONS TAB — Support Mode
---------------------------------------------------------------------------------------
--  What it does: Support Mode keybind (a toggle), support bar page, Self-Cast keybind and
--  modifier, Vignette tint toggle and the nameplates dropdown. An unbound
--  Support Mode key disables it. (The Support crosshair color and texture are on the Crosshair
--  tab: Reaction Colors and Appearance.)
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

-- Stored ids are the macro modifier names ("shift" in [mod:shift]); "none" = off.
local SELF_MODIFIER_VALUES = {
  none = L["Off"],
  shift = _G.SHIFT_KEY or L["Shift"],
  ctrl = _G.CTRL_KEY or L["Ctrl"],
  alt = _G.ALT_KEY or L["Alt"],
}
local SELF_MODIFIER_ORDER = { "none", "shift", "ctrl", "alt" }

-- char.supportModeNameplateMode (applied by CM.SyncSupportModeNameplates in CVarManager).
local NAMEPLATE_VALUES = {
  keep = L["Don't change"],
  friendly = L["Friendly only"],
  all = L["Friendly and enemy"],
  none = L["Hide all"],
}
local NAMEPLATE_ORDER = { "keep", "friendly", "all", "none" }

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
      text = L["A second set of click casts for supporting your group. While Support Mode is on, helpful spells on your click-cast buttons go to the friendly unit under the crosshair, else to the ally the game soft-targets in front of you, else to your friendly target (such as an Ally Cycle pick), and never to yourself by accident. Your main action bar shows a support page, and friendly nameplates replace enemy ones. Harmful spells keep targeting enemies."],
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
    ctx:Dropdown({
      label = L["Self-Cast Modifier"],
      desc = L["Hold this modifier while clicking in Support Mode to cast the click's helpful spell on yourself. Warning: this replaces the modifier's own click binds while Support Mode is on."],
      helpTooltip = {
        title = L["Self-Cast Modifier"],
        stacked = true,
        lines = {
          {
            label = L["Example: Shift"],
            value = L["Shift + Left Click casts the Left Click's helpful spell on yourself, and Shift + Right Click the Right Click's."],
            warning = L["While Support Mode is on, Shift + Left Click and Shift + Right Click cast on yourself instead of their own click binds (action bar slots 3 and 4 by default) whenever the plain click holds a helpful spell. Outside Support Mode they work as usual."],
          },
        },
      },
      charSpecific = true,
      newFeatureFlag = true,
      values = SELF_MODIFIER_VALUES,
      order = SELF_MODIFIER_ORDER,
      get = function()
        local modifier = CM.DB.char.supportModeSelfCastModifier
        return SELF_MODIFIER_VALUES[modifier] and modifier or "none"
      end,
      set = function(value)
        CM.DB.char.supportModeSelfCastModifier = value
        Apply()
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
    ctx:Toggle({
      label = L["Tint Vignette"],
      desc = L["While Support Mode is on, the Vignette takes the Support crosshair color, so you can tell the mode at a glance. It shows only when your Vignette does; with the Vignette off, nothing is tinted."],
      charSpecific = true,
      newFeatureFlag = true,
      get = function()
        return CM.DbBool(CM.DB.char.supportModeTintVignette, true)
      end,
      set = function(value)
        CM.DB.char.supportModeTintVignette = value and true or false
        if CM.RefreshVignetteTint then
          CM.RefreshVignetteTint()
        end
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
    ctx:Dropdown({
      label = L["Nameplates"],
      desc = L["Which nameplates show while Support Mode is on. Your own nameplate settings come back when you leave it."],
      charSpecific = true,
      newFeatureFlag = true,
      values = NAMEPLATE_VALUES,
      order = NAMEPLATE_ORDER,
      get = function()
        local mode = CM.DB.char.supportModeNameplateMode
        return NAMEPLATE_VALUES[mode] and mode or "friendly"
      end,
      set = function(value)
        CM.DB.char.supportModeNameplateMode = value
        if CM.SyncSupportModeNameplates then
          CM.SyncSupportModeNameplates()
        end
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
  end,
})
