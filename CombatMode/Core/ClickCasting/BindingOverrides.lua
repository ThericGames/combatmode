---------------------------------------------------------------------------------------
--  Core/ClickCasting/BindingOverrides.lua — CLICKCAST — secure proxies + overrides
---------------------------------------------------------------------------------------
--  What it does: Creates SecureActionButtonTemplate proxy frames, applies mouselook and
--  keyboard override bindings for click-cast slots, ground @cursor casts, the
--  toggle-focus bind, and configurable Target Lock cycle keybinds.
--  Architecture / how it works:
--    • Honors char.reticleTargeting, macroInjectionClickCastOnly (except explicit slot 1
--      lock-and-attack), and GetBindingsLocation() for which bindings table to read.
--    • SetNewBinding / OverrideDefaultButtons / ResetBindingOverride — per-slot secure
--      attributes + SetMouselookOverrideBinding / SetOverrideBindingClick. STARTATTACK
--      / PETATTACK are reticle /tar + /startattack or /petattack (not raw Blizzard binds).
--    • Proxy macros (Clear Target, pings, markers) and which keys skip the proxy: see .claude/rules/domain-click-casting.md (BindingOverrides.lua notes).
--    • ApplyGroundCastKeyOverrides — keyboard keys click the same proxy so prelines run
--      for ACTIONBUTTON + MULTIACTIONBAR1–7 (CM.Constants.ClickCastBars).
--    • ApplyToggleFocusTargetBinding — Action Combat Mode Target Lock keybind; its macro is chosen from
--      char.targetLockBehavior (Toggle / Switch Target) (always clears
--      override owner first so stolen keys cannot leave a stale click override). No-ops
--      install when char.reticleTargeting is off (CM.IsTargetLockEnabled).
--    • Mid-combat RefreshClickCastMacros / ApplyGroundCastKeyOverrides /
--      ApplyToggleFocusTargetBinding set a pending flag; EventRouter flushes on
--      PLAYER_REGEN_ENABLED via FlushPendingClickCastRefresh (silent; BindingQueue
--      remains for options UI deferred applies).
--    • ApplyCycleFocusBindings — dedicated Bindings.xml cycle keys via
--      SetOverrideBindingClick (user assigns keys in options or Key Bindings UI).
--    • UpdateFocusCycleWheelBindings — alias for ApplyCycleFocusBindings.
--    • AssignNamedKeybind / ClearInteractOrphansOnKey — shared options keybind helpers.
--    • Combat-safe via BindingQueue when options change mid-combat.
--    • RefreshClickCastMacros also runs CM.RebuildComposedMacros so composer-built
--      macros follow the active preline (lockdown refreshes are queued, flushed on regen).
--    • Support Mode: click-cast and main-bar proxies store a second macro text
--      (BuildModeMacroTexts → CM.SetModeMacroText) that SupportMode.lua's secure key swaps in;
--      the Target Lock / cycle keys and Toggle Focus actions get friendly-only twins the same way.
--  Does not: Resolve ElvUI/BT4 frame names (AddonActionBarResolver) or build preline text
--  (TargetingMacroBuilder).
--  Related: Core/ClickCasting/TargetingMacroBuilder.lua, Core/ClickCasting/ComposedMacros.lua,
--  Core/ClickCasting/{AddonActionBarResolver,SupportMode}.lua, Core/Runtime/BindingQueue.lua,
--  Core/Runtime/EventRouter.lua, Core/Runtime/Bootstrap.lua,
--  UI/Options/Tabs/TabClickCasting.lua, UI/Options/Tabs/TabGeneral.lua, Constants/Gameplay.lua
---------------------------------------------------------------------------------------
local _, CM = ...
local _G = _G

