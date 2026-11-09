---------------------------------------------------------------------------------------
--  Core/ClickCasting/HealingMode.lua — CLICKCAST — Healing Mode key + secure mode swap
---------------------------------------------------------------------------------------
--  What it does: The Healing Mode keybind. While the mode is on, helpful spells on the
--  click-cast mouse buttons only go to the friendly unit under the crosshair (an optional
--  modifier casts on yourself), the main action bar shows the healing page, and enemy
--  nameplates give way to friendly ones. Leaving it puts page 1 and the nameplates back.
--  Architecture / how it works:
--    • Enabled = Reticle Targeting on and the key bound (no master toggle).
--    • CombatModeHealingMode (SecureHandlerBaseTemplate) holds the state (attribute hm = 1 / 0)
--      and a frame ref to every click-cast proxy that has two macro texts. BindingOverrides and
--      the Party Wheel route buttons store both out of combat (CM.SetModeMacroText: hm-off /
--      hm-on attributes); the key's wrapped OnClick copies the right one into macrotext, so the
--      swap works in combat.
--    • CombatModeHealingModeKey (SecureActionButtonTemplate, type macro) runs
--      /changeactionbar <page> for the page swap, the only secure way to page in combat.
--      Key Behavior: toggle (press) or hold (press = on, release = off).
--    • Insecure side: Handler.HealingModeChanged (CallMethod) → nameplates
--      (CM.SyncHealingModeNameplates in CVarManager; protected in combat, so they wait for
--      PLAYER_REGEN_ENABLED) and the on / off notice. CM.IsHealingModeActive reads the attribute.
--    • The mode never survives a reload: CM.InitializeHealingMode turns a leftover healing
--      page back to page 1 and CVarManager restores leftover nameplate CVars.
--  Does not: Build macro text (TargetingMacroBuilder), own the proxy buttons or their
--  bindings (BindingOverrides), or write CVars (CVarManager).
--  Related: Core/ClickCasting/{TargetingMacroBuilder,BindingOverrides}.lua,
--  Core/RadialMenu/PartyWheel.lua, Core/Runtime/{CVarManager,EventRouter,Bootstrap}.lua,
--  UI/Options/Tabs/TabHealingMode.lua, Constants/DatabaseDefaults.lua, Bindings.xml
---------------------------------------------------------------------------------------
local _, CM = ...
local L = CM.L
local _G = _G

-- WoW API
local C_ActionBar = _G.C_ActionBar
local ClearOverrideBindings = _G.ClearOverrideBindings
local CreateFrame = _G.CreateFrame
local GetBindingKey = _G.GetBindingKey
local InCombatLockdown = _G.InCombatLockdown
local SecureHandlerExecute = _G.SecureHandlerExecute
local SecureHandlerSetFrameRef = _G.SecureHandlerSetFrameRef
local SecureHandlerWrapScript = _G.SecureHandlerWrapScript
local SetOverrideBindingClick = _G.SetOverrideBindingClick
local UIParent = _G.UIParent

-- Lua stdlib
local ipairs = _G.ipairs
local pcall = _G.pcall
local tonumber = _G.tonumber

local BIND_NAME = "Combat Mode - Healing Mode"
-- Leaving Healing Mode always returns to the first bar page.
local EXIT_PAGE = 1
-- Saved option value -> macro conditional modifier.
local SELF_CAST_MODIFIERS = { SHIFT = "shift", CTRL = "ctrl", ALT = "alt" }

local Handler
local KeyButton
local OverrideOwner = CreateFrame("Frame", nil, UIParent)
local proxyCount = 0
local pendingApply = false
local pendingNameplates = false
local pendingProxies = {} -- proxies created during lockdown, registered after combat
-- Reused by CM.GetHealingModeBuildContext (one refresh asks for it once per binding).
local buildContext = {}

---------------------------------------------------------------------------------------
-- Snippets (restricted environment)
---------------------------------------------------------------------------------------
-- Needs `owner` (the handler) and `want` (boolean): stores the state and gives every registered
-- proxy the macro text of that state.
local SWAP = [[
  owner:SetAttribute("hm", want and 1 or 0)
  local attr = want and "hm-on" or "hm-off"
  local count = owner:GetAttribute("hmcount") or 0
  for i = 1, count do
    local proxy = owner:GetFrameRef("p" .. i)
    local text = proxy and proxy:GetAttribute(attr)
    if text then
      proxy:SetAttribute("macrotext", text)
    end
  end
  owner:CallMethod("HealingModeChanged")
]]

