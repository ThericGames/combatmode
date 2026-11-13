---------------------------------------------------------------------------------------
--  Core/ClickCasting/TargetingMacroBuilder.lua — CLICKCAST — reticle macro text
---------------------------------------------------------------------------------------
--  What it does: Builds the macrotext injected into click-cast proxies: targeting prelines
--  (enemy-only, optional Auto Target Lock variant, with DB overrides), optional
--  Ally Cycle restore post-line, /click bar button or /cast [@cursor] for ground spells,
--  and membership tests for cast-at-cursor / exclude lists (spell IDs).
--  Architecture / how it works:
--    • BuildClickCastMacroText(bindingValue, opts) — nil when reticleTargeting is off; opts =
--      Support Mode bar page + friendly-only preline for helpful spells (SupportMode.lua).
--    • Default prelines clear dead focus + dead hostile hard target (friendly corpses
--      kept for res), then /tar (enemy / autoLockEnemy). Overrides from
--      global.targetingMacroPreline*Override keys.
--      char.autoTargetLockOnAttack selects the auto-lock variant (not in Support Mode). Focus is gated
--      on harm so a friendly Target Lock does not hijack hostile casts.
--    • Auto-lock prelines and helpful-spell routing: see .claude/rules/domain-click-casting.md (TargetingMacroBuilder.lua notes).
--    • The /click line omits /click's default args (LeftButton, key-up) and only adds
--      "LeftButton 1" for addon bars with key-down on. CM.TargetingMacroPrelineMaxLen =
--      255 − worst /click cast − newline (140); editor enforces.
--    • IsCastAtCursorSpell / IsExcludedFromTargetingSpell read char CSV spell-ID lists;
--      builtin skyriding IDs from Constants.ReticleTargetingBuiltinExcludeSpellIds.
--    • GetEffectiveBarButtonFrameName uses AddonActionBarResolver for third-party bars.
--    • GetDisplayedActionSlotInfo — currently shown action (live frame action attr,
--      reject stale override 121–132 after dismount, else page/bonus or MultiBar slot).
--      IsSlotMacro / BuildClickCastMacroText / BindingOverrides use this so paged /
--      bonus / secondary bar macros are not misclassified as page-1 spells.
--    • Single-Button Assistant (Assisted Combat) buttons are detected live
--      (C_ActionBar.IsAssistedCombatAction, assistant spell id fallback) and always get the
--      harmful targeting route instead of being classified by their churning suggested spell.
--    • Click frame map from CM.Constants.ClickCastBars (ACTIONBUTTON + MultiBar 1–7).
--    • CM.GetActiveTargetingPreline() — settings-only preline (no per-spell routing), shared
--      with the Run MACRO composer (ComposedMacros.lua).
--  Does not: Own SecureActionButton frames or SetOverrideBinding (BindingOverrides).
--  Related: Core/ClickCasting/BindingOverrides.lua,
--  Core/AllyCycle/{AllyCycle,Cycle}.lua,
--  Core/ClickCasting/ComposedMacros.lua, UI/Editors/TargetingMacroPrelinesEditor.lua,
--  UI/Options/Tabs/TabReticleTargeting.lua, UI/Options/SpellMultiSelect.lua,
--  Constants/DatabaseDefaults.lua, Constants/Gameplay.lua,
--  Core/ClickCasting/{AddonActionBarResolver,SupportMode}.lua
---------------------------------------------------------------------------------------
local _, CM = ...
local _G = _G

