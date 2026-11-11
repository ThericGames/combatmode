---------------------------------------------------------------------------------------
--  Core/ClickCasting/SupportMode.lua — CLICKCAST — Support Mode key + secure mode swap
---------------------------------------------------------------------------------------
--  What it does: The Support Mode keybind. While the mode is on, helpful spells on the
--  click-cast mouse buttons only go to your friendly hard target (an Ally Cycle pick), else to
--  the ally under the crosshair or soft-targeted, else to you if the game's Self Cast setting
--  says so; the main action bar shows the support page, and enemy nameplates give way to
--  friendly ones. Leaving it puts page 1 and the nameplates back.
--  Architecture / how it works:
--    • Enabled = Reticle Targeting on and the key bound (no master toggle).
--    • CombatModeSupportMode (SecureHandlerBaseTemplate) holds the state (attribute sm = 1 / 0)
--      and a frame ref to every click-cast proxy with more than one macro text (the Target
--      Lock and cycle keys too: their Support Mode texts only take friendly units).
--      BindingOverrides and the Party Wheel route buttons store them out of combat
--      (CM.SetModeMacroText: sm-off / sm-on attributes); the key's wrapped OnClick copies the
--      right one into macrotext, so the swap works in combat.
--    • CombatModeSupportModeKey (SecureActionButtonTemplate, type macro) runs
--      /changeactionbar <page> for the page swap, the only secure way to page in combat.
--      The key is a toggle: each press flips the mode, the release does nothing.
--    • No self-cast option of its own (a hold key and a modifier existed before release and
--      were removed); the macro texts follow the game's Self Cast setting instead.
--    • Insecure side: Handler.SupportModeChanged (CallMethod) → nameplates
--      (CM.SyncSupportModeNameplates in CVarManager; only if a client protects those CVars in
--      combat do they wait for PLAYER_REGEN_ENABLED), the crosshair
--      (Support texture + idle tint) and the Vignette tint (CM.RefreshVignetteTint).
--      CM.IsSupportModeActive reads the attribute.
--    • The mode never survives a reload: CM.InitializeSupportMode turns a leftover support
--      page back to page 1 and CVarManager restores leftover nameplate CVars.
--  Does not: Build macro text (TargetingMacroBuilder), own the proxy buttons or their
--  bindings (BindingOverrides), or write CVars (CVarManager).
--  Related: Core/ClickCasting/{TargetingMacroBuilder,BindingOverrides}.lua,
--  Core/RadialMenu/PartyWheel.lua, Core/Runtime/{CVarManager,EventRouter,Bootstrap}.lua,
--  UI/Options/Tabs/TabSupportMode.lua, Constants/DatabaseDefaults.lua, Bindings.xml
---------------------------------------------------------------------------------------
local _, CM = ...
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

local BIND_NAME = "Combat Mode - Support Mode"
-- Leaving Support Mode always returns to the first bar page.
local EXIT_PAGE = 1

local Handler
local KeyButton
local OverrideOwner = CreateFrame("Frame", nil, UIParent)
local proxyCount = 0
local pendingApply = false
local pendingNameplates = false
local pendingProxies = {} -- proxies created during lockdown, registered after combat
-- Reused by CM.GetSupportModeBuildContext (one refresh asks for it once per binding).
local buildContext = {}

---------------------------------------------------------------------------------------
-- Snippets (restricted environment)
---------------------------------------------------------------------------------------
-- Needs `owner` (the handler): gives every registered proxy the macro text of the stored state
-- (sm-off, or sm-on in Support Mode).
local APPLY = [[
  local attr = owner:GetAttribute("sm") == 1 and "sm-on" or "sm-off"
  local count = owner:GetAttribute("smcount") or 0
  for i = 1, count do
    local proxy = owner:GetFrameRef("p" .. i)
    local text = proxy and proxy:GetAttribute(attr)
    if text then
      proxy:SetAttribute("macrotext", text)
    end
  end
]]

