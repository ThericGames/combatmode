---------------------------------------------------------------------------------------
--  UI/Editors/TargetingMacroPrelinesEditor.lua — EDITOR — targeting macro prelines
---------------------------------------------------------------------------------------
--  What it does: Standalone editor (CM.OpenTargetingMacroPrelinesEditor) for customizing
--  the targeting prelines injected into click-cast macros. Shows both preline fields
--  (normal + Auto Target Lock); the inactive one uses the disabled watermark overlay
--  based on Auto Target Lock.
--  Architecture / how it works:
--    • Defaults from TargetingMacroBuilder.TargetingMacroPrelinesDefaults.
--    • Override keys: targetingMacroPrelineEnemyOverride / AutoLockEnemyOverride.
--    • Active field = Auto Target Lock mode; the other stays visible but stamped Inactive.
--    • Max length = CM.TargetingMacroPrelineMaxLen (255 − worst /click − newline);
--      EditBox SetMaxLetters + validate refuse oversized input. Each field shows a live
--      "used / max characters" counter under its label (like the Macro Composer).
--    • Reset clears both overrides. Combat-guarded open; uses CM.UI CreateWindow.
--  Does not: Rebuild secure macrotext until reload / RefreshClickCastMacros path runs.
--  Related: Core/ClickCasting/TargetingMacroBuilder.lua,
--  UI/Options/Tabs/TabReticleTargeting.lua, Constants/DatabaseDefaults.lua,
--  UI/Options/OptionsPanel.lua
---------------------------------------------------------------------------------------
local _, CM = ...
local L = CM.L
local _G = _G

-- WoW API
local InCombatLockdown = _G.InCombatLockdown

-- Lua stdlib
local format = _G.string.format
local strtrim = _G.strtrim
local type = _G.type

local UI = CM.UI
local M = CM.METADATA

local RELOAD_CONFIRM = L["A UI Reload is required when making this change. Proceed?"]

local window

local function PrelineMaxLen()
  return CM.TargetingMacroPrelineMaxLen or 140
end

local function NormalizeInput(value)
  value = type(value) == "string" and strtrim(value) or ""
  if value == "" then
    return nil
  end
  return value
end

local function ValidatePreline(value)
  value = type(value) == "string" and value or ""
  local maxLen = PrelineMaxLen()
  if #value > maxLen then
    return format(
      L["Preline must be %d characters or fewer (room for /click under the 255 macro limit)."],
      maxLen
    )
  end
  return true
end

local function AutoTargetLock()
  return CM.DB and CM.DB.char and CM.DB.char.autoTargetLockOnAttack == true
end

-- forAutoLock describes which Auto Target Lock mode this field belongs to.
local function FieldDisabled(forAutoLock)
  return function()
    return forAutoLock ~= AutoTargetLock()
  end
end

local function FieldWatermark(forAutoLock)
  return function()
    if forAutoLock then
      if not AutoTargetLock() then
        return L["Inactive — Auto Target Lock is OFF"]
      end
    elseif AutoTargetLock() then
      return L["Inactive — Auto Target Lock is ON"]
    end
    return L["Inactive"]
  end
end

