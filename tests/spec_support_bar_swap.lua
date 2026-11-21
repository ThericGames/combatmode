return function(check, loadedCM)
  local frames = {}
  local currentPage, inCombat = 2, false
  local function CreateFrame(_, name)
    local attributes = {}
    local references = {}
    local frame = {
      RegisterForClicks = function() end,
      SetAttribute = function(_, key, value)
        attributes[key] = value
      end,
      GetAttribute = function(_, key)
        return attributes[key]
      end,
      GetEffectiveAttribute = function(_, key)
        return attributes[key] or (key == "actionpage" and currentPage or nil)
      end,
      GetFrameRef = function(_, key)
        return references[key]
      end,
      SetFrameRef = function(_, key, value)
        references[key] = value
      end,
      GetName = function()
        return name
      end,
      CallMethod = function(self, method)
        self[method]()
      end,
    }
    if name then
      frames[name] = frame
    end
    return frame
  end
  local env = setmetatable({
    NUM_ACTIONBAR_PAGES = 6,
    C_ActionBar = {
      GetActionBarPage = function()
        return currentPage
      end,
      SetActionBarPage = function(value)
        currentPage = value
      end,
    },
    CreateFrame = CreateFrame,
    ClearOverrideBindings = function() end,
    SetOverrideBindingClick = function() end,
    GetBindingKey = function(command)
      if command == "Combat Mode - Support Mode" then
        return "F6"
      end
    end,
    InCombatLockdown = function()
      return inCombat
    end,
    SecureHandlerExecute = function(frame, snippet)
      assert(loadstring("return function(self) " .. snippet .. " end"))()(frame)
    end,
    SecureHandlerSetFrameRef = function(frame, key, value)
      frame:SetFrameRef(key, value)
    end,
    SecureHandlerWrapScript = function(frame, _, owner, snippet)
      local run = assert(loadstring("return function(self, owner, down) " .. snippet .. " end"))()
      frame.press = function()
        run(frame, owner, true)
        local text = frame:GetAttribute("macrotext") or ""
        local page = text:match("/changeactionbar (%d+)")
        if page then
          currentPage = tonumber(page)
        end
      end
    end,
  }, { __index = _G })
  env._G = env
  for index, bar in ipairs(loadedCM.Constants.ClickCastBars) do
    for buttonIndex = 1, bar.count do
      local name = bar.frame .. buttonIndex
      local button = CreateFrame("Button", name)
      if index > 1 then
        button:SetAttribute("actionpage", (bar.actionBase - 1) / 12 + 1)
      end
      env[name] = button
    end
  end
  env.MainActionBar = {
    GetAttribute = function(_, key)
      return key == "actionpage" and currentPage or nil
    end,
  }
  local char = { reticleTargeting = true, supportModePage = 4 }
  local CM = { Constants = loadedCM.Constants, DbBool = loadedCM.DbBool, DB = { char = char } }
  local source = debug.getinfo(loadedCM.GetSupportModePage, "S").source:sub(2)
  setfenv(assert(loadfile(source)), env)("CombatMode", CM)

  check("existing selected page still swaps", CM.GetSupportModePage(), 4)
  char.supportModeSwapBars = 0
  check("swap off retains the chosen page", CM.GetSupportModeBarChoice(), 4)
  check("numeric false selects one-way paging", CM.GetSupportModePage(), 4)
  CM.ApplySupportModeBinding()
  local key = frames.CombatModeSupportModeKey
  local main, barTwo, barThree =
    env.ActionButton1, env.MultiBarBottomLeftButton1, env.MultiBarBottomRightButton1
  key.press()
  check("one-way paging changes the game page", currentPage, 4)
  check("one-way paging leaves the other bars alone", barTwo:GetEffectiveAttribute("actionpage"), 6)
  key.press()
  check("one-way paging restores Page 1", currentPage, 1)
  char.supportModeSwapPage = nil
  char.supportModePage, char.supportModeSwapBars = 0, nil
  check("legacy Don't Swap remains off", CM.IsSupportModeBarSwapEnabled(), false)
  check("legacy Don't Swap has no selected bar", CM.GetSupportModeBarChoice(), nil)
  char.supportModePage = 2
  check("hidden Page 2 has no physical bar to exchange", CM.GetSupportModeBarChoice(), nil)
  check("Action Bar 2 uses Blizzard's Page 6 slots", CM.GetSupportModeBarChoices()[1].page, 6)
  check(
    "Action Bar 8 can be selected on supported clients",
    CM.GetSupportModeBarChoices()[7].page,
    15
  )

  char.supportModePage, char.supportModeSwapPage = 2, 6
  char.supportModeSwapBars = true
  CM.ApplySupportModeBinding()
  currentPage = 2
  inCombat = true
  key.press()
  check(
    "entering Support Mode displays the partner on the main bar",
    main:GetEffectiveAttribute("actionpage"),
    6
  )
  check("the partner shows the previous main page", barTwo:GetEffectiveAttribute("actionpage"), 2)
  check("the game page is preserved during the exchange", currentPage, 2)
  check("Support Mode marks the new secure swap for reloads", char.supportModeAppliedPage, 0)
  check(
    "click-cast macros see the original main page",
    CM.GetSupportModeBuildContext().normalPage,
    2
  )
  key.press()
  check("exiting in combat restores the main attribute", main:GetAttribute("actionpage"), nil)
  check("exiting in combat restores the partner", barTwo:GetEffectiveAttribute("actionpage"), 6)
  inCombat = false
  key.press()
  char.supportModeSwapPage = 5
  CM.ApplySupportModeBinding()
  check(
    "changing the choice while active displays the new bar",
    main:GetEffectiveAttribute("actionpage"),
    5
  )
  check(
    "changing the choice restores the old partner",
    barTwo:GetEffectiveAttribute("actionpage"),
    6
  )
  check(
    "the new partner displays the original main page",
    barThree:GetEffectiveAttribute("actionpage"),
    2
  )
  check("active reticle routing uses the new page", CM.GetSupportModeBuildContext().page, 5)
  inCombat = true
  char.supportModeSwapBars = false
  CM.ApplySupportModeBinding()
  check("page updates defer in combat", main:GetEffectiveAttribute("actionpage"), 5)
  inCombat = false
  CM.FlushSupportMode()
  check("turning off the swap restores the main page", main:GetEffectiveAttribute("actionpage"), 2)
  check(
    "turning off the swap restores the other bar",
    barThree:GetEffectiveAttribute("actionpage"),
    5
  )
  check(
    "Support Mode stays active when switching to one-way paging",
    CM.IsSupportModeActive(),
    true
  )
  check("the legacy page is still saved", char.supportModePage, 2)
  check("the separate physical bar choice is still saved", CM.GetSupportModeBarChoice(), 5)
  char.supportModeSwapBars = true
  CM.ApplySupportModeBinding()
  check(
    "switching from paging to a swap restores the original Page 1 first",
    barThree:GetEffectiveAttribute("actionpage"),
    1
  )
  check(
    "switching back to two-way recalls the separate bar choice",
    main:GetEffectiveAttribute("actionpage"),
    5
  )
  char.supportModeSwapBars = false
  char.supportModePage = 0
  CM.ApplySupportModeBinding()
  currentPage = 3
  key.press()
  check("leaving with Don't Swap keeps the current bar", currentPage, 3)
  char.supportModeActive, char.supportModeAppliedPage = true, 5
  currentPage = 5
  CM.InitializeSupportMode()
  check("reload restores the previously applied page when swapping is now off", currentPage, 1)
end