-- The key, both edges. useOnKeyDown is set per edge so the button's own macro (the page swap) runs
-- on the edge that changed the mode, whatever ActionButtonUseKeyDown says.
local KEY_PRE = [[
  local owner = owner or self
  local hold = owner:GetAttribute("hmhold")
  local on = owner:GetAttribute("hm") == 1
  local want
  if down then
    self:SetAttribute("useOnKeyDown", true)
    want = hold or not on
  elseif hold then
    self:SetAttribute("useOnKeyDown", false)
    want = false
  else
    return false
  end
  if want == on then
    return false
  end
  ]] .. SWAP .. [[
  self:SetAttribute("macrotext", owner:GetAttribute(want and "hmenter" or "hmexit"))
]]

local FORCE_OFF = "local owner = self\nlocal want = false\n" .. SWAP

---------------------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------------------
--- Bar page shown while Healing Mode is on, or nil when the page swap is off.
function CM.GetHealingModePage()
  local page = tonumber(CM.DB and CM.DB.char and CM.DB.char.healingModePage)
  local pages = tonumber(_G.NUM_ACTIONBAR_PAGES) or 6
  if page and page > EXIT_PAGE and page <= pages then
    return page
  end
  return nil
end

--- Reticle Targeting on and the Healing Mode key bound.
function CM.IsHealingModeEnabled()
  local char = CM.DB and CM.DB.char
  if not Handler or not char or not char.reticleTargeting then
    return false
  end
  return GetBindingKey(BIND_NAME) ~= nil
end

function CM.IsHealingModeActive()
  return Handler ~= nil and Handler:GetAttribute("hm") == 1
end

--- What BindingOverrides needs to build both macro texts of a key, or nil when the feature is
--- off: `page` (healing bar page or nil), `selfModifier` ("shift" | "ctrl" | "alt" | nil),
--- `active` (the healing page is the one showing right now). The table is reused: read it at once.
function CM.GetHealingModeBuildContext()
  if not CM.IsHealingModeEnabled() then
    return nil
  end
  buildContext.page = CM.GetHealingModePage()
  buildContext.selfModifier = SELF_CAST_MODIFIERS[CM.DB.char.healingModeSelfCastModifier]
  buildContext.active = CM.IsHealingModeActive()
  return buildContext
end

