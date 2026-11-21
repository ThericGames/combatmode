---------------------------------------------------------------------------------------
--  Core/ClickCasting/SupportMode.lua — CLICKCAST — Support Mode key + secure mode swap
---------------------------------------------------------------------------------------
--  What it does: The Support Mode keybind. While the mode is on, helpful spells on the
--  click-cast mouse buttons only go to your friendly hard target (an Ally Cycle pick), else to
--  the ally under the crosshair or soft-targeted, else to you if the game's Self Cast setting
--  says so; the main and chosen bars can exchange their displayed actions. Leaving
--  restores both of the bars and the previous nameplate settings.
--  Architecture / how it works:
--    • Enabled = Reticle Targeting on and the key bound (no master toggle).
--    • CombatModeSupportMode (SecureHandlerBaseTemplate) holds the state (attribute sm = 1 / 0)
--      (the key's macro also clears a Target Lock of the other kind) and a frame ref to every click-cast proxy with more than one macro text (the Target
--      Lock and cycle keys too: their Support Mode texts only take friendly units).
--      BindingOverrides and the Party Wheel route buttons store them out of combat
--      (CM.SetModeMacroText: sm-off / sm-on attributes); the key's wrapped OnClick copies the
--      right one into macrotext, so the swap works in combat.
--    • CombatModeSupportModeKey (SecureActionButtonTemplate, type macro) runs
--      focus cleanup and optional legacy paging. The secure handler can instead exchange both bars.
--      The key is a toggle: each press flips the mode, the release does nothing.
--    • Self-cast hold key (CombatModeSupportModeSelfKey, its own keybind): while it is down
--      (attribute smself = 1) and the mode is on, proxies that hold a third text (sm-self:
--      /cast [@player] <spell>, helpful spells on click-cast buttons only) run that one. Its
--      wrapped OnClick sets the state on press and release and casts nothing itself. Asked for
--      once Auto Target Lock could lock an ally: a living lock takes every heal, and the
--      game's Self Cast key takes over every click bind that includes its modifier.
--    • Insecure side: Handler.SupportModeChanged (CallMethod) → nameplates
--      (CM.SyncSupportModeNameplates in CVarManager; only if a client protects those CVars in
--      combat do they wait for PLAYER_REGEN_ENABLED), the crosshair
--      (Support texture + idle tint) and the Vignette tint (CM.RefreshVignetteTint).
--      CM.IsSupportModeActive reads the attribute. Pet / minion nameplates are not swapped:
--      CM.RefreshSupportModePetNameplates sets them once per option / key change and on load.
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
local SELF_BIND_NAME = "Combat Mode - Support Mode Self Cast"
-- Legacy builds changed the game page directly and restored Page 1 on exit.
local EXIT_PAGE = 1
-- Target Lock is mode-specific (Support Mode locks allies, the regular mode enemies), so a mode
-- swap clears a lock of the other kind. Neutral focus targets stay.
local DROP_HOSTILE_LOCK = "/clearfocus [@focus,harm]"
local DROP_FRIENDLY_LOCK = "/clearfocus [@focus,help]"

local Handler
local KeyButton
local SelfKeyButton
local OverrideOwner = CreateFrame("Frame", nil, UIParent)
local proxyCount = 0
local pendingApply = false
local pendingNameplates = false
local pendingPetPlates = false
local pendingProxies = {} -- proxies created during lockdown, registered after combat
-- Reused by CM.GetSupportModeBuildContext (one refresh asks for it once per binding).
local buildContext = {}

---------------------------------------------------------------------------------------
-- Snippets (restricted environment)
---------------------------------------------------------------------------------------
-- Needs `owner` (the handler): gives every registered proxy the macro text of the stored state
-- (sm-off, or sm-on in Support Mode; sm-self where a proxy has one while the self-cast key is
-- held in Support Mode).
local APPLY = [[
  local on = owner:GetAttribute("sm") == 1
  local attr = on and "sm-on" or "sm-off"
  local selfHeld = on and owner:GetAttribute("smself") == 1
  local count = owner:GetAttribute("smcount") or 0
  for i = 1, count do
    local proxy = owner:GetFrameRef("p" .. i)
    if proxy then
      local text = (selfHeld and proxy:GetAttribute("sm-self")) or proxy:GetAttribute(attr)
      if text then
        proxy:SetAttribute("macrotext", text)
      end
    end
  end
]]