-- WoW API
local C_ActionBar = _G.C_ActionBar
local C_AssistedCombat = _G.C_AssistedCombat
local C_CVar = _G.C_CVar
local C_Spell = _G.C_Spell
local C_SpellBook = _G.C_SpellBook
local GetActionInfo = _G.GetActionInfo
local GetMacroBody = _G.GetMacroBody
local GetMacroInfo = _G.GetMacroInfo
local GetNumMacros = _G.GetNumMacros
local IsInGroup = _G.IsInGroup
-- The label of an action slot (a macro's name): C_ActionBar on current clients, a global before.
local GetActionText = (C_ActionBar and C_ActionBar.GetActionText) or _G.GetActionText

-- Lua stdlib
local ipairs = _G.ipairs
local pairs = _G.pairs
local pcall = _G.pcall
local strtrim = _G.strtrim
local string = _G.string
local tonumber = _G.tonumber
local type = _G.type

-- Click-cast macro wrapper: binding value (e.g. ACTIONBUTTON1) -> frame name.
-- Shared map includes ACTIONBUTTON + MULTIACTIONBAR1–7 (MultiBar5–7 = DF+ bars).
local CLICKCAST_BARS = CM.Constants.ClickCastBars
  or {
    { bind = "ACTIONBUTTON", frame = "ActionButton", count = 12 },
    { bind = "MULTIACTIONBAR1BUTTON", frame = "MultiBarBottomLeftButton", count = 12 },
    { bind = "MULTIACTIONBAR2BUTTON", frame = "MultiBarBottomRightButton", count = 12 },
    { bind = "MULTIACTIONBAR3BUTTON", frame = "MultiBarRightButton", count = 12 },
    { bind = "MULTIACTIONBAR4BUTTON", frame = "MultiBarLeftButton", count = 12 },
  }

local BindingToClickFrame = {}
for _, bar in ipairs(CLICKCAST_BARS) do
  for i = 1, bar.count do
    BindingToClickFrame[bar.bind .. i] = bar.frame .. i
  end
end

-- Helper function to check which action bar type is currently active.
-- Returns the frame prefix for the active bar type, or nil if using default bar.
local function GetActiveActionBarType()
  if C_ActionBar then
    -- Check for override action bar (vehicles, quest UIs, etc.)
    if C_ActionBar.HasOverrideActionBar and C_ActionBar.HasOverrideActionBar() then
      return "OverrideActionBarButton"
    end
    -- Check for bonus action bar (druid forms, rogue stealth, etc.)
    if C_ActionBar.HasBonusActionBar and C_ActionBar.HasBonusActionBar() then
      return "BonusActionButton"
    end
    -- Check for extra action bar (encounter-specific abilities)
    if C_ActionBar.HasExtraActionBar and C_ActionBar.HasExtraActionBar() then
      -- Extra action bar uses ExtraActionButton1, not ACTIONBUTTON bindings
      return nil
    end
    -- Check for temp shapeshift action bar
    if C_ActionBar.HasTempShapeshiftActionBar and C_ActionBar.HasTempShapeshiftActionBar() then
      return "TempShapeshiftActionButton"
    end
  end

  -- Fallback to frame visibility check for override bar (for older clients or if API unavailable)
  local overrideBar = _G.OverrideActionBar
  if overrideBar and overrideBar:IsShown() then
    return "OverrideActionBarButton"
  end

  -- Default action bar
  return nil
end

-- Helper function to resolve the correct frame name for ACTIONBUTTON bindings.
-- Checks for OverrideActionBarButton, BonusActionButton, or TempShapeshiftActionButton when active,
-- falls back to ActionButton otherwise.
local function ResolveActionButtonFrame(bindingValue)
  if not bindingValue:match("^ACTIONBUTTON") then
    -- Not an ACTIONBUTTON binding, return the mapped frame directly
    return BindingToClickFrame[bindingValue]
  end

  -- Extract button number from binding (e.g., "ACTIONBUTTON5" -> 5)
  local buttonNum = bindingValue:match("(%d+)$")
  if not buttonNum then
    return BindingToClickFrame[bindingValue]
  end

  -- Check which action bar type is currently active
  local activeBarType = GetActiveActionBarType()
  if activeBarType then
    local frameName = activeBarType .. buttonNum
    local ok, actionFrame = pcall(function()
      return _G[frameName]
    end)
    if ok and actionFrame then
      -- Check if the frame has an action assigned
      local rawAction = actionFrame.GetAttribute and actionFrame:GetAttribute("action")
        or actionFrame.action
      local action = rawAction and tonumber(rawAction)
      if action and action > 0 then
        return frameName
      end
    end
  end

  -- Fall back to regular ActionButton
  return BindingToClickFrame[bindingValue]
end

-- Primary action bar slot index (1–12): frame names used by common bar replacement addons for bar 1.
-- First match that exists and is shown wins; then first that exists; else caller uses ActionButtonN.
local PRIMARY_BAR_FRAME_CANDIDATES = {
  function(i)
    return "ElvUI_Bar1Button" .. i
  end,
  function(i)
    return "BT4Button" .. i
  end,
}

local function FindPrimaryBarButtonFrame(index)
  local n = tonumber(index)
  if not n or n < 1 or n > 12 then
    return nil
  end

  for _, makeName in ipairs(PRIMARY_BAR_FRAME_CANDIDATES) do
    local name = makeName(n)
    local f = _G[name]
    if f then
      local ok, shown = pcall(function()
        return f.IsShown and f:IsShown()
      end)
      if ok and shown then
        return name
      end
    end
  end

  for _, makeName in ipairs(PRIMARY_BAR_FRAME_CANDIDATES) do
    local name = makeName(n)
    if _G[name] then
      return name
    end
  end

  return nil
end

-- Some action bar addons require matching the /click "down" arg to ActionButtonUseKeyDown so secure clicks fire.
local function GetActionButtonUseKeyDownMacroSuffix()
  local v = C_CVar and C_CVar.GetCVar and C_CVar.GetCVar("ActionButtonUseKeyDown")
  if v == "1" then
    return "1"
  end
  return "0"
end

local function IsAddonActionButtonFrame(frameName)
  if not frameName or frameName == "" then
    return false
  end
  return frameName:match("^BT4Button") ~= nil or frameName:match("^ElvUI_Bar") ~= nil
end

-- Frame state the macro checks at run time to click the override-bar button instead of the main bar's.
local CLICK_BAR_STATE_CONDITIONS = "[overridebar][possessbar][shapeshift][vehicleui]"

-- Arguments after the frame name. /click defaults to LeftButton and to a key-up click (a down arg of
-- 0 is the same as none), so they are left out to keep the macro short. Some addon action buttons
-- (Bartender/ElvUI) need the down arg to match ActionButtonUseKeyDown for secure clicks to fire,
-- so only for them and only when key-down is on we pass "LeftButton 1" (down needs the button).
local function ClickArgs(frameName)
  if IsAddonActionButtonFrame(frameName) and GetActionButtonUseKeyDownMacroSuffix() == "1" then
    return " LeftButton 1"
  end
  return ""
end

local function FormatClickLine(frameName)
  return "/click " .. frameName .. ClickArgs(frameName)
end

-- Auto Attack / Auto Shot / Shoot / Pet Attack are combat swings, not IsSpellHarmful.
local AUTO_SWING_KIND = {
  [6603] = "attack",
  [75] = "shot",
  [5019] = "shoot",
  [287988] = "pet",
}

local function AutoSwingKind(spellId)
  return AUTO_SWING_KIND[spellId]
end

local function AutoSwingSwapCommand(kind, spellId)
  if kind == "shot" or kind == "shoot" then
    local name
    if C_Spell and C_Spell.GetSpellInfo and spellId then
      local info = C_Spell.GetSpellInfo(spellId)
      name = info and info.name
    end
    if type(name) == "string" and name ~= "" then
      return "/cast !" .. name
    end
    return "/cast !spell:" .. tostring(spellId)
  end
  if kind == "pet" then
    return "/petattack"
  end
  return "/startattack"
end

local function IsAutoSwingSpell(spellId)
  if type(spellId) ~= "number" or spellId <= 0 then
    return false
  end
  if AutoSwingKind(spellId) then
    return true
  end
  if C_Spell and C_Spell.IsAutoRepeatSpell then
    local ok, isRepeat = pcall(C_Spell.IsAutoRepeatSpell, spellId)
    if ok and isRepeat then
      return true
    end
  end
  local IsAutoRepeatSpell = _G.IsAutoRepeatSpell
  if IsAutoRepeatSpell then
    local ok, isRepeat = pcall(IsAutoRepeatSpell, spellId)
    return ok and isRepeat or false
  end
  return false
end

local function ShouldInjectTargetingForSpell(spellId)
  if not spellId or type(spellId) ~= "number" or spellId <= 0 then
    return false
  end
  if IsAutoSwingSpell(spellId) then
    return true
  end
  -- Only inject targeting logic for actual combat spells (helpful/harmful).
  -- Use C_Spell helpers (spellId-based). If unavailable, fall back to injecting for spells
  -- unless explicitly excluded elsewhere.
  if C_Spell and C_Spell.IsSpellHelpful and C_Spell.IsSpellHarmful then
    local okHelp, isHelp = pcall(C_Spell.IsSpellHelpful, spellId)
    local okHarm, isHarm = pcall(C_Spell.IsSpellHarmful, spellId)
    return (okHelp and isHelp) or (okHarm and isHarm) or false
  end
  return true
end

local function IsSpecialLogicalBarFrameName(frameName)
  if not frameName then
    return false
  end
  return frameName:match("^OverrideActionBarButton")
    or frameName:match("^BonusActionButton")
    or frameName:match("^TempShapeshiftActionButton")
end

function CM.IsSpecialLogicalBarFrameName(frameName)
  return IsSpecialLogicalBarFrameName(frameName) and true or false
end

-- Override / vehicle / possess / temp-shapeshift bars use action slots 121–132.
-- After dismount the button attribute can linger; reject those when the bar is gone.
local OVERRIDE_ACTION_MIN = 121
local OVERRIDE_ACTION_MAX = 132

local function IsOverrideStyleBarActive()
  if C_ActionBar then
    if C_ActionBar.HasOverrideActionBar then
      local ok, v = pcall(C_ActionBar.HasOverrideActionBar)
      if ok and v then
        return true
      end
    end
    if C_ActionBar.HasVehicleActionBar then
      local ok, v = pcall(C_ActionBar.HasVehicleActionBar)
      if ok and v then
        return true
      end
    end
    if C_ActionBar.HasTempShapeshiftActionBar then
      local ok, v = pcall(C_ActionBar.HasTempShapeshiftActionBar)
      if ok and v then
        return true
      end
    end
  end
  local overrideBar = _G.OverrideActionBar
  if overrideBar then
    local ok, shown = pcall(function()
      return overrideBar.IsShown and overrideBar:IsShown()
    end)
    if ok and shown then
      return true
    end
  end
  return false
end

local function IsStaleOverrideAction(action)
  if not action or action < OVERRIDE_ACTION_MIN or action > OVERRIDE_ACTION_MAX then
    return false
  end
  return not IsOverrideStyleBarActive()
end

local function GetActionBarPageSafe()
  if C_ActionBar and C_ActionBar.GetActionBarPage then
    local ok, page = pcall(C_ActionBar.GetActionBarPage)
    if ok and type(page) == "number" and page > 0 then
      return page
    end
  end
  local GetActionBarPage = _G.GetActionBarPage
  if GetActionBarPage then
    local ok, page = pcall(GetActionBarPage)
    if ok and type(page) == "number" and page > 0 then
      return page
    end
  end
  return 1
end

local function GetBonusBarOffsetSafe()
  if C_ActionBar and C_ActionBar.GetBonusBarOffset then
    local ok, offset = pcall(C_ActionBar.GetBonusBarOffset)
    if ok and type(offset) == "number" then
      return offset
    end
  end
  local GetBonusBarOffset = _G.GetBonusBarOffset
  if GetBonusBarOffset then
    local ok, offset = pcall(GetBonusBarOffset)
    if ok and type(offset) == "number" then
      return offset
    end
  end
  return 0
end

local function HasBonusActionBarSafe()
  if C_ActionBar and C_ActionBar.HasBonusActionBar then
    local ok, v = pcall(C_ActionBar.HasBonusActionBar)
    if ok and v then
      return true
    end
  end
  return GetBonusBarOffsetSafe() ~= 0
end

-- ACTIONBUTTON index → action slot for the currently paged / bonus bar.
local function ComputeActionButtonSlot(buttonNum)
  local id = tonumber(buttonNum)
  local buttons = tonumber(_G.NUM_ACTIONBAR_BUTTONS) or 12
  if not id or id < 1 or id > buttons then
    return nil
  end
  local pages = tonumber(_G.NUM_ACTIONBAR_PAGES) or 6
  local bonusOffset = GetBonusBarOffsetSafe()
  if HasBonusActionBarSafe() and bonusOffset ~= 0 then
    return id + ((pages + bonusOffset - 1) * buttons)
  end
  local page = GetActionBarPageSafe()
  return id + ((page - 1) * buttons)
end

-- ACTIONBUTTON index → action slot on a given bar page, whichever page is showing now (Support
-- Mode builds macros for the page it will swap to). Blizzard only shows the bonus bar (forms,
-- stealth) on page 1 (ActionBarController_UpdateAll).
local function ComputeActionButtonSlotOnPage(buttonNum, page)
  local id = tonumber(buttonNum)
  local buttons = tonumber(_G.NUM_ACTIONBAR_BUTTONS) or 12
  if not id or id < 1 or id > buttons then
    return nil
  end
  if page == 1 then
    local bonusOffset = GetBonusBarOffsetSafe()
    if HasBonusActionBarSafe() and bonusOffset ~= 0 then
      local pages = tonumber(_G.NUM_ACTIONBAR_PAGES) or 6
      return id + ((pages + bonusOffset - 1) * buttons)
    end
  end
  return id + ((page - 1) * buttons)
end

local function ReadFrameActionId(frameName)
  if not frameName then
    return nil
  end
  local ok, actionFrame = pcall(function()
    return _G[frameName]
  end)
  if not ok or not actionFrame then
    return nil
  end
  local rawAction = actionFrame.GetAttribute and actionFrame:GetAttribute("action")
    or actionFrame.action
  local action = rawAction and tonumber(rawAction)
  if not action or action <= 0 then
    return nil
  end
  if IsStaleOverrideAction(action) then
    return nil
  end
  return action
end

--- Currently displayed action for ACTIONBUTTON / MULTIACTIONBAR* bindings.
--- Prefers the live button action attribute; rejects stale override slots (121–132)
--- after dismount; falls back to page/bonus math or ResolveClickCastBindingToActionSlot.
--- `page` (optional, ACTIONBUTTON only): the action on that bar page instead of the shown one.
function CM.GetDisplayedActionSlotInfo(bindingValue, page)
  if not bindingValue or bindingValue == "" then
    return nil
  end

  local buttonNum = bindingValue:match("^ACTIONBUTTON(%d+)$")
  local action
  if page and buttonNum then
    action = ComputeActionButtonSlotOnPage(buttonNum, page)
  else
    action = ReadFrameActionId(CM.GetEffectiveBarButtonFrameName(bindingValue))
  end

  if not action then
    if buttonNum then
      action = ComputeActionButtonSlot(buttonNum)
    elseif CM.ResolveClickCastBindingToActionSlot then
      action = CM.ResolveClickCastBindingToActionSlot(bindingValue)
    end
  end

  if not action or action <= 0 then
    return nil
  end

  local getOk, atype, id = pcall(GetActionInfo, action)
  if not getOk then
    return nil
  end
  return atype, id, action
end

local function ResolveAddonMultiBarButtonFrame(bindingValue)
  local prefix, slotStr = bindingValue:match("^(MULTIACTIONBAR%d+BUTTON)(%d+)$")
  if not prefix or not slotStr then
    return nil
  end
  local btnIdx = tonumber(slotStr)
  if not btnIdx or btnIdx < 1 or btnIdx > 12 then
    return nil
  end

  local baseFrame = ResolveActionButtonFrame(bindingValue)
  if not baseFrame then
    return nil
  end

  -- Resolve lives in AddonActionBarResolver.lua; it matches addon action slots
  -- by reading action from the Blizzard base multibar frame.
  return CM.ResolveAddonMultiBarButtonFrameByBase(prefix, btnIdx, baseFrame)
end

-- Frame to read action from and /click for macros: addon replacement bar when present, else Blizzard.
function CM.GetEffectiveBarButtonFrameName(bindingValue)
  local base = ResolveActionButtonFrame(bindingValue)
  if not base then
    return nil
  end

  local actionBtnNum = bindingValue:match("^ACTIONBUTTON(%d+)$")
  if actionBtnNum then
    if not IsSpecialLogicalBarFrameName(base) then
      return FindPrimaryBarButtonFrame(actionBtnNum) or base
    end
    return base
  end

  if bindingValue:match("^MULTIACTIONBAR%d+BUTTON%d+$") then
    return ResolveAddonMultiBarButtonFrame(bindingValue) or base
  end

  return base
end

-- Shared note: a condition group with ONLY @unit (no boolean) is ALWAYS true — use
-- ,exists / harm / nodead / nomounted / etc. so fallthrough works. @unit still implies
-- exists when paired with those booleans (harm/nodead already require exists).
-- After /clearfocus [@focus,dead], focus retarget need not repeat ,nodead.
-- /tar is a valid alias for /target. Do not use /f — that is /follow, not /focus.
-- @anyenemy is hostile-only — ,harm is redundant on it.
-- @anyfriend is players (target / softfriend). Friendly NPCs are @softinteract.

-- Full macrotext = preline + "\n" + /click [+ optional post-line]. Hard engine
-- limit is 255 (patch 11.0.2). Same patch: macrotext cannot /click another
-- macro-executing button — do not split onto a second type=macro SecureActionButton.
local SECURE_MACROTEXT_MAX = 255
-- Longest cast line BuildClickCastMacroText emits: the ACTIONBUTTON conditional /click with the
-- override frame (OverrideActionBarButton12) and an ElvUI primary bar (ElvUI_Bar1Button12) that
-- needs the key-down arg.
local CLICKCAST_WORST_CAST_LINE_LEN = #(
  "/click "
  .. CLICK_BAR_STATE_CONDITIONS
  .. " OverrideActionBarButton12; ElvUI_Bar1Button12 LeftButton 1"
)
-- Max editable preline so pre + newline + worst cast stays within SECURE_MACROTEXT_MAX.
CM.TargetingMacroPrelineMaxLen = SECURE_MACROTEXT_MAX - CLICKCAST_WORST_CAST_LINE_LEN - 1

