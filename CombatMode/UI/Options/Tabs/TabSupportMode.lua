---------------------------------------------------------------------------------------
--  UI/Options/Tabs/TabSupportMode.lua — OPTIONS TAB — Support Mode
---------------------------------------------------------------------------------------
--  What it does: Support Mode keybind (a toggle), Self-Cast keybind (a hold), Prioritize
--  Crosshair Target, support bar page,
--  Cycle NPCs and Pets, Cycle in Group Order, Vignette tint toggle and the nameplates dropdown. An unbound Support Mode key disables it.
--  (The Support crosshair color and texture are on the Crosshair tab: Reaction Colors and
--  Appearance.)
--  Architecture / how it works:
--    • DB.char.supportMode* (per character). Every setter re-stores the secure key
--      (CM.ApplySupportModeBinding) and rebuilds the click-cast macros
--      (CM.RefreshClickCastMacros); both queue themselves in combat.
--    • Rows are disabled with a notice while Reticle Targeting is off (the mode needs its
--      click-cast proxies).
--    • Disable Target Lock leaves click-cast ally targeting available without a focus lock.
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

-- char.supportModeNameplateMode (applied by CM.SyncSupportModeNameplates in CVarManager).
local NAMEPLATE_VALUES = {
  keep = L["Don't Change"],
  friendly = L["Friendly Only"],
  all = L["Friendly and Enemy"],
  none = L["Hide All"],
}
local NAMEPLATE_ORDER = { "keep", "friendly", "all", "none" }

-- Stored as "p<page>" in the dropdown; the DB keeps the number (0 = no page swap).
local PAGE_VALUES = { p0 = L["Don't Swap"] }
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
      text = L["A support-focused mode that, when active, switches your main action bar to a dedicated support page and allows helpful spells to target the friendly unit under your crosshair."],
    })

    ctx:Keybind({
      label = L["Support Mode Keybind"],
      desc = L["Tap to toggle Support Mode on or off."],
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
    ctx:Keybind({
      label = L["Self-Cast Keybind"],
      desc = L["Hold to cast your click-cast helpful spells on yourself. Your target and Target Lock don't change."],
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
      label = L["Disable Target Lock"],
      desc = L["Disable manual and automatic Target Lock in Support Mode. Entering Support Mode clears your lock. If you are already in Support Mode, leave and re-enter to clear it."],
      charSpecific = true,
      get = function()
        return CM.DbBool(CM.DB.char.supportModeDisableTargetLock, false)
      end,
      set = function(value)
        CM.DB.char.supportModeDisableTargetLock = value and true or false
        Apply()
        CM.ApplyToggleFocusTargetBinding()
        CM.ApplyCycleFocusBindings()
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
    ctx:Toggle({
      label = L["Prioritize Crosshair Target"],
      desc = L["Prioritizes the ally under your crosshair over other friendly targets (e.g. Ally Cycle). Disable to prioritize your selected target instead."],
      charSpecific = true,
      get = function()
        return CM.DbBool(CM.DB.char.supportModeCrosshairFirst, false)
      end,
      set = function(value)
        CM.DB.char.supportModeCrosshairFirst = value and true or false
        Apply()
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
    ctx:Toggle({
      label = L["Cycle NPCs and Pets"],
      desc = L["Cycle Lock also includes nearby NPCs and pets. While off, friendly pet nameplates are hidden."],
      charSpecific = true,
      get = function()
        return CM.DbBool(CM.DB.char.supportModeCycleNPCs, false)
      end,
      set = function(value)
        CM.DB.char.supportModeCycleNPCs = value and true or false
        -- Apply also sets the pet and minion nameplates (CM.RefreshSupportModePetNameplates).
        Apply()
        -- The cycle buttons' Support Mode text is stored by this, not by the macro refresh.
        if CM.ApplyCycleFocusBindings then
          CM.ApplyCycleFocusBindings()
        end
        -- Group order: whether Cycle Lock presses stop on pets (Ally Cycle's lockPets attribute).
        if CM.ApplyAllyCycleBindings then
          CM.ApplyAllyCycleBindings()
        end
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
    ctx:Toggle({
      label = L["Cycle in Group Order"],
      desc = L["Cycle Lock follows your party or raid order instead of the nearest ally. The first press locks the first member (Next) or the last (Previous)."],
      charSpecific = true,
      get = function()
        return CM.DbBool(CM.DB.char.supportModeCycleGroupOrder, false)
      end,
      set = function(value)
        CM.DB.char.supportModeCycleGroupOrder = value and true or false
        -- Stores the cycle buttons' Support Mode text (queued while in combat).
        if CM.ApplyCycleFocusBindings then
          CM.ApplyCycleFocusBindings()
        end
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
    ctx:Dropdown({
      label = L["Support Bar Page"],
      desc = L["The main action bar page shown while Support Mode is on. Place support abilities here. Exiting Support Mode returns to Page 1."],
      charSpecific = true,
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
    ctx:Toggle({
      label = L["Tint Vignette"],
      desc = L["While Support Mode is active, the Vignette adopts the Support crosshair color. It only appears when the Vignette is enabled."],
      charSpecific = true,
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
      label = L["Nameplate Behavior"],
      desc = L["Choose which nameplates appear while in Support Mode. Normal settings are restored when exiting Support Mode."],
      charSpecific = true,
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
        -- "Don't Change" also leaves the pet and minion nameplates alone.
        if CM.RefreshSupportModePetNameplates then
          CM.RefreshSupportModePetNameplates()
        end
      end,
      disabled = ReticleTargetingOff,
      watermarkWhenDisabled = ReticleTargetingNotice,
    })
  end,
})