-- Needs `owner` and `want` (boolean): enters / leaves the mode.
local SWAP = [[
  owner:SetAttribute("sm", want and 1 or 0)
  ]] .. APPLY .. [[
  owner:CallMethod("SupportModeChanged")
]]

-- The key toggles the mode on its press; the release is dropped. The button keeps useOnKeyDown
-- set, so its own macro (the page swap) runs on that press whatever ActionButtonUseKeyDown says.
-- (A hold-to-stay-on behavior existed before release and was removed as not useful.)
local KEY_PRE = [[
  if not down then
    return false
  end
  local owner = owner or self
  local want = owner:GetAttribute("sm") ~= 1
  ]] .. SWAP .. [[
  self:SetAttribute("macrotext", owner:GetAttribute(want and "smenter" or "smexit"))
]]

local FORCE_OFF = "local owner = self\nlocal want = false\n" .. SWAP

---------------------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------------------
--- Bar page shown while Support Mode is on, or nil when the page swap is off.
function CM.GetSupportModePage()
  local page = tonumber(CM.DB and CM.DB.char and CM.DB.char.supportModePage)
  local pages = tonumber(_G.NUM_ACTIONBAR_PAGES) or 6
  if page and page > EXIT_PAGE and page <= pages then
    return page
  end
  return nil
end

--- Reticle Targeting on and the Support Mode key bound.
function CM.IsSupportModeEnabled()
  local char = CM.DB and CM.DB.char
  if not Handler or not char or not char.reticleTargeting then
    return false
  end
  return GetBindingKey(BIND_NAME) ~= nil
end

function CM.IsSupportModeActive()
  return Handler ~= nil and Handler:GetAttribute("sm") == 1
end

--- What BindingOverrides needs to build the macro texts of a key, or nil when the feature is
--- off: `page` (support bar page or nil) and `active` (the support page is the one showing
--- right now). The table is reused: read it at once.
function CM.GetSupportModeBuildContext()
  if not CM.IsSupportModeEnabled() then
    return nil
  end
  buildContext.page = CM.GetSupportModePage()
  buildContext.active = CM.IsSupportModeActive()
  return buildContext
end