---------------------------------------------------------------------------------------
-- Proxy registration (called by the modules that own the proxy buttons)
---------------------------------------------------------------------------------------
--- Lets the Healing Mode key swap this secure button's macro text. A call in combat is kept for
--- PLAYER_REGEN_ENABLED (CM.FlushHealingMode).
function CM.HealingModeRegisterProxy(frame)
  if not Handler or not frame or frame.cmHealingModeProxy then
    return
  end
  if InCombatLockdown() then
    pendingProxies[#pendingProxies + 1] = frame
    return
  end
  frame.cmHealingModeProxy = true
  proxyCount = proxyCount + 1
  SecureHandlerSetFrameRef(Handler, "p" .. proxyCount, frame)
  Handler:SetAttribute("hmcount", proxyCount)
end

--- Stores a proxy's normal and Healing Mode macro texts (same text when `healText` is nil) and
--- shows the one for the current mode. Out of combat only.
function CM.SetModeMacroText(frame, normalText, healText)
  if not frame or not normalText or InCombatLockdown() then
    return
  end
  healText = healText or normalText
  frame:SetAttribute("hm-off", normalText)
  frame:SetAttribute("hm-on", healText)
  frame:SetAttribute("macrotext", CM.IsHealingModeActive() and healText or normalText)
end

---------------------------------------------------------------------------------------
-- Insecure reactions
---------------------------------------------------------------------------------------
local function SyncNameplates()
  -- False = the nameplate CVars are protected right now (combat): retry on PLAYER_REGEN_ENABLED.
  local applied = not CM.SyncHealingModeNameplates or CM.SyncHealingModeNameplates()
  pendingNameplates = applied == false
  return applied
end

local function Notify(active, nameplatesApplied)
  local frame = _G.UIErrorsFrame
  if not frame or not frame.AddMessage then
    return
  end
  local text
  if nameplatesApplied == false then
    text = active and L["Healing Mode on. Nameplates switch after combat."]
      or L["Healing Mode off. Nameplates switch after combat."]
  else
    text = active and L["Healing Mode on"] or L["Healing Mode off"]
  end
  frame:AddMessage(text, 1, 0.82, 0)
end

-- Runs from the secure snippet (CallMethod), in or out of combat: nothing protected in here.
local function OnModeChanged()
  local active = CM.IsHealingModeActive()
  if CM.DB and CM.DB.char then
    CM.DB.char.healingModeActive = active
  end
  Notify(active, SyncNameplates())
end

local function SetBarPage(page)
  local set = (C_ActionBar and C_ActionBar.SetActionBarPage) or _G.ChangeActionBarPage
  if set then
    pcall(set, page)
  end
end

local function GetBarPage()
  local get = (C_ActionBar and C_ActionBar.GetActionBarPage) or _G.GetActionBarPage
  local ok, page = pcall(get)
  return ok and tonumber(page) or nil
end

-- Leaves the mode from addon code (feature turned off while it was on). Out of combat only.
local function ForceOff()
  if not CM.IsHealingModeActive() or InCombatLockdown() then
    return
  end
  local page = CM.GetHealingModePage()
  SecureHandlerExecute(Handler, FORCE_OFF)
  if page and GetBarPage() == page then
    SetBarPage(EXIT_PAGE)
  end
end

---------------------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------------------
if SecureHandlerWrapScript then
  Handler = CreateFrame("Frame", "CombatModeHealingMode", UIParent, "SecureHandlerBaseTemplate")
  Handler:SetAttribute("hm", 0)
  Handler:SetAttribute("hmcount", 0)
  Handler.HealingModeChanged = OnModeChanged

  KeyButton =
    CreateFrame("Button", "CombatModeHealingModeKey", UIParent, "SecureActionButtonTemplate")
  KeyButton:RegisterForClicks("AnyDown", "AnyUp")
  KeyButton:SetAttribute("type", "macro")
  KeyButton:SetAttribute("useOnKeyDown", true)
  SecureHandlerWrapScript(KeyButton, "OnClick", Handler, KEY_PRE)
end

---------------------------------------------------------------------------------------
-- Apply
---------------------------------------------------------------------------------------
local function ApplyImpl()
  ClearOverrideBindings(OverrideOwner)
  if not Handler then
    return
  end
  local page = CM.GetHealingModePage()
  Handler:SetAttribute("hmhold", CM.DB.char.healingModeKeyBehavior == "hold" or nil)
  Handler:SetAttribute("hmenter", page and ("/changeactionbar " .. page) or nil)
  Handler:SetAttribute("hmexit", page and ("/changeactionbar " .. EXIT_PAGE) or nil)
  if not CM.IsHealingModeEnabled() then
    ForceOff()
    return
  end
  for _, key in ipairs({ GetBindingKey(BIND_NAME) }) do
    SetOverrideBindingClick(OverrideOwner, false, key, KeyButton:GetName(), "LeftButton")
  end
end

--- Stores the key's settings and (re)binds it; a call in combat waits for PLAYER_REGEN_ENABLED.
--- Callers that change what the macros say (key, page, modifier) also run
--- CM.RefreshClickCastMacros.
function CM.ApplyHealingModeBinding()
  if InCombatLockdown() then
    pendingApply = true
    return
  end
  pendingApply = false
  ApplyImpl()
end

-- A reload while the mode was on leaves the healing page showing with the secure state back to
-- off: return to page 1 (out of combat; PLAYER_REGEN_ENABLED retries).
local function ClearLeftoverSession()
  local char = CM.DB and CM.DB.char
  if not char or not char.healingModeActive or CM.IsHealingModeActive() or InCombatLockdown() then
    return
  end
  char.healingModeActive = false
  local page = CM.GetHealingModePage()
  if page and GetBarPage() == page then
    SetBarPage(EXIT_PAGE)
  end
end

--- PLAYER_REGEN_ENABLED: whatever combat held back.
function CM.FlushHealingMode()
  if InCombatLockdown() then
    return
  end
  ClearLeftoverSession()
  if #pendingProxies > 0 then
    for i = 1, #pendingProxies do
      CM.HealingModeRegisterProxy(pendingProxies[i])
      pendingProxies[i] = nil
    end
    -- Their macro texts were not stored either.
    if CM.RefreshClickCastMacros then
      CM.RefreshClickCastMacros()
    end
  end
  if pendingApply then
    CM.ApplyHealingModeBinding()
  end
  if pendingNameplates then
    SyncNameplates()
  end
end

--- Login / reload: the secure state starts off, so undo what an earlier session left behind.
function CM.InitializeHealingMode()
  ClearLeftoverSession()
  SyncNameplates()
  CM.ApplyHealingModeBinding()
end