-- Each physical button retains its binding and position. Its own actionpage
-- attribute takes precedence over Blizzard's inherited page for icons and clicks.
local SWAP_ACTION_BARS = [[
  local page = owner:GetAttribute("smpage")
  local original = owner:GetAttribute("smoriginalpage")
  if want and page and not original then
    local first = owner:GetFrameRef("sm-main1")
    original = first:GetEffectiveAttribute("actionpage") or 1
    owner:SetAttribute("smoriginalpage", original)
    for i = 1, owner:GetAttribute("smbarbuttons") do
      local main = owner:GetFrameRef("sm-main" .. i)
      local other = owner:GetFrameRef("sm-other" .. i)
      owner:SetAttribute("sm-main-page" .. i, main:GetAttribute("actionpage"))
      owner:SetAttribute("sm-other-page" .. i, other:GetAttribute("actionpage"))
      main:SetAttribute("actionpage", page)
      other:SetAttribute("actionpage", original)
    end
  elseif not want and original then
    for i = 1, owner:GetAttribute("smbarbuttons") do
      local main = owner:GetFrameRef("sm-main" .. i)
      local other = owner:GetFrameRef("sm-other" .. i)
      main:SetAttribute("actionpage", owner:GetAttribute("sm-main-page" .. i))
      other:SetAttribute("actionpage", owner:GetAttribute("sm-other-page" .. i))
      owner:SetAttribute("sm-main-page" .. i, nil)
      owner:SetAttribute("sm-other-page" .. i, nil)
    end
    owner:SetAttribute("smoriginalpage", nil)
  end
]]

local RESTORE_BARS = "local owner = self\nlocal want = false\n" .. SWAP_ACTION_BARS
local APPLY_BARS = "local owner = self\nlocal want = true\n" .. SWAP_ACTION_BARS

-- Needs `owner` and `want` (boolean): enters / leaves the mode.
local SWAP = [[
  owner:SetAttribute("sm", want and 1 or 0)
  ]] .. SWAP_ACTION_BARS .. APPLY .. [[
  owner:CallMethod("SupportModeChanged")
]]

-- The key toggles the mode on its press; the release is dropped. The button keeps useOnKeyDown
-- set, so its focus macro also runs on that press whatever ActionButtonUseKeyDown says.
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

-- The self-cast key: held = 1, released = 0. Outside Support Mode only the state is kept (the
-- proxies already show sm-off, and entering the mode applies it). The click itself does nothing.
local SELF_KEY_PRE = [[
  local owner = owner or self
  owner:SetAttribute("smself", down and 1 or 0)
  if owner:GetAttribute("sm") == 1 then
    ]] .. APPLY .. [[
  end
  return false
]]