---------------------------------------------------------------------------------------
-- Proxy registration (called by the modules that own the proxy buttons)
---------------------------------------------------------------------------------------
--- Lets the Support Mode key swap this secure button's macro text. A call in combat is kept for
--- PLAYER_REGEN_ENABLED (CM.FlushSupportMode).
function CM.SupportModeRegisterProxy(frame)
  if not Handler or not frame or frame.cmSupportModeProxy then
    return
  end
  if InCombatLockdown() then
    pendingProxies[#pendingProxies + 1] = frame
    return
  end
  frame.cmSupportModeProxy = true
  proxyCount = proxyCount + 1
  SecureHandlerSetFrameRef(Handler, "p" .. proxyCount, frame)
  Handler:SetAttribute("smcount", proxyCount)
end

--- Stores a proxy's macro texts: normal and Support Mode (`supportText`, nil = same as normal),
--- and shows the one for the current state. Out of combat only.
function CM.SetModeMacroText(frame, normalText, supportText)
  if not frame or not normalText or InCombatLockdown() then
    return
  end
  supportText = supportText or normalText
  frame:SetAttribute("sm-off", normalText)
  frame:SetAttribute("sm-on", supportText)
  frame:SetAttribute("macrotext", CM.IsSupportModeActive() and supportText or normalText)
end

---------------------------------------------------------------------------------------
-- Insecure reactions
---------------------------------------------------------------------------------------
local function SyncNameplates()
  -- False = the nameplate CVars are protected right now (combat): retry on PLAYER_REGEN_ENABLED.
  local applied = not CM.SyncSupportModeNameplates or CM.SyncSupportModeNameplates()
  pendingNameplates = applied == false
  return applied
end

-- Runs from the secure snippet (CallMethod), in or out of combat: nothing protected in here.
local function OnModeChanged()
  local active = CM.IsSupportModeActive()
  if CM.DB and CM.DB.char then
    CM.DB.char.supportModeActive = active
  end
  SyncNameplates()
  -- The idle reticle is tinted while the mode is on (CM.GetCrosshairIdleColorState).
  -- The old reticle locks out while the new one locks in (Animations.lua).
  if CM.PlayCrosshairModeSwap and CM.RefreshCrosshairAppearance then
    CM.PlayCrosshairModeSwap(CM.RefreshCrosshairAppearance)
  elseif CM.RefreshCrosshairAppearance then
    CM.RefreshCrosshairAppearance()
  end
  -- The Vignette takes the same color (Core/Vignette.lua).
  if CM.RefreshVignetteTint then
    CM.RefreshVignetteTint()
  end
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
  if not CM.IsSupportModeActive() or InCombatLockdown() then
    return
  end
  local page = CM.GetSupportModePage()
  SecureHandlerExecute(Handler, FORCE_OFF)
  if page and GetBarPage() == page then
    SetBarPage(EXIT_PAGE)
  end
end

---------------------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------------------
if SecureHandlerWrapScript then
  Handler = CreateFrame("Frame", "CombatModeSupportMode", UIParent, "SecureHandlerBaseTemplate")
  Handler:SetAttribute("sm", 0)
  Handler:SetAttribute("smcount", 0)
  Handler.SupportModeChanged = OnModeChanged

  KeyButton =
    CreateFrame("Button", "CombatModeSupportModeKey", UIParent, "SecureActionButtonTemplate")
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
  local page = CM.GetSupportModePage()
  KeyButton:SetAttribute("useOnKeyDown", true)
  Handler:SetAttribute("smenter", page and ("/changeactionbar " .. page) or nil)
  Handler:SetAttribute("smexit", page and ("/changeactionbar " .. EXIT_PAGE) or nil)
  if not CM.IsSupportModeEnabled() then
    ForceOff()
    return
  end
  for _, key in ipairs({ GetBindingKey(BIND_NAME) }) do
    SetOverrideBindingClick(OverrideOwner, false, key, KeyButton:GetName(), "LeftButton")
  end
end

--- Stores the key's settings and (re)binds it; a call in combat waits for
--- PLAYER_REGEN_ENABLED. Callers that change what the macros say (Support Mode key, page) also
--- run CM.RefreshClickCastMacros.
function CM.ApplySupportModeBinding()
  if InCombatLockdown() then
    pendingApply = true
    return
  end
  pendingApply = false
  ApplyImpl()
end

-- A reload while the mode was on leaves the support page showing with the secure state back to
-- off: return to page 1 (out of combat; PLAYER_REGEN_ENABLED retries).
local function ClearLeftoverSession()
  local char = CM.DB and CM.DB.char
  if not char or not char.supportModeActive or CM.IsSupportModeActive() or InCombatLockdown() then
    return
  end
  char.supportModeActive = false
  local page = CM.GetSupportModePage()
  if page and GetBarPage() == page then
    SetBarPage(EXIT_PAGE)
  end
end

--- PLAYER_REGEN_ENABLED: whatever combat held back.
function CM.FlushSupportMode()
  if InCombatLockdown() then
    return
  end
  ClearLeftoverSession()
  if #pendingProxies > 0 then
    for i = 1, #pendingProxies do
      CM.SupportModeRegisterProxy(pendingProxies[i])
      pendingProxies[i] = nil
    end
    -- Their macro texts were not stored either.
    if CM.RefreshClickCastMacros then
      CM.RefreshClickCastMacros()
    end
  end
  if pendingApply then
    CM.ApplySupportModeBinding()
  end
  if pendingNameplates then
    SyncNameplates()
  end
end

--- Login / reload: the secure state starts off, so undo what an earlier session left behind.
function CM.InitializeSupportMode()
  ClearLeftoverSession()
  SyncNameplates()
  CM.ApplySupportModeBinding()
end