-- A proxy cannot "/click" a bar button that holds a macro (see above: a silent no-op), so for a
-- macro slot the proxy runs the macro's own text instead. This only matters for the page that is
-- not showing when a key's texts are built (Support Mode builds one text per page): the shown
-- slot, when it is a macro, is bound straight to the real button. Reported by players: after a
-- Support Mode swap in combat, or one whose refresh was missed, click-cast keys on a slot holding
-- a macro (a Reticle Targeting Macro on the main bar, say) did nothing until a reload.
-- The text is the one the macro has when the texts are built; `inlinedMacroTexts` remembers it
-- so a later macro edit can ask for a rebuild (CM.InlinedMacroTextChanged, UPDATE_MACROS).
-- The slot's label is the macro's name on every client; GetActionInfo's id is not a macro index
-- on current ones (Blizzard's ActionButton.lua treats it as a spell id). A name can be shared by
-- a general and a character macro, and then it does not say which one the slot holds: such a
-- slot keeps the /click (MacroNameIsUnique).
local inlinedMacroTexts = {}
local macroNameCounts -- name -> macros carrying it; built on first use, dropped on each rebuild

local function MacroNameIsUnique(name)
  if not (GetNumMacros and GetMacroInfo) then
    return true
  end
  if not macroNameCounts then
    macroNameCounts = {}
    local globalCount, charCount = GetNumMacros()
    local accountMax = _G.MAX_ACCOUNT_MACROS or 120
    local ranges = { 1, globalCount or 0, accountMax + 1, accountMax + (charCount or 0) }
    for r = 1, #ranges, 2 do
      for index = ranges[r], ranges[r + 1] do
        local macroName = GetMacroInfo(index)
        if macroName then
          macroNameCounts[macroName] = (macroNameCounts[macroName] or 0) + 1
        end
      end
    end
  end
  return (macroNameCounts[name] or 0) <= 1
end

local function ReadMacroSlotText(slot)
  local name = GetActionText(slot)
  if type(name) ~= "string" or name == "" or not MacroNameIsUnique(name) then
    return nil
  end
  local body = GetMacroBody(name)
  if type(body) ~= "string" or body == "" or #body > SECURE_MACROTEXT_MAX then
    return nil
  end
  return body, name
end

-- nil = no text to run (unnamed slot, macro gone, an API missing): the caller keeps its /click.
local function MacroSlotText(slot)
  if not slot or not GetActionText or not GetMacroBody then
    return nil
  end
  local ok, body, name = pcall(ReadMacroSlotText, slot)
  if not ok or not body then
    return nil
  end
  inlinedMacroTexts[name] = body
  return body
end

--- Forgets the remembered macro texts; BindingOverrides calls it before it rebuilds every key.
function CM.ResetInlinedMacroTexts()
  for name in pairs(inlinedMacroTexts) do
    inlinedMacroTexts[name] = nil
  end
  macroNameCounts = nil
end

--- True when a macro whose text a proxy runs no longer has that text (edited, renamed, deleted).
function CM.InlinedMacroTextChanged()
  if not GetMacroBody then
    return false
  end
  for name, body in pairs(inlinedMacroTexts) do
    local ok, current = pcall(GetMacroBody, name)
    if not ok or current ~= body then
      return true
    end
  end
  return false
end

-- Regular (Auto Target Lock OFF):
-- Clear dead focus + dead hostile hard target. Focus branch gated on harm so a friendly
-- Target Lock (e.g. a party member) is ignored for hostile casts. Otherwise: mouseover
-- hostile+alive under the crosshair; else anyenemy (hard target, then softenemy /
-- Action Targeting). Soft ,nodead kept on mouseover; dropped on @anyenemy (hostile
-- corpse already cleared).
local CLICKCAST_PRE_LINE_ENEMY = "/clearfocus [@focus,dead]\n"
  .. "/cleartarget [dead,harm]\n"
  .. "/tar [@focus,harm];[nomounted,@mouseover,harm,nodead][nomounted,@anyenemy]"

-- Auto Target Lock ON — shared behavior:
-- Must leave room for the longest /click cast line under the 255-char macrotext cap.
-- Clear dead focus AND dead hostile hard target — otherwise a hostile corpse stays
-- selected and [@focus,noexists] can re-lock it. Friendly dead targets are left alone
-- (battle res). Then retarget; resync focus each click ([nodead] / [nodead,harm]) so
-- a dead lock cannot persist when clearfocus misses. [dead,harm] on /cleartarget
-- defaults to @target. Focus branches must include ,nodead — ,harm / ,exists alone
-- still match corpses.

-- Auto Target Lock ON:
-- ,nodead on the focus and mouseover branches (a dead hostile under the reticle is not picked up);
-- resync /focus [nodead,harm] (replaces sticky noexists). Mounted (skyriding) abilities are
-- excluded from targeting by the builtin exclude list, so there is no [nomounted] here.
local CLICKCAST_PRE_LINE_AUTO_LOCK_ENEMY = "/clearfocus [@focus,dead]\n"
  .. "/cleartarget [dead,harm]\n"
  .. "/tar [@focus,harm,nodead][@mouseover,harm,nodead][@anyenemy]\n"
  .. "/focus [nodead,harm]"

-- Export defaults so the prelines editor can show a starting point even when no override exists.
CM.TargetingMacroPrelinesDefaults = {
  enemy = CLICKCAST_PRE_LINE_ENEMY,
  autoLockEnemy = CLICKCAST_PRE_LINE_AUTO_LOCK_ENEMY,
}

--- Builds a set of numeric spell IDs from a CSV list. Numeric tokens are used as-is;
--- legacy name tokens are resolved via C_Spell.GetSpellInfo when possible.
local function ParseSpellListIds(list)
  if not list or list == "" then
    return nil
  end
  local ids = {}
  local any = false
  for entry in string.gmatch(list, "[^,]+") do
    local token = strtrim(entry)
    if token ~= "" then
      local idText = token:gsub("^#", "")
      local id = tonumber(idText)
      if id and id > 0 then
        ids[id] = true
        any = true
      elseif C_Spell and C_Spell.GetSpellInfo then
        local si = C_Spell.GetSpellInfo(token)
        local spellId = si and (si.spellID or si.spellId)
        if spellId and spellId > 0 then
          ids[spellId] = true
          any = true
        end
      end
    end
  end
  if not any then
    return nil
  end
  return ids
end

local function RelatedSpellIds(spellId)
  local related = { [spellId] = true }
  if C_SpellBook and C_SpellBook.FindBaseSpellByID then
    local base = C_SpellBook.FindBaseSpellByID(spellId)
    if base and base > 0 then
      related[base] = true
    end
  end
  if C_SpellBook and C_SpellBook.FindSpellOverrideByID then
    local override = C_SpellBook.FindSpellOverrideByID(spellId)
    if override and override > 0 then
      related[override] = true
    end
  end
  return related
end

local function SpellListContains(list, spellId)
  if not spellId or spellId <= 0 then
    return false
  end
  local ids = ParseSpellListIds(list)
  if not ids then
    return false
  end
  for id in pairs(RelatedSpellIds(spellId)) do
    if ids[id] then
      return true
    end
  end
  return false
end

-- Returns true if spellId is in the user's cast-at-crosshair list (CSV of spell IDs).
function CM.IsCastAtCursorSpell(spellId)
  return SpellListContains(CM.DB.char.castAtCursorSpells, spellId)
end

local function BuiltinExcludeContains(spellId)
  local builtin = CM.Constants and CM.Constants.ReticleTargetingBuiltinExcludeSpellIds
  if not builtin or not spellId or spellId <= 0 then
    return false
  end
  for id in pairs(RelatedSpellIds(spellId)) do
    if builtin[id] then
      return true
    end
  end
  return false
end

-- Returns true if spellId is in the exclude-from-targeting list (CSV of spell IDs)
-- or the builtin skyriding set (not shown in options).
function CM.IsExcludedFromTargetingSpell(spellId)
  return BuiltinExcludeContains(spellId)
    or SpellListContains(CM.DB.char.excludeFromTargetingSpells, spellId)
end

-- Helpful: no /tar (a friendly hard target, such as an Ally Cycle pick, is kept).
local CLICKCAST_PRE_LINE_ALLY_HELP = "/clearfocus [@focus,dead]"

-- Same as ENEMY (clears a dead focus too). Keeps [@focus,harm] so hostile Target Lock still wins
-- /tar. With the /targetlasttarget post-line this can overflow the 255-char cap on setups with a
-- long /click line (ElvUI / Bartender with key-down), so it falls back to the slimmer variant below
-- (no dead-focus clear) whenever the whole macro would not fit.
local CLICKCAST_PRE_LINE_ALLY_HARM_RESTORE_SLIM = "/cleartarget [dead,harm]\n"
  .. "/tar [@focus,harm];[nomounted,@mouseover,harm,nodead][nomounted,@anyenemy]"
local CLICKCAST_PRE_LINE_ALLY_HARM_RESTORE = "/clearfocus [@focus,dead]\n"
  .. CLICKCAST_PRE_LINE_ALLY_HARM_RESTORE_SLIM
local CLICKCAST_POST_LINE_ALLY_HARM_RESTORE = "/targetlasttarget [harm]"

-- Prelines with a slimmer stand-in, used when the assembled macro is over SECURE_MACROTEXT_MAX.
local SLIMMER_PRELINE = {
  [CLICKCAST_PRE_LINE_ALLY_HARM_RESTORE] = CLICKCAST_PRE_LINE_ALLY_HARM_RESTORE_SLIM,
}

local function AllyCycleRestoreAfterHarm()
  return CM.IsAllyCycleRestoreAfterHarm and CM.IsAllyCycleRestoreAfterHarm()
end

-- Auto Target Lock applies to enemies outside Support Mode only: in Support Mode it locks the
-- ally who took a heal (SupportAutoLockText), so harmful spells get the non-locking variants
-- (`support` = the Support Mode text is being built).
local function AutoLockEnemies(support)
  return not support and CM.DbBool(CM.DB.char.autoTargetLockOnAttack, false)
end

local function GetAllyCycleHarmPreLine(support)
  if AutoLockEnemies(support) then
    return CLICKCAST_PRE_LINE_AUTO_LOCK_ENEMY
  end
  if AllyCycleRestoreAfterHarm() then
    return CLICKCAST_PRE_LINE_ALLY_HARM_RESTORE
  end
  return CLICKCAST_PRE_LINE_ENEMY
end

local function GetAllyCycleHarmPostLine(support)
  if AutoLockEnemies(support) then
    return nil
  end
  if not AllyCycleRestoreAfterHarm() then
    return nil
  end
  return CLICKCAST_POST_LINE_ALLY_HARM_RESTORE
end

--- Classify spell for Ally Cycle routing. Dual help+harm → help (stick to ally).
--- True for a Single-Button Assistant (Assisted Combat) action button. Its slot shows whichever
--- spell is currently suggested, and that churns (and is a non-combat or placeholder spell right
--- after loading), so classifying it by spell would leave the targeting pre-line off. The slot
--- check is live (not the cached slot set), with the assistant spell id as a fallback.
local function IsAssistedCombatButton(slot, spellId)
  if slot and C_ActionBar and C_ActionBar.IsAssistedCombatAction then
    local ok, isAssisted = pcall(C_ActionBar.IsAssistedCombatAction, slot)
    if ok and isAssisted then
      return true
    end
  end
  if slot and CM.IsAssistedCombatActionSlot and CM.IsAssistedCombatActionSlot(slot) then
    return true
  end
  if spellId and C_AssistedCombat and C_AssistedCombat.GetActionSpell then
    local ok, assistantSpell = pcall(C_AssistedCombat.GetActionSpell)
    if ok and assistantSpell and assistantSpell == spellId then
      return true
    end
  end
  return false
end

local function GetAllyCycleSpellRoute(spellId)
  if not spellId or type(spellId) ~= "number" or spellId <= 0 then
    return nil
  end
  if IsAutoSwingSpell(spellId) then
    return "harm"
  end
  if not (C_Spell and C_Spell.IsSpellHelpful and C_Spell.IsSpellHarmful) then
    return nil
  end
  local okHelp, isHelp = pcall(C_Spell.IsSpellHelpful, spellId)
  local okHarm, isHarm = pcall(C_Spell.IsSpellHarmful, spellId)
  isHelp = okHelp and isHelp
  isHarm = okHarm and isHarm
  if isHelp then
    return "help"
  end
  if isHarm then
    return "harm"
  end
  return nil
end

-- Shared with keyboard routing so helpful exclusions still receive both mode macros.
function CM.ShouldSelfCastOutsideSupport(spellId)
  return CM.DbBool(CM.DB.char.supportModeSelfCast, false)
    and GetAllyCycleSpellRoute(spellId) == "help"
end

-- Cycle Up/Down bound. Gates harm/restore routing only — not helpful prelines.
local function AllyCycleKeysBound()
  return CM.IsAllyCycleEnabled and CM.IsAllyCycleEnabled()
end

local function AllyCycleInGroup()
  return IsInGroup and IsInGroup()
end

-- Settings-only preline (Auto Target Lock, honoring editor overrides).
-- No per-spell ally-cycle routing; shared with the macro composer.
function CM.GetActiveTargetingPreline(support)
  local function GetOverride(key)
    local v = CM.DB and CM.DB.global and CM.DB.global[key]
    if type(v) ~= "string" then
      return nil
    end
    v = strtrim(v)
    if v == "" then
      return nil
    end
    -- Oversized saved overrides would truncate the trailing /click; ignore them.
    local maxLen = CM.TargetingMacroPrelineMaxLen
    if maxLen and #v > maxLen then
      return nil
    end
    return v
  end

  if AutoLockEnemies(support) then
    return GetOverride("targetingMacroPrelineAutoLockEnemyOverride")
      or CLICKCAST_PRE_LINE_AUTO_LOCK_ENEMY
  end
  return GetOverride("targetingMacroPrelineEnemyOverride") or CLICKCAST_PRE_LINE_ENEMY
end

-- Support Mode (Core/ClickCasting/SupportMode.lua): a helpful spell on a click-cast button only
-- goes to your living friendly hard target (an Ally Cycle pick: top priority, the user's call),
-- else to the aimed-at ally (SUPPORT_ALLY_UNITS below). SupportCastLine below does that without
-- touching your target; the target-then-click preline is only its fallback. `help` is true for a
-- dead ally, so a resurrection still works.
-- Casting on yourself follows the game's own Self Cast setting, as a normal action button does
-- (asked for after testing: Support Mode cast nothing with no ally to take the spell):
--  • Auto Self Cast (CVar autoSelfCast) on: with no friendly unit in any of them the spell lands
--    on you ([@player] last). Off: nothing is cast.
--  • Self Cast key: [mod:SELFCAST,@player] first, evaluated live (never true when the key is
--    "None"). Like the game, it also fires on a click bind that includes that key.
-- The addon has no self-cast option of its own: a hold key and a Shift / Ctrl / Alt modifier
-- were built and removed before release.
-- The aimed-at ally: the unit whose model is under the crosshair, else the friendly soft target.
-- A nameplate is not a mouseover unit in Mouse Look (reported in game: aiming at a friendly
-- nameplate cast nothing), so Support Mode turns friendly soft targeting on (SoftTargetFriend,
-- CVarManager) and @softfriend picks the ally in front of you. Blizzard picks it from an arc in
-- front of the character, not from the crosshair, so it is looser than a mouseover.
local SUPPORT_ALLY_UNITS = "[@mouseover,help][@softfriend,help]"
-- The friendly hard target comes first, but only while alive: a dead pick must not block heals
-- on the aimed-at ally. Dead, it is the last resort (SupportCastLine), so a resurrection on a
-- cycled ally still works when nobody else is aimed at.
local SUPPORT_LIVING_TARGET = "[@target,help,nodead]"
-- Target Lock on an ally (a living friendly focus; the Target Lock and cycle keys pick friendly
-- units in Support Mode) beats everything else in both orders, as a lock does for enemies. The
-- lock key also hard-targets it, so this only matters once the target moved on (a harmful cast,
-- an Ally Cycle press). Dead, it steps aside like a dead hard target and is a last resort.
local SUPPORT_LOCKED_ALLY = "[@focus,help,nodead]"
-- The allies after the lock (SupportCastUnits = the lock + these): the hard target before the
-- crosshair.
local SUPPORT_ALLY_ORDER = SUPPORT_LIVING_TARGET .. SUPPORT_ALLY_UNITS
-- Crosshair First (char.supportModeCrosshairFirst, default off): the unit under the crosshair
-- beats a hard target or an Ally Cycle pick, but not Target Lock; then the living hard target,
-- then the soft friend. Off: the order above.
local SUPPORT_ALLY_ORDER_CROSSHAIR_FIRST = "[@mouseover,help]"
  .. SUPPORT_LIVING_TARGET
  .. "[@softfriend,help]"
-- Last resorts, for resurrections: the hard target, then the lock, when it is a dead ally.
local SUPPORT_DEAD_TARGET = "[@target,help]"
local SUPPORT_DEAD_LOCK = "[@focus,help]"

local function SupportAllyOrder()
  local char = CM.DB and CM.DB.char
  if char and CM.DbBool(char.supportModeCrosshairFirst, false) then
    return SUPPORT_ALLY_ORDER_CROSSHAIR_FIRST
  end
  return SUPPORT_ALLY_ORDER
end

local function SupportCastUnits()
  return SUPPORT_LOCKED_ALLY .. SupportAllyOrder()
end

local SUPPORT_SELF_KEY = "[mod:SELFCAST,@player]"

-- Read when the macro is built; EventRouter rebuilds the macros on this CVar's CVAR_UPDATE.
local function AutoSelfCastOn()
  return C_CVar and C_CVar.GetCVar and C_CVar.GetCVar("autoSelfCast") == "1"
end

-- Fallback preline (target, then /click). A living friendly target "retargets" itself (no
-- change); a dead one stays when nothing is aimed at. The /click applies the game's Self Cast
-- setting by itself, so with Auto Self Cast on nothing may stop the macro; with it off, a
-- helpful /click without a friendly target would raise the targeting cursor, so the macro stops
-- there unless the Self Cast key is held.
local function SupportPreLine()
  local line = "/tar " .. SupportCastUnits()
  if AutoSelfCastOn() then
    return line
  end
  return line .. "\n/stopmacro [nomod:SELFCAST,nohelp]"
end

-- Auto Target Lock (char.autoTargetLockOnAttack) for allies, the user's call: the option locks
-- what you attack, so in Support Mode it also locks who you heal. The cast line is followed by
--   /stopmacro [mod:SELFCAST][@focus,help,nodead]
--   /focus <the allies in cast order, without the lock>
-- A living locked ally already took the heal, so the macro stops and the lock stays. Otherwise
-- the /focus line walks the same units the cast just walked and locks the one that took it; a
-- heal that went to you, or to a dead hard target, matches nothing and locks nobody. A dead or
-- hostile lock gives way to the next ally healed. Your hard target is never changed.
-- The /focus line must not name @focus: Blizzard's /focus swaps a "focus" target for the (empty)
-- action and calls FocusUnit("") (read in SlashCommands.lua, live and forever branches). That
-- is what a bare [] does too, and in game a bare [] locked the soft interact target, so it
-- would move the lock; hence /stopmacro for the "lock alive" case.
-- 255 characters is tight with the spell named in the cast, so extras go one by one until it
-- fits: the Self Cast key guard on /stopmacro (a self-cast with that key then also locks the
-- aimed-at ally), the dead-lock last resort, the dead-target last resort. nil = even that is too
-- long: the caller uses the plain cast line (no auto-lock for that spell).
local function SupportAutoLockText(units, selfCast, name)
  local lockLine = "\n/focus " .. SupportAllyOrder()
  local stop = "\n/stopmacro [mod:SELFCAST]" .. SUPPORT_LOCKED_ALLY
  local deadTarget, deadLock = SUPPORT_DEAD_TARGET, SUPPORT_DEAD_LOCK
  for step = 1, 4 do
    if step == 2 then
      stop = "\n/stopmacro " .. SUPPORT_LOCKED_ALLY
    elseif step == 3 then
      deadLock = ""
    elseif step == 4 then
      deadTarget = ""
    end
    local cast = "/cast " .. units .. deadTarget .. deadLock .. selfCast .. " " .. name
    local text = cast .. stop .. lockLine
    if #text <= SECURE_MACROTEXT_MAX then
      return text
    end
  end
  return nil
end

-- Prioritize Crosshair Target on (the user's call after testing: with it on, the ally you aim
-- at should also become your target, as an enemy does with Reticle Targeting; with it off the
-- heal must leave the target alone so an Ally Cycle pick stays selected): a /tar line ahead of
-- the cast hard-targets the ally the cast is about to pick. The cast below it is unchanged and
-- still resolves to that ally. Falls back to lock + crosshair only, then to no line, when the
-- macro would pass 255 characters. A self-cast with the Self Cast key still moves the target.
local function SupportCrosshairTargetLine(text)
  local char = CM.DB and CM.DB.char
  if not (char and CM.DbBool(char.supportModeCrosshairFirst, false)) then
    return ""
  end
  local full = "/tar " .. SupportCastUnits() .. "\n"
  if #full + #text <= SECURE_MACROTEXT_MAX then
    return full
  end
  local short = "/tar " .. SUPPORT_LOCKED_ALLY .. "[@mouseover,help]\n"
  if #short + #text <= SECURE_MACROTEXT_MAX then
    return short
  end
  return ""
end

-- Auto Target Lock and Prioritize Crosshair Target both on. SupportAutoLockText fills the 255
-- characters by itself, which would leave no room for the /tar line above, so this is one text
-- of its own. The /tar line puts the ally on your target first, so the cast only needs the
-- target (and the dead-lock last resort), and the lock is the enemy auto-lock's own line:
-- "/focus [help,nodead]" has no unit, so it focuses your target. The /stopmacro before it keeps
-- a living lock (already targeted by the /tar line) from being focused again on every heal, and
-- stops a self-cast with the Self Cast key from locking. nil = Prioritize Crosshair Target is
-- off, or the text is too long (the caller then builds the separate forms).
local function SupportAutoLockTargetText(selfCast, name)
  local char = CM.DB and CM.DB.char
  if not (char and CM.DbBool(char.supportModeCrosshairFirst, false)) then
    return nil
  end
  local cast = "/cast " .. SUPPORT_SELF_KEY .. SUPPORT_DEAD_TARGET .. SUPPORT_DEAD_LOCK .. selfCast
  local text = "/tar "
    .. SupportCastUnits()
    .. "\n"
    .. cast
    .. " "
    .. name
    .. "\n/stopmacro [mod:SELFCAST]"
    .. SUPPORT_LOCKED_ALLY
    .. "\n/focus [help,nodead]"
  if #text <= SECURE_MACROTEXT_MAX then
    return text
  end
  return nil
end

-- Support Mode cast: one line that never changes your hard target, unless Prioritize Crosshair
-- Target is on (SupportCrosshairTargetLine above). Order (SupportCastUnits):
-- you while the game's Self Cast key is held, then your living locked ally (Target Lock), then
-- either your living friendly hard target first (the default: an Ally Cycle pick wins over
-- whatever you aim at; clear the target to heal by aim again) or the aimed-at ally first
-- (Prioritize Crosshair Target), then the other, the soft friend, the hard target or the lock
-- when it is a dead ally (SUPPORT_DEAD_TARGET / SUPPORT_DEAD_LOCK), and last
-- you when the game's Auto Self Cast is on (off: every condition fails and nothing is cast).
-- Any friendly hard target counts: a macro can't tell who picked it.
-- /click can't name a unit, so this is a named /cast of the spell on the slot when the macro is
-- built; a Classic rank rides along as "Name(Rank N)".
-- With Auto Target Lock on, two more lines lock the ally who took the heal (SupportAutoLockText,
-- or SupportAutoLockTargetText when Prioritize Crosshair Target is on as well).
-- nil = no name yet: the caller keeps SupportPreLine + /click (which never auto-locks).
local function SupportCastLine(spellId, selfOnly)
  if not spellId or not (C_Spell and C_Spell.GetSpellInfo) then
    return nil
  end
  local info = C_Spell.GetSpellInfo(spellId)
  local name = info and info.name
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local getSubtext = C_Spell.GetSpellSubtext or _G.GetSpellSubtext
  if getSubtext then
    local ok, subtext = pcall(getSubtext, spellId)
    if ok and type(subtext) == "string" and subtext:find("%d") then
      name = name .. "(" .. subtext .. ")"
    end
  end
  if selfOnly then
    return "/cast [@player] " .. name
  end
  local units = SUPPORT_SELF_KEY .. SupportCastUnits()
  local selfCast = AutoSelfCastOn() and "[@player]" or ""
  local text
  if CM.DbBool(CM.DB.char.autoTargetLockOnAttack, false) then
    local combined = SupportAutoLockTargetText(selfCast, name)
    if combined then
      return combined
    end
    text = SupportAutoLockText(units, selfCast, name)
  end
  text = text
    or ("/cast " .. units .. SUPPORT_DEAD_TARGET .. SUPPORT_DEAD_LOCK .. selfCast .. " " .. name)
  return SupportCrosshairTargetLine(text) .. text
end

-- Second return: true when the Support Mode preline was used.
local function GetClickCastPreLine(spellId, routeOverride, opts)
  if not CM.DB.char.reticleTargeting then
    return nil
  end

  local route = routeOverride or GetAllyCycleSpellRoute(spellId)

  if route == "help" and opts and opts.support then
    return SupportPreLine(), true
  end

  -- Helpful: Reticle Targeting friendly-preserving path (not Ally Cycle–gated).
  if route == "help" then
    return CLICKCAST_PRE_LINE_ALLY_HELP
  end

  -- Harmful + cycle keys: enemy / restore-aware preline (including solo).
  local support = opts and opts.support
  if AllyCycleKeysBound() and route == "harm" then
    return GetAllyCycleHarmPreLine(support)
  end

  -- Unclassified + cycle keys: treat as help (same as when cycling is on).
  if AllyCycleKeysBound() then
    return CLICKCAST_PRE_LINE_ALLY_HELP
  end

  return CM.GetActiveTargetingPreline(support)
end

local function GetClickCastPostLine(spellId, routeOverride, opts)
  if not CM.DB.char.reticleTargeting then
    return nil
  end
  if not (AllyCycleKeysBound() and AllyCycleInGroup()) then
    return nil
  end
  if (routeOverride or GetAllyCycleSpellRoute(spellId)) ~= "harm" then
    return nil
  end
  return GetAllyCycleHarmPostLine(opts and opts.support)
end

--- `opts` (optional, Support Mode): `page` classifies an ACTIONBUTTON by that bar page instead of
--- the shown one; `support = true` gives helpful spells the Support Mode cast (your living
--- friendly hard target, else the ally under the crosshair or soft-targeted, else you if the
--- game's Self Cast setting says so). Second return: true when that cast was used.
function CM.BuildClickCastMacroText(bindingValue, opts)
  -- When reticle targeting is off, no macro wrapping (no pre-line, no castAtCursor, no excludeFromTargeting).
  if not CM.DB.char.reticleTargeting then
    return nil
  end

  -- For ACTIONBUTTON bindings, use a conditional /click so action bar type is resolved
  -- at macro run time (works when action bars change in combat; we can't refresh bindings then).
  local buttonNum = bindingValue:match("^ACTIONBUTTON(%d+)$")
  local useConditionalClick = buttonNum ~= nil

  local clickFrame = ResolveActionButtonFrame(bindingValue)
  if not clickFrame then
    return nil
  end
  local effectiveFrame = CM.GetEffectiveBarButtonFrameName(bindingValue) or clickFrame

  -- Check if this is a special action bar button (don't inject preline for special bar abilities)
  local isSpecialBarButton = clickFrame:match("^OverrideActionBarButton")
    or clickFrame:match("^BonusActionButton")
    or clickFrame:match("^TempShapeshiftActionButton")

  local castLine
  if useConditionalClick then
    -- Use conditional macro to check for override bar at runtime
    -- (works when exiting vehicle in combat; we can't refresh bindings then)
    -- For bonus/shapeshift bars, bindings are refreshed via events when out of combat
    local regularFrame = FindPrimaryBarButtonFrame(buttonNum) or ("ActionButton" .. buttonNum)

    local overrideFrame = "OverrideActionBarButton" .. buttonNum
    castLine = "/click "
      .. CLICK_BAR_STATE_CONDITIONS
      .. " "
      .. overrideFrame
      .. ClickArgs(overrideFrame)
      .. "; "
      .. regularFrame
      .. ClickArgs(regularFrame)
  else
    castLine = FormatClickLine(effectiveFrame)
  end

  -- Classify from the currently displayed slot (paged / bonus / override-aware).
  -- Macros: no pre-line so the macro runs as written (e.g. [mod:shift], [@cursor]).
  local atype, id, slot = CM.GetDisplayedActionSlotInfo(bindingValue, opts and opts.page)
  local spellIdForPreline
  -- Single-Button Assistant: its slot spell is whatever is suggested right now, so it is never
  -- classified by spell. It gets the harmful targeting route and skips the spell-based exclude /
  -- cast-at-cursor / combat-spell checks (which would otherwise drop the pre-line whenever the
  -- suggestion is a non-combat or placeholder spell, e.g. right after loading).
  local isAssistedButton = false
  if atype == "macro" then
    -- A proxy only gets here for a page that is not showing: run the macro's text (MacroSlotText).
    return MacroSlotText(slot) or castLine
  end
  if atype then
    local idNum = tonumber(id)
    isAssistedButton = IsAssistedCombatButton(slot, idNum)
    -- Auto-swing / Pet Attack IDs can show up as non-spell action types.
    if not isAssistedButton and atype ~= "spell" and not IsAutoSwingSpell(idNum) then
      return castLine
    end
    if idNum and idNum > 0 and not isAssistedButton then
      spellIdForPreline = idNum
    end
    -- Special action bar abilities (override, bonus, shapeshift): don't inject pre-line, just click the button directly
    if isSpecialBarButton then
      return castLine
    end
    -- Explicit self targeting takes precedence over targeting exclusions/cursor casting.
    -- Support Mode keeps its existing routing and special bars/macros remain untouched.
    if
      not isAssistedButton
      and CM.ShouldSelfCastOutsideSupport(spellIdForPreline)
      and not (opts and opts.support)
    then
      -- Never fall back to /click here: it could cast on an ally while data is unavailable.
      return SupportCastLine(spellIdForPreline, true) or "/stopmacro"
    end
    -- Spell in blacklist (e.g. self-cast defensives): don't apply targeting pre-line.
    if
      not isAssistedButton
      and spellIdForPreline
      and CM.IsExcludedFromTargetingSpell(spellIdForPreline)
    then
      return castLine
    end
    -- Ground-targeted spell from whitelist: use /cast [@cursor] only (no pre-line).
    -- Must run before ShouldInjectTargetingForSpell: many ground spells are neither helpful nor harmful per C_Spell API.
    if not isAssistedButton and spellIdForPreline and CM.IsCastAtCursorSpell(spellIdForPreline) then
      local spellInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellIdForPreline)
      local spellName = spellInfo and spellInfo.name
      if spellName and spellName ~= "" then
        return "/cast [@cursor] " .. spellName
      end
      return "/cast [@cursor] spell:" .. spellIdForPreline
    end
    -- Non-combat spells (e.g. mounts) shouldn't get the targeting pre-line.
    if not isAssistedButton and not ShouldInjectTargetingForSpell(spellIdForPreline) then
      return castLine
    end
  end

  -- Don't inject preline for special action bar buttons
  if isSpecialBarButton then
    return castLine
  end

  -- /click Attack after /tar toggles relative to "already swinging," so a swap
  -- turns the ability off. /startattack and /cast ! only start (or keep) the swing.
  if IsAutoSwingSpell(spellIdForPreline) then
    local kind = AutoSwingKind(spellIdForPreline) or "attack"
    local pre = GetClickCastPreLine(spellIdForPreline, nil, opts)
    local swapCmd = AutoSwingSwapCommand(kind, spellIdForPreline)
    return pre and (pre .. "\n" .. swapCmd) or swapCmd
  end

  local routeOverride = isAssistedButton and "harm" or nil
  local pre, supportPreline = GetClickCastPreLine(spellIdForPreline, routeOverride, opts)
  if supportPreline then
    local supportLine = SupportCastLine(spellIdForPreline)
    if supportLine then
      return supportLine, true
    end
  end
  local post = GetClickCastPostLine(spellIdForPreline, routeOverride, opts)
  -- Do not prefix pre-line with [nooverridebar]; that can be misinterpreted in combat and echo to chat.
  local function Assemble(preLine)
    local text = castLine
    if preLine then
      text = preLine .. "\n" .. text
    end
    if post then
      text = text .. "\n" .. post
    end
    return text
  end
  local text = Assemble(pre)
  -- A preline with a slimmer stand-in gives way when the whole macro would not fit in 255.
  local slimmer = pre and SLIMMER_PRELINE[pre]
  if slimmer and #text > SECURE_MACROTEXT_MAX then
    text = Assemble(slimmer)
  end
  return text, supportPreline or false
end