-- WoW API
local CreateFrame = _G.CreateFrame
local ClearOverrideBindings = _G.ClearOverrideBindings
local GetActionInfo = _G.GetActionInfo
local GetBindingAction = _G.GetBindingAction
local GetBindingKey = _G.GetBindingKey
local GetCurrentBindingSet = _G.GetCurrentBindingSet
local InCombatLockdown = _G.InCombatLockdown
local SaveBindings = _G.SaveBindings
local SetBinding = _G.SetBinding
local SetMouselookOverrideBinding = _G.SetMouselookOverrideBinding
local SetOverrideBinding = _G.SetOverrideBinding
local SetOverrideBindingClick = _G.SetOverrideBindingClick
local SecureHandlerWrapScript = _G.SecureHandlerWrapScript
local UIParent = _G.UIParent

-- Lua stdlib
local ipairs = _G.ipairs
local pairs = _G.pairs
local pcall = _G.pcall
local select = _G.select
local tonumber = _G.tonumber
local tostring = _G.tostring
local type = _G.type

local pendingClickCastRefresh = false

local function MarkPendingClickCastRefresh()
  pendingClickCastRefresh = true
end

-- Click-cast macro wrapper: binding value (e.g. ACTIONBUTTON1) -> pre-line + /click frameName.
-- Shared map includes ACTIONBUTTON + MULTIACTIONBAR1–7 (MultiBar5–7 = DF+ bars).
local CLICKCAST_BARS = CM.Constants.ClickCastBars
  or {
    { bind = "ACTIONBUTTON", frame = "ActionButton", count = 12 },
    { bind = "MULTIACTIONBAR1BUTTON", frame = "MultiBarBottomLeftButton", count = 12 },
    { bind = "MULTIACTIONBAR2BUTTON", frame = "MultiBarBottomRightButton", count = 12 },
    { bind = "MULTIACTIONBAR3BUTTON", frame = "MultiBarRightButton", count = 12 },
    { bind = "MULTIACTIONBAR4BUTTON", frame = "MultiBarLeftButton", count = 12 },
  }

-- Reticle targeting macro text helpers live in TargetingMacroBuilder.lua.