-- Back to "not held" (ApplyImpl, when the key is unbound and its release can't arrive any more).
local RESET_SELF = [[
  local owner = self
  if owner:GetAttribute("smself") == 1 then
    owner:SetAttribute("smself", 0)
    ]] .. APPLY .. [[
  end
]]

---------------------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------------------
local function PageForBar(bar)
  return (bar.actionBase - 1) / CM.Constants.ClickCastBars[1].count + 1
end

function CM.GetSupportModeBarChoices()
  local choices = {}
  for index, bar in ipairs(CM.Constants.ClickCastBars) do
    if index > 1 and _G[bar.frame .. "1"] then
      choices[#choices + 1] = { label = index, page = PageForBar(bar) }
    end
  end
  return choices
end

local function SupportBarForPage(page)
  for _, bar in ipairs(CM.Constants.ClickCastBars) do
    if PageForBar(bar) == page and page > EXIT_PAGE then
      return bar
    end
  end
end

function CM.GetSupportModeBarChoice()
  local char = CM.DB and CM.DB.char
  local page = tonumber(char and (char.supportModeSwapPage or char.supportModePage))
  if SupportBarForPage(page) then
    return page
  end
end

function CM.IsSupportModeBarSwapEnabled()
  local char = CM.DB and CM.DB.char
  return not CM.ThirdPartyActionBarsActive and char and CM.DbBool(char.supportModeSwapBars, false)
    or false
end

local function GetPagingPage()
  local page = tonumber(CM.DB and CM.DB.char and CM.DB.char.supportModePage)
  local maxPage = tonumber(_G.NUM_ACTIONBAR_PAGES) or 6
  if page and page > EXIT_PAGE and page <= maxPage and page % 1 == 0 then
    return page
  end
end

function CM.GetSupportModePage()
  if CM.IsSupportModeBarSwapEnabled() then
    return CM.GetSupportModeBarChoice()
  end
  return GetPagingPage()
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
  local page = Handler:GetAttribute("smpage")
  local partner = SupportBarForPage(page)
  local main = _G.MainActionBar
  buildContext.page = page or Handler:GetAttribute("smpaging")
  buildContext.partner = partner and partner.bind or nil
  local nativePage = (main and tonumber(main:GetAttribute("actionpage"))) or EXIT_PAGE
  buildContext.normalPage = page and (Handler:GetAttribute("smoriginalpage") or nativePage) or nil
  buildContext.returnPage = page and nativePage or nil
  buildContext.active = CM.IsSupportModeActive()
  return buildContext
end

---------------------------------------------------------------------------------------
-- Proxy registration (called by the modules that own the proxy buttons)
---------------------------------------------------------------------------------------
--- Lets the Support Mode key swap this secure button's macro text. A call in combat is kept for
--- PLAYER_REGEN_ENABLED (CM.FlushSupportMode). `wantsState`: the frame also gets a frame ref to
--- the handler ("smhandler"), so its own snippets can read the mode (attribute sm = 1 / 0).
function CM.SupportModeRegisterProxy(frame, wantsState)
  if not Handler or not frame or frame.cmSupportModeProxy then
    return
  end
  if wantsState then
    frame.cmSupportModeWantsState = true
  end
  if InCombatLockdown() then
    pendingProxies[#pendingProxies + 1] = frame
    return
  end
  frame.cmSupportModeProxy = true
  proxyCount = proxyCount + 1
  SecureHandlerSetFrameRef(Handler, "p" .. proxyCount, frame)
  Handler:SetAttribute("smcount", proxyCount)
  if frame.cmSupportModeWantsState then
    SecureHandlerSetFrameRef(frame, "smhandler", Handler)
  end
end

--- Stores a proxy's macro texts: normal, Support Mode (`supportText`, nil = same as normal) and
--- Support Mode with the self-cast key held (`selfText`, nil = same as Support Mode), and shows
--- the one for the current state. Out of combat only.
function CM.SetModeMacroText(frame, normalText, supportText, selfText)
  if not frame or not normalText or InCombatLockdown() then
    return
  end
  supportText = supportText or normalText
  frame:SetAttribute("sm-off", normalText)
  frame:SetAttribute("sm-on", supportText)
  frame:SetAttribute("sm-self", selfText)
  local text = normalText
  if CM.IsSupportModeActive() then
    local selfHeld = Handler and Handler:GetAttribute("smself") == 1
    text = (selfHeld and selfText) or supportText
  end
  frame:SetAttribute("macrotext", text)
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

--- Pet and minion nameplates follow Cycle NPCs and Pets as a standing game setting, not the
--- mode swap (CM.ApplySupportModePetNameplates in CVarManager). Runs when the key, the option or
--- the Nameplate Behavior dropdown changes and on load; a write that combat blocks is retried on
--- PLAYER_REGEN_ENABLED.
function CM.RefreshSupportModePetNameplates()
  local applied = not CM.ApplySupportModePetNameplates or CM.ApplySupportModePetNameplates()
  pendingPetPlates = applied == false
end

-- Runs from the secure snippet (CallMethod), in or out of combat: nothing protected in here.
local function OnModeChanged()
  local active = CM.IsSupportModeActive()
  if CM.DB and CM.DB.char then
    CM.DB.char.supportModeActive = active
    CM.DB.char.supportModeAppliedPage = active and (Handler:GetAttribute("smpaging") or 0) or nil
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
  if CM.IsSupportModeActive() and not InCombatLockdown() then
    SecureHandlerExecute(Handler, FORCE_OFF)
  end
end

-- Frame references and layout changes are prepared out of combat. The secure
-- Support Mode key then uses those references in either combat state.
local function SetSwapBar(page)
  if Handler:GetAttribute("smpage") == page then
    return
  end
  SecureHandlerExecute(Handler, RESTORE_BARS)
  Handler:SetAttribute("smpage", nil)
  local partner = SupportBarForPage(page)
  if not partner then
    return
  end

  local main = CM.Constants.ClickCastBars[1]
  for i = 1, main.count do
    if not _G[main.frame .. i] or not _G[partner.frame .. i] then
      return
    end
  end
  for i = 1, main.count do
    SecureHandlerSetFrameRef(Handler, "sm-main" .. i, _G[main.frame .. i])
    SecureHandlerSetFrameRef(Handler, "sm-other" .. i, _G[partner.frame .. i])
  end
  Handler:SetAttribute("smbarbuttons", main.count)
  Handler:SetAttribute("smpage", page)
  if CM.IsSupportModeActive() then
    SecureHandlerExecute(Handler, APPLY_BARS)
  end
end

-- Return to the normal page before changing what gets displayed in the current
-- Support Mode session. Exchanging physical bars leaves Blizzard's own page alone.
local function ApplyBarBehavior(page, swapping)
  local paging = not swapping and page or nil
  local previousPaging = Handler:GetAttribute("smpaging")
  local active = CM.IsSupportModeActive()
  if previousPaging ~= paging then
    Handler:SetAttribute("smpaging", paging)
    if active and previousPaging and GetBarPage() == previousPaging then
      SetBarPage(EXIT_PAGE)
    end
  end
  SetSwapBar(swapping and page or nil)
  if active and previousPaging ~= paging then
    CM.DB.char.supportModeAppliedPage = paging or 0
    if paging then
      SetBarPage(paging)
    end
  end
  return paging
end

---------------------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------------------
if SecureHandlerWrapScript then
  Handler = CreateFrame("Frame", "CombatModeSupportMode", UIParent, "SecureHandlerBaseTemplate")
  Handler:SetAttribute("sm", 0)
  Handler:SetAttribute("smself", 0)
  Handler:SetAttribute("smcount", 0)
  Handler.SupportModeChanged = OnModeChanged

  KeyButton =
    CreateFrame("Button", "CombatModeSupportModeKey", UIParent, "SecureActionButtonTemplate")
  KeyButton:RegisterForClicks("AnyDown", "AnyUp")
  KeyButton:SetAttribute("type", "macro")
  KeyButton:SetAttribute("useOnKeyDown", true)
  SecureHandlerWrapScript(KeyButton, "OnClick", Handler, KEY_PRE)

  -- No `type`: it only carries the wrapped OnClick, for the press and the release.
  SelfKeyButton =
    CreateFrame("Button", "CombatModeSupportModeSelfKey", UIParent, "SecureActionButtonTemplate")
  SelfKeyButton:RegisterForClicks("AnyDown", "AnyUp")
  SecureHandlerWrapScript(SelfKeyButton, "OnClick", Handler, SELF_KEY_PRE)
end

---------------------------------------------------------------------------------------
-- Apply
---------------------------------------------------------------------------------------
local function ApplyImpl()
  ClearOverrideBindings(OverrideOwner)
  if not Handler then
    return
  end
  local char = CM.DB and CM.DB.char
  if char and char.supportModeSwapPage == nil then
    -- Seed the separate choice from a previously selected visible bar, if any.
    char.supportModeSwapPage = CM.GetSupportModeBarChoice() or 0
  end
  local enabled = CM.IsSupportModeEnabled()
  local paging =
    ApplyBarBehavior(enabled and CM.GetSupportModePage(), CM.IsSupportModeBarSwapEnabled())
  KeyButton:SetAttribute("useOnKeyDown", true)
  Handler:SetAttribute(
    "smenter",
    DROP_HOSTILE_LOCK .. (paging and ("\n/changeactionbar " .. paging) or "")
  )
  Handler:SetAttribute(
    "smexit",
    DROP_FRIENDLY_LOCK .. (paging and ("\n/changeactionbar " .. EXIT_PAGE) or "")
  )
  -- With no self-cast key left, a release can never arrive: don't stay "held". With one bound the
  -- state is left alone (this runs on every bindings refresh, also while the key is down; its
  -- next press and release put a stale state right).
  local selfKeys = { GetBindingKey(SELF_BIND_NAME) }
  if #selfKeys == 0 then
    SecureHandlerExecute(Handler, RESET_SELF)
  end
  -- Whether the mode is in use (key bound, Reticle Targeting on) decides the pet nameplates.
  CM.RefreshSupportModePetNameplates()
  if not enabled then
    ForceOff()
    return
  end
  for _, key in ipairs({ GetBindingKey(BIND_NAME) }) do
    SetOverrideBindingClick(OverrideOwner, false, key, KeyButton:GetName(), "LeftButton")
  end
  for _, key in ipairs(selfKeys) do
    SetOverrideBindingClick(OverrideOwner, false, key, SelfKeyButton:GetName(), "LeftButton")
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
  local page = tonumber(char.supportModeAppliedPage) or tonumber(char.supportModePage)
  char.supportModeAppliedPage = nil
  if page and page > EXIT_PAGE and GetBarPage() == page then
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
  if pendingPetPlates then
    CM.RefreshSupportModePetNameplates()
  end
end

--- Login / reload: the secure state starts off, so undo what an earlier session left behind.
function CM.InitializeSupportMode()
  ClearLeftoverSession()
  SyncNameplates()
  CM.ApplySupportModeBinding()
end