local function Build()
  local defaults = CM.TargetingMacroPrelinesDefaults or {}
  local maxLen = PrelineMaxLen()
  local ctx
  window, ctx = UI.CreateWindow(
    "CombatModeTargetingMacroPrelinesEditor",
    M["TITLE"] .. " - " .. L["Targeting Macro Prelines Editor"],
    700,
    UI.GetSecondaryEditorHeight(),
    { noScroll = true }
  )

  local maxLenMarkup = UI.AccentWrap(tostring(maxLen))
  ctx:Description({
    justify = "LEFT",
    color = UI.Colors.textDim,
    allowColors = true,
    text = format(
      L["Customize the targeting prelines injected before each ability when Reticle Targeting is enabled.\n\n• Only the preline matching your current %s setting is active.\n• Max %s characters per preline — SecureActionButton macros are capped at %s; the rest is reserved for the trailing %s line.\n• Use %s to reload and pick up edits."],
      UI.AccentWrap(L["Auto Target Lock"]),
      maxLenMarkup,
      UI.AccentWrap("255"),
      UI.SlashWrap("/click"),
      UI.AccentWrap(L["Apply Changes"])
    ),
  })

  local function StateLines(autoLockOn)
    return format(L["Auto Target Lock: %s"], UI.OnOffWrap(autoLockOn))
  end

  local function AddPrelineField(opts)
    -- Live length of the text in the box, shown under the label like the Macro Composer's counter.
    local used = #(opts.get() or "")
    ctx:TextInput({
      label = opts.label,
      labelAllowColors = true,
      labelSize = UI.Fonts.small,
      -- Auto Target Lock state, shown as the small muted helper under the label.
      desc = function()
        local text = format(L["%d / %d characters"], used, maxLen)
        if used > maxLen then
          text = format(L["%s (over the macro limit)"], UI.AccentWrap(text))
        end
        return opts.state .. "\n" .. text
      end,
      descAllowColors = true,
      multiline = 4,
      maxLetters = maxLen,
      get = opts.get,
      set = opts.set,
      onTextChanged = function(value)
        used = #value
        UI.Options.Sync()
      end,
      validate = ValidatePreline,
      disabled = opts.disabled,
      watermarkWhenDisabled = opts.watermarkWhenDisabled,
    })
  end

  AddPrelineField({
    label = L["Preline: No Auto Lock"],
    state = StateLines(false),
    get = function()
      return CM.DB.global.targetingMacroPrelineEnemyOverride or defaults.enemy or ""
    end,
    set = function(value)
      CM.DB.global.targetingMacroPrelineEnemyOverride = NormalizeInput(value)
    end,
    disabled = FieldDisabled(false),
    watermarkWhenDisabled = FieldWatermark(false),
  })
  AddPrelineField({
    label = L["Preline: Auto Lock"],
    state = StateLines(true),
    get = function()
      return CM.DB.global.targetingMacroPrelineAutoLockEnemyOverride or defaults.autoLockEnemy or ""
    end,
    set = function(value)
      CM.DB.global.targetingMacroPrelineAutoLockEnemyOverride = NormalizeInput(value)
    end,
    disabled = FieldDisabled(true),
    watermarkWhenDisabled = FieldWatermark(true),
  })
  ctx:Gap()
  ctx:ButtonRow({
    {
      label = L["Reset to Defaults"],
      confirm = true,
      confirmText = RELOAD_CONFIRM,
      reload = true,
      func = function()
        CM.DB.global.targetingMacroPrelineEnemyOverride = nil
        CM.DB.global.targetingMacroPrelineAutoLockEnemyOverride = nil
        CM.ReloadUI()
      end,
    },
    {
      label = L["Apply Changes"],
      confirm = true,
      confirmText = RELOAD_CONFIRM,
      reload = true,
      func = function()
        CM.ReloadUI()
      end,
    },
  })

  ctx:Finish()
  -- Measure content once, publish as the shared secondary-editor height, then apply it
  -- (published via UI.SetSecondaryEditorHeight).
  UI.SizeWindowToContent(window)
  UI.SetSecondaryEditorHeight(window:GetHeight())
  window:SetHeight(UI.GetSecondaryEditorHeight())
end

function CM.OpenTargetingMacroPrelinesEditor()
  if InCombatLockdown and InCombatLockdown() then
    print(
      CM.Constants.BasePrintMsg
        .. "|cff909090: "
        .. L["Cannot open this editor while in combat."]
        .. "|r"
    )
    return
  end

  if not window then
    Build()
  end

  -- Anchor to the right of the main options window when it is open.
  local anchor = CM.GetOptionsFrame and CM.GetOptionsFrame()
  window:ClearAllPoints()
  if anchor and anchor:IsShown() then
    window:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 12, 0)
  else
    window:SetPoint("CENTER")
  end

  window:Show()
  window:Raise()
  window:SetHeight(UI.GetSecondaryEditorHeight())
  UI.Options.Sync()
end