-- Ordered list of all binding names (ACTIONBUTTON1..12, MULTIACTIONBAR1–7BUTTON1..12).
local OrderedBindingNames = {}
for _, bar in ipairs(CLICKCAST_BARS) do
  for i = 1, bar.count do
    OrderedBindingNames[#OrderedBindingNames + 1] = bar.bind .. i
  end
end

-- Owner frame only for ClearOverrideBindings / SetOverrideBinding*; proxy buttons live on UIParent
-- like CombatModeClickCast* so secure macro execution matches the working mouselook path.
local GroundCastKeyOverrideOwner = CreateFrame("Frame", nil, UIParent)
local SlotFramesByBindingName = {}

for idx, bindingName in ipairs(OrderedBindingNames) do
  local f = CreateFrame("Button", "CombatModeSlot" .. idx, UIParent, "SecureActionButtonTemplate")
  f:SetAttribute("type", "macro")
  f:RegisterForClicks("AnyUp", "AnyDown")
  SlotFramesByBindingName[bindingName] = f
  -- Only the main bar is paged, so only its keys have a second (Support Mode) macro text.
  if bindingName:match("^ACTIONBUTTON%d+$") then
    CM.SupportModeRegisterProxy(f)
  end
end

-- Click pre-line moved to TargetingMacroBuilder.lua

local CLICKCAST_KEYS = {
  "BUTTON1",
  "BUTTON2",
  "SHIFT-BUTTON1",
  "SHIFT-BUTTON2",
  "CTRL-BUTTON1",
  "CTRL-BUTTON2",
  "ALT-BUTTON1",
  "ALT-BUTTON2",
}
local ClickCastFramesByKey = {}
for i, key in ipairs(CLICKCAST_KEYS) do
  local f =
    CreateFrame("Button", "CombatModeClickCast" .. i, UIParent, "SecureActionButtonTemplate")
  f:SetAttribute("type", "macro")
  f:RegisterForClicks("AnyUp", "AnyDown")
  ClickCastFramesByKey[key] = f
  CM.SupportModeRegisterProxy(f)
end

-- Secure action button for toggle focus target
local ToggleFocusTargetOverrideOwner = CreateFrame("Frame", nil, UIParent)
local ToggleFocusTargetButton = CreateFrame(
  "Button",
  "CombatModeToggleFocusTarget",
  ToggleFocusTargetOverrideOwner,
  "SecureActionButtonTemplate"
)
ToggleFocusTargetButton:SetAttribute("type", "macro")
-- macrotext set by UpdateToggleFocusTargetMacroText() based on targetLockBehavior
ToggleFocusTargetButton:RegisterForClicks("AnyUp", "AnyDown")
-- Support Mode swaps in the friendly-only lock macro (and the friendly cycle macros below).
CM.SupportModeRegisterProxy(ToggleFocusTargetButton)

-- Configurable Target Lock cycle (nearest / previous enemy → focus).
-- Dedicated Bindings.xml keys + SetOverrideBindingClick (same model as Target Lock).
-- Duplicate keys are resolved by the engine when the user assigns binds in options.
-- Secure PreClick: UnitExists("focus") → cycle macro; else no-op.
local CycleFocusOverrideOwner = CreateFrame("Frame", nil, UIParent)

local CycleFocusEnemyNextButton = CreateFrame(
  "Button",
  "CombatModeCycleFocusEnemyNext",
  CycleFocusOverrideOwner,
  "SecureActionButtonTemplate, SecureHandlerBaseTemplate"
)
CycleFocusEnemyNextButton:SetAttribute("type", "macro")
CycleFocusEnemyNextButton:RegisterForClicks("AnyUp", "AnyDown")

local CycleFocusEnemyPrevButton = CreateFrame(
  "Button",
  "CombatModeCycleFocusEnemyPrev",
  CycleFocusOverrideOwner,
  "SecureActionButtonTemplate, SecureHandlerBaseTemplate"
)
CycleFocusEnemyPrevButton:SetAttribute("type", "macro")
CycleFocusEnemyPrevButton:RegisterForClicks("AnyUp", "AnyDown")
CM.SupportModeRegisterProxy(CycleFocusEnemyNextButton)
CM.SupportModeRegisterProxy(CycleFocusEnemyPrevButton)

if SecureHandlerWrapScript then
  SecureHandlerWrapScript(
    CycleFocusEnemyNextButton,
    "PreClick",
    CycleFocusEnemyNextButton,
    [[
      if UnitExists("focus") then
        self:SetAttribute("type", "macro")
      else
        self:SetAttribute("type", nil)
      end
    ]]
  )
  SecureHandlerWrapScript(
    CycleFocusEnemyPrevButton,
    "PreClick",
    CycleFocusEnemyPrevButton,
    [[
      if UnitExists("focus") then
        self:SetAttribute("type", "macro")
      else
        self:SetAttribute("type", nil)
      end
    ]]
  )
end

local function EnsureFocusCycleMacroText()
  local macros_const = CM.Constants and CM.Constants.Macros
  if not macros_const or InCombatLockdown() then
    return
  end
  -- Second text: Support Mode cycles friendly units instead (the secure key swaps them in combat).
  -- Players only, unless the Cycle NPCs and Pets option is on.
  local withNPCs = CM.DbBool(CM.DB.char.supportModeCycleNPCs, false)
  CM.SetModeMacroText(
    CycleFocusEnemyNextButton,
    macros_const.CM_CycleFocusEnemyNext,
    withNPCs and macros_const.CM_CycleFocusFriendAllNext or macros_const.CM_CycleFocusFriendNext
  )
  CM.SetModeMacroText(
    CycleFocusEnemyPrevButton,
    macros_const.CM_CycleFocusEnemyPrev,
    withNPCs and macros_const.CM_CycleFocusFriendAllPrev or macros_const.CM_CycleFocusFriendPrev
  )
end

--- Target Lock (focus toggle, wheel cycle, marker, sounds) requires Reticle Targeting.
function CM.IsTargetLockEnabled()
  return CM.DB and CM.DB.char and CM.DB.char.reticleTargeting and true or false
end

--- Install/clear SetOverrideBindingClick for cycle binds. Call out of combat
--- (BindingQueue defers option toggles). PreClick reads UnitExists("focus") at click time.
function CM.ApplyCycleFocusBindings()
  if InCombatLockdown() then
    MarkPendingClickCastRefresh()
    return
  end
  ClearOverrideBindings(CycleFocusOverrideOwner)
  if not CM.IsTargetLockEnabled() then
    CM.DebugPrint("Cycle Focus bindings override cleared (Reticle Targeting off)")
    return
  end
  EnsureFocusCycleMacroText()
  local nextKey = GetBindingKey("Combat Mode - Cycle Focus Next")
  if nextKey then
    SetOverrideBindingClick(
      CycleFocusOverrideOwner,
      false,
      nextKey,
      CycleFocusEnemyNextButton:GetName(),
      "LeftButton"
    )
    CM.DebugPrint("Cycle Focus Next binding applied to " .. tostring(nextKey))
  end
  local prevKey = GetBindingKey("Combat Mode - Cycle Focus Previous")
  if prevKey then
    SetOverrideBindingClick(
      CycleFocusOverrideOwner,
      false,
      prevKey,
      CycleFocusEnemyPrevButton:GetName(),
      "LeftButton"
    )
    CM.DebugPrint("Cycle Focus Previous binding applied to " .. tostring(prevKey))
  end
end

function CM.UpdateFocusCycleWheelBindings()
  CM.ApplyCycleFocusBindings()
end

--- Support Mode text of the Target Lock key / Toggle Focus actions: friendly units only, same
--- Target Lock Behavior (Toggle / Switch Target).
local function SupportFocusMacroText()
  local macros_const = CM.Constants.Macros
  if CM.DB.char.targetLockBehavior == "switch" then
    return macros_const.CM_SwitchFocusSupport
  end
  return macros_const.CM_ToggleFocusSupport
end

local function UpdateToggleFocusTargetMacroText()
  if not ToggleFocusTargetButton then
    return
  end
  local char_config = CM.DB.char
  local macros_const = CM.Constants.Macros
  local macroText
  if char_config.targetLockBehavior == "switch" then
    macroText = macros_const.CM_SwitchFocusEnemy
  else
    macroText = macros_const.CM_ToggleFocusEnemy
  end
  CM.SetModeMacroText(ToggleFocusTargetButton, macroText, SupportFocusMacroText())
end

-- BuildClickCastMacroText moved to TargetingMacroBuilder.lua

-- `supportText` (optional) is what the proxy runs while Support Mode is on, `selfText`
-- (optional) while its self-cast key is held as well; the secure keys swap them in combat
-- (CM.SetModeMacroText).
local function SetClickCastFrameMacro(frame, macroText, supportText, selfText)
  CM.SetModeMacroText(frame, macroText, supportText, selfText)
end

-- Normal, Support Mode and Support Mode self-cast macro texts for a bar binding (nil = no extra
-- text; only a helpful spell on a click-cast mouse button has the third).
--  • `strict` (click-cast mouse buttons): helpful spells become a cast on your living friendly
--    hard target (an Ally Cycle pick), else on the ally under the crosshair or soft-targeted
--    (it never changes your target). Keyboard keys keep the normal routing, classified for the
--    support page.
--  • While the mode is on the support page is the one showing, so the normal text is classified
--    from the page the mode returns to (page 1) instead of the displayed slot.
local function BuildModeMacroTexts(bindingValue, strict)
  local ctx = CM.GetSupportModeBuildContext()
  if not ctx then
    return (CM.BuildClickCastMacroText(bindingValue)), nil
  end
  local page, active = ctx.page, ctx.active
  local isMainBar = bindingValue:match("^ACTIONBUTTON%d+$") ~= nil
  if not strict and not (page and isMainBar) then
    return (CM.BuildClickCastMacroText(bindingValue)), nil
  end
  local normalText =
    CM.BuildClickCastMacroText(bindingValue, active and page and { page = 1 } or nil)
  if not strict then
    return normalText, (CM.BuildClickCastMacroText(bindingValue, { page = page }))
  end
  local supportText, _, selfText =
    CM.BuildClickCastMacroText(bindingValue, { page = page, support = true })
  return normalText, supportText, selfText
end

-- Returns true if the given action bar binding currently has a macro in the
-- *displayed* slot (paged / bonus / override-aware via GetDisplayedActionSlotInfo).
local function IsSlotMacro(bindingValue)
  local atype = CM.GetDisplayedActionSlotInfo(bindingValue)
  return atype == "macro"
end

--- Spell id on the currently displayed action for this binding, or nil if not a spell.
local function GetSpellIdForActionBarBinding(bindingName)
  local atype, id = CM.GetDisplayedActionSlotInfo(bindingName)
  if atype ~= "spell" or not id or type(id) ~= "number" or id <= 0 then
    return nil
  end
  return id
end

-- House Editor (housing) is active; do not override action bar keys so housing bindings (e.g. R to return item) work.
local function IsHouseEditorActive()
  if not _G.C_HouseEditor or not _G.C_HouseEditor.IsHouseEditorActive then
    return false
  end
  local ok, active = pcall(_G.C_HouseEditor.IsHouseEditorActive)
  return ok and active
end

local function IsMouseBindingKey(key)
  if not key or key == "" then
    return false
  end
  return key:match("BUTTON%d+") ~= nil or key:match("MOUSEWHEEL") ~= nil
end

-- Ground keyboard path: override keys to click a frame.
-- Use LeftButton clicks; this is the most reliable click type across Blizzard bars and our proxy buttons.
-- Priority overrides so ReassignBindings does not replace Combat Mode last.
local GROUND_CAST_KEY_PRIORITY = true

local function ApplyGroundCastKeyboardBinding(key, frameName)
  if not key or not frameName or frameName == "" then
    return
  end
  -- Match ApplyToggleFocusTargetBinding: SetOverrideBindingClick drives SecureActionButtonTemplate reliably.
  SetOverrideBindingClick(
    GroundCastKeyOverrideOwner,
    GROUND_CAST_KEY_PRIORITY,
    key,
    frameName,
    "LeftButton"
  )
end

-- Override keyboard keys (Q, E, etc.) to click our slot frame so the same macro logic runs (pre-line + /click or /cast [@cursor] for ground spells). No per-spell macros.
-- When macroInjectionClickCastOnly is true, skip keyboard overrides so only the 8 click-cast mouse bindings get the injection.

function CM.FlushPendingClickCastRefresh()
  if InCombatLockdown() or not pendingClickCastRefresh then
    return
  end
  pendingClickCastRefresh = false
  CM.RefreshClickCastMacros()
  if CM.ApplyToggleFocusTargetBinding then
    CM.ApplyToggleFocusTargetBinding()
  end
  if CM.ApplyCycleFocusBindings then
    CM.ApplyCycleFocusBindings()
  end
end

function CM.ApplyGroundCastKeyOverrides()
  if InCombatLockdown() then
    MarkPendingClickCastRefresh()
    return
  end
  ClearOverrideBindings(GroundCastKeyOverrideOwner)
  -- When reticle targeting is off, no macro injection on keybinds at all.
  if not CM.DB.char.reticleTargeting then
    return
  end
  local clickCastOnly = CM.DB.char.macroInjectionClickCastOnly
  local lockActionButton1 = CM.DbBool(CM.DB.char.targetLockActionButton1, false)
  if clickCastOnly and not lockActionButton1 then
    return
  end
  -- When House Editor (housing) is active, do not override action bar keys so housing bindings (e.g. R to return item to box) work.
  if IsHouseEditorActive() then
    return
  end

  for bindingIndex, bindingName in ipairs(OrderedBindingNames) do
    local key1 = GetBindingKey(bindingName)
    local key2 = select(2, GetBindingKey(bindingName))
    local keys = { key1, key2 }

    for _, key in ipairs(keys) do
      -- Never override mouse-button bindings here; click-cast already owns mouse buttons.
      if
        key
        and not IsMouseBindingKey(key)
        and (not clickCastOnly or (lockActionButton1 and bindingName == "ACTIONBUTTON1"))
      then
        local realFrame = CM.GetEffectiveBarButtonFrameName(bindingName)
        if realFrame and IsSlotMacro(bindingName) then
          -- Slot is a macro: do not inject (nested macro /click is a no-op).
          -- Normal ActionButton/MultiBar: native bind name (same path as page-1 macros).
          -- Bonus/Override/TempShapeshift: click the live frame so Classic-style overlay
          -- bars are not sent to the hidden main ActionButton.
          if CM.IsSpecialLogicalBarFrameName and CM.IsSpecialLogicalBarFrameName(realFrame) then
            SetOverrideBindingClick(
              GroundCastKeyOverrideOwner,
              GROUND_CAST_KEY_PRIORITY,
              key,
              realFrame,
              "LeftButton"
            )
          else
            SetOverrideBinding(
              GroundCastKeyOverrideOwner,
              GROUND_CAST_KEY_PRIORITY,
              key,
              bindingName
            )
          end
        else
          local spellId = GetSpellIdForActionBarBinding(bindingName)
          if
            realFrame
            and spellId
            and CM.IsExcludedFromTargetingSpell(spellId)
            and not CM.IsCastAtCursorSpell(spellId)
          then
            SetOverrideBinding(
              GroundCastKeyOverrideOwner,
              GROUND_CAST_KEY_PRIORITY,
              key,
              bindingName
            )
          else
            local frame = SlotFramesByBindingName[bindingName]
            local macroText, supportText = BuildModeMacroTexts(bindingName, false)
            if frame and macroText then
              SetClickCastFrameMacro(frame, macroText, supportText)
              -- Party Wheel spell on this key: the wheel's key button runs the same macro on a tap.
              local wheelButton, wheelArg
              if CM.PartyWheelPrepareKey then
                wheelButton, wheelArg =
                  CM.PartyWheelPrepareKey(bindingIndex, bindingName, macroText, supportText)
              end
              if wheelButton then
                SetOverrideBindingClick(
                  GroundCastKeyOverrideOwner,
                  GROUND_CAST_KEY_PRIORITY,
                  key,
                  wheelButton,
                  wheelArg
                )
              else
                ApplyGroundCastKeyboardBinding(key, frame:GetName())
              end
            end
          end
        end
      end
    end
  end
end

function CM.RefreshClickCastMacros()
  return CM.Profile("Bind:RefreshMacros", function()
    if InCombatLockdown() then
      MarkPendingClickCastRefresh()
      return
    end
    pendingClickCastRefresh = false
    CM.ClearAddonButtonCaches()
    -- Keep macros built via the Macro Composer in step with the active preline. First: a proxy
    -- may run a bar macro's text (the other Support Mode page), read while the keys are rebuilt.
    if CM.RebuildComposedMacros then
      CM.RebuildComposedMacros()
    end
    if CM.ResetInlinedMacroTexts then
      CM.ResetInlinedMacroTexts()
    end
    -- Re-apply all bindings so macro slots get "click real button" and spell slots get our frame.
    -- This refreshes both keyboard bindings (via ApplyGroundCastKeyOverrides) and mouse button bindings (via OverrideDefaultButtons)
    CM.OverrideDefaultButtons()
    CM.ApplyGroundCastKeyOverrides()
  end)
end

-- Compact snapshot of action-bar slot contents (type+id). Used to ignore noisy
-- ACTIONBAR_SLOT_CHANGED bursts that do not change spells/items/macros we care about.
-- Uses a numeric hash to minimize per-call string allocation.
local FINGERPRINT_PRIME = 31
function CM.GetActionBarContentFingerprint()
  local fingerprint = 0
  for slot = 1, 180 do
    local ok, atype, id = pcall(GetActionInfo, slot)
    if ok and atype then
      local typeByte = atype:byte() or 0
      local idNum = tonumber(id) or 0
      fingerprint = fingerprint * FINGERPRINT_PRIME + slot + typeByte + idNum
    end
  end
  return fingerprint
end

local function ClickCastMouseButton(key)
  return key:match("BUTTON2") and "RightButton" or "LeftButton"
end

-- Click-cast action values that run a macro text of ours (not a player macro): the CM.Constants.Macros
-- texts, and the Blizzard bindings we replace (CM.Constants.BlizzardActionMacros: pings and raid
-- markers, which then act on the unit under the crosshair).
local ACTION_MACRO_TEXTS = {
  CLEARTARGET = CM.Constants.Macros.CM_ClearTarget,
  CLEARFOCUS = CM.Constants.Macros.CM_ClearFocus,
  STARTATTACK = CM.Constants.Macros.CM_StartAttack,
  PETATTACK = CM.Constants.Macros.CM_PetAttack,
}
-- Toggle Focus click-cast actions follow Target Lock Behavior (Toggle / Switch Target).
local FOCUS_ACTION_MACRO_KEYS = {
  TOGGLEFOCUSENEMY = { toggle = "CM_ToggleFocusEnemy", switch = "CM_SwitchFocusEnemy" },
}
-- Second return: the Support Mode text (Toggle Focus actions lock friendly units there), or nil.
local function ActionMacroText(value)
  local focus = FOCUS_ACTION_MACRO_KEYS[value]
  if focus then
    local behavior = CM.DB.char.targetLockBehavior == "switch" and "switch" or "toggle"
    return CM.Constants.Macros[focus[behavior]], SupportFocusMacroText()
  end
  return ACTION_MACRO_TEXTS[value]
end
for value, text in pairs(CM.Constants.BlizzardActionMacros) do
  ACTION_MACRO_TEXTS[value] = text
end

function CM.SetNewBinding(buttonSettings)
  if not buttonSettings.enabled then
    return
  end

  local key, value = buttonSettings.key, buttonSettings.value
  local valueToUse
  if value == "MACRO" then
    valueToUse = "MACRO " .. buttonSettings.macroName
  elseif ActionMacroText(value) then
    -- Combat Mode's own click-cast actions: their macro text goes on this key's proxy button and
    -- the key clicks it, so nothing has to exist in the player's macro list.
    local frame = ClickCastFramesByKey[key]
    local macroText, supportText = ActionMacroText(value)
    if frame and macroText then
      SetClickCastFrameMacro(frame, macroText, supportText)
      valueToUse = "CLICK " .. frame:GetName() .. ":" .. ClickCastMouseButton(key)
    end
  else
    -- When reticle targeting is off, no macro wrapping: use raw binding (no pre-line, no castAtCursor/excludeFromTargeting).
    if not CM.DB.char.reticleTargeting then
      valueToUse = value
    else
      local realFrame = CM.GetEffectiveBarButtonFrameName(value)
      if realFrame and IsSlotMacro(value) then
        -- Slot is a macro: bind key to click the real action bar button so the macro runs as written.
        valueToUse = "CLICK " .. realFrame .. ":" .. ClickCastMouseButton(key)
      else
        local frame = ClickCastFramesByKey[key]
        local macroText, supportText, selfText = BuildModeMacroTexts(value, true)
        if frame and macroText then
          SetClickCastFrameMacro(frame, macroText, supportText, selfText)
          valueToUse = "CLICK " .. frame:GetName() .. ":" .. ClickCastMouseButton(key)
        else
          valueToUse = value
        end
      end
    end
  end
  SetMouselookOverrideBinding(key, valueToUse)
end

function CM.OverrideDefaultButtons()
  for _, button in pairs(CM.Constants.ButtonsToOverride) do
    CM.SetNewBinding(CM.DB[CM.GetBindingsLocation()].bindings[button])
  end
end

function CM.ResetBindingOverride(buttonSettings)
  SetMouselookOverrideBinding(buttonSettings.key, nil)
  CM.DebugPrint(buttonSettings.key .. "'s override binding is now cleared")
end

-- Apply override binding for toggle focus target. Always clear first so a stolen /
-- unbound Target Lock key cannot leave a stale SetOverrideBindingClick active.
-- Reticle Targeting off: clear only (Target Lock requires SoftTarget / reticle).
function CM.ApplyToggleFocusTargetBinding()
  if InCombatLockdown() then
    MarkPendingClickCastRefresh()
    return
  end
  ClearOverrideBindings(ToggleFocusTargetOverrideOwner)
  if not CM.IsTargetLockEnabled() then
    CM.DebugPrint("Toggle Focus Target override cleared (Reticle Targeting off)")
    return
  end
  UpdateToggleFocusTargetMacroText()
  local key = GetBindingKey("Combat Mode - Toggle Focus Target")
  if key then
    SetOverrideBindingClick(
      ToggleFocusTargetOverrideOwner,
      false,
      key,
      ToggleFocusTargetButton:GetName(),
      "LeftButton"
    )
    CM.DebugPrint("Toggle Focus Target binding applied to " .. tostring(key))
  else
    CM.DebugPrint("Toggle Focus Target override cleared (no key bound)")
  end
end

local INTERACT_MOUSEOVER = "INTERACTMOUSEOVER"
local INTERACT_TARGET = "INTERACTTARGET"

local function IsInteractAction(action)
  return action == INTERACT_MOUSEOVER or action == INTERACT_TARGET
end

--- Clears Interact on `key` and `ALT-key` when those chords still hold INTERACT*.
--- Mouse Look / Ally Cycle / Target Lock steal only the base key; Interact's intentional
--- dual-bind otherwise leaves ALT-<key> behind and the Interact option shows Alt+key.
--- Always try ALT-<key> too — including when `key` is already ALT-* — so a leftover
--- ALT-ALT-* orphan (from an older dual-bind bug) is cleared when the chord is stolen.
function CM.ClearInteractOrphansOnKey(key)
  if not key or key == "" or not GetBindingAction or not SetBinding then
    return
  end
  if IsInteractAction(GetBindingAction(key)) then
    SetBinding(key)
  end
  local altKey = "ALT-" .. key
  if IsInteractAction(GetBindingAction(altKey)) then
    SetBinding(altKey)
  end
end

--- Assign (or clear) a named binding command, clear Interact orphans on the new key,
--- save bindings, and refresh Target Lock + Cycle Lock override layers.
function CM.AssignNamedKeybind(command, key)
  if not command or command == "" then
    return
  end
  local oldKey = GetBindingKey(command)
  while oldKey do
    SetBinding(oldKey)
    oldKey = GetBindingKey(command)
  end
  if key and key ~= "" then
    CM.ClearInteractOrphansOnKey(key)
    SetBinding(key, command)
  end
  if SaveBindings and GetCurrentBindingSet then
    SaveBindings(GetCurrentBindingSet())
  end
  CM.ApplyToggleFocusTargetBinding()
  if CM.ApplyCycleFocusBindings then
    CM.ApplyCycleFocusBindings()
  end
end

-- Handler for toggle focus target keybinding (fallback - should be overridden)
function _G.CombatMode_ToggleFocusTarget()
  -- Nothing inside here will work as it will be overriden by ApplyToggleFocusTargetBinding calling UpdateToggleFocusTargetMacroText
end

function _G.CombatMode_CycleFocusNext()
  -- Overridden by ApplyCycleFocusBindings via SetOverrideBindingClick.
end

function _G.CombatMode_CycleFocusPrevious()
  -- Overridden by ApplyCycleFocusBindings via SetOverrideBindingClick.
end
