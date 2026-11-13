---------------------------------------------------------------------------------------
--  UI/Wizard/SetupWizard.lua — WIZARD — first-run setup wizard (guided tour of the options)
---------------------------------------------------------------------------------------
--  What it does: Walks a new player through the essentials inside the real options window.
--  Each step opens a tab, scrolls to a setting, dims everything but it and shows a balloon that
--  explains what it does; the player changes the setting right there (keybinds, toggles, the
--  spell lists) and presses Next. Started by the welcome popup on first install and by the cog
--  next to the version number in the options header (after a confirmation).
--  Architecture / how it works:
--    • Tasks: a step can ask for actions (a key bound, ...). They show as a check list in the balloon
--      and Next / Finish stay disabled until every one is done; Skip tour always works.
--    • Steps are data (STEPS): tab id, then either one control label (plus optional `also`
--      labels) or a whole section by header title (`sectionEnd` = a later section's title where
--      the highlight ends, so one step can cover several sections), with a title and text. Options.FocusControl /
--      Options.FocusSection select the tab, scroll to it and return the frame(s) to highlight;
--      UI.ShowSpotlight (Spotlight.lua) dims around them (cut to the tab's visible area) and
--      shows the balloon.
--    • The dim never blocks the mouse, so every option keeps working while a step is shown.
--    • Steps marked `preview` (Crosshair, Assist HUD, Ally HUD) also leave that one live element
--      (crosshair, Assist HUD or Ally HUD) undimmed with its own outline, and the balloon keeps clear.
--    • Steps with `slides = { key, count[, hold[, fade]] }` show those screenshots (Assets/wizard/<key>_<n>.blp,
--      built by scripts/art/make-wizard-previews.py) flipping in order inside the balloon.
--    • Wizard.FindStep / Wizard.ShowInfo: Options adds an "i" button to every header / option that has
--      a step; it opens that step alone as an info popup (UI.ShowSpotlight `info`), never during the tour.
--      A step's optional `details` text is appended to its body in that popup only (the tour stays short),
--      and `infoDropLast` leaves out its last paragraph there (the "Set your key" instruction).
--    • global.seenWizard is set when the tour finishes or is skipped (Skip / ESC).
--    • Combat: Start waits for combat to end; entering combat mid-tour ends the tour.
--  Does not: Cover every option (only the basics and the major features), or own any setting
--      (the tabs do).
--  Related: UI/Wizard/Spotlight.lua, UI/Options/OptionsPanel.lua (cog, FocusControl),
--  Core/Runtime/Runtime.lua (first-run hook)
---------------------------------------------------------------------------------------
local _, CM = ...
local L = CM.L
local _G = _G

-- WoW API
local C_Timer = _G.C_Timer
local CreateFrame = _G.CreateFrame
local GetBindingKey = _G.GetBindingKey
local InCombatLockdown = _G.InCombatLockdown

-- Lua stdlib
local abs = _G.math.abs
local ipairs = _G.ipairs

local UI = CM.UI
local Options = UI.Options

local Wizard = {}
CM.Wizard = Wizard

local SETTLE_DELAY = 0.15 -- lets a tab switch start its scroll before it is checked
local SCROLL_POLL = 0.05
local SCROLL_MAX_WAIT = 1.5 -- give up waiting for the scroll to land after this long

local function Bound(command)
  return GetBindingKey(command) ~= nil
end

-- A step's `body` can use `{text}` for accent-coloured words, `{!text}` for red warning text and a blank line (`\n\n`) between paragraphs.
-- A step may also carry `warning`: a caution shown in red under the text, and `slides`: { asset key,
-- screenshot count, optional seconds per slide, optional cross-fade seconds } shown as a looping slideshow between the title and the text.
-- A step highlights a whole section (`section` = its header title). `tasks` are the actions the
-- step asks for: each shows as a check mark that fills in once `done()` is true, and Next stays
-- disabled until all are. The order follows the sidebar tabs after the Mouse Look section.
local STEPS = {
  {
    tab = "general",
    section = L["MOUSE LOOK"],
    title = L["Mouse Look"],
    slides = { "mouselook", 5, 0.3, 0.1 },
    body = L["Lock your cursor to the center of the screen and steer by moving the mouse, no more holding right-click.\n\nSet a {key to toggle it}, and {one to interact with} whatever you're aiming at."],
    details = L["How the keys behave:\n• {Tap} the Mouse Look key to turn it on or off\n• {Hold} it to free your cursor for as long as you hold\n• {Tap} the Interact key to interact with what you aim at\n• {Hold} it on a player to open their menu"],
    infoDropLast = true,
    tasks = {
      {
        label = L["Set a Mouse Look key"],
        done = function()
          return Bound("Combat Mode - Mouse Look")
        end,
      },
      {
        label = L["Set an Interact key"],
        done = function()
          return Bound("INTERACTMOUSEOVER") or Bound("INTERACTTARGET")
        end,
      },
    },
  },
  {
    tab = "crosshair",
    section = L["CROSSHAIR"],
    preview = "crosshair",
    title = L["Crosshair"],
    slides = { "crosshair", 4 },
    body = L["A reactive, fully customizable crosshair that adapts to your target and combat state."],
    details = L["It only shows while Mouse Look is on, and its color follows what you aim at ({Reaction Colors}). {Cast Feedback} makes it react as you cast.\n\nWhile Target Lock is active it becomes a steady dot, and Support Mode uses its own texture."],
  },
  {
    tab = "crosshair",
    section = L["ASSIST HUD"],
    preview = "assist",
    title = L["Assist HUD"],
    slides = { "assisthud", 3 },
    body = L["Aim at an enemy and the HUD next to your crosshair suggests your {next spell} and shows its key.\n\nAim at something you can interact with and it shows its {name} and your {Interact key} instead."],
    details = L["Aim at a player for a second and the {Player Interaction Prompt} appears; hold Interact to open their menu.\n\nWhile the {Interactable Indicator} is on, Blizzard's own interact icons are hidden, so you don't see them twice."],
  },
  {
    tab = "reticle",
    section = L["RETICLE TARGETING"],
    title = L["Reticle Targeting"],
    slides = { "reticle", 5 },
    body = L["Target enemies just by aiming at them, and drop ground-targeted spells and AoE abilities right where your crosshair points, with no tab-targeting."],
    details = L["Reticle Targeting only picks {enemies}. Helpful spells keep your friendly target, so use {Ally Cycle}, {Support Mode} or the {Party Wheel} to reach allies.\n\nAlso worth knowing:\n• Spells on macro buttons need the {Reticle Targeting Macros} below\n• Spells in {Excluded Spells} skip the targeting logic\n• {Auto Target Lock} locks the enemy you attack so the reticle stops swapping"],
    warning = L["Turning Reticle Targeting on or off reloads the UI."],
  },
  {
    tab = "reticle",
    label = L["Cast at Crosshair"],
    title = L["Cast at Crosshair"],
    slides = { "castatcrosshair", 3 },
    body = L["Ground-targeted spells that should be cast at the crosshair location.\n\nType a {spell name or ID} to add it."],
    infoDropLast = true,
    details = L["Normally a ground-targeted spell cast through Reticle Targeting will temporarily disable Mouse Look so you can place it manually. Spells listed here are automatically cast on the ground at your crosshair location instead.\n\nSpells like {Blizzard}, {Heroic Leap} or {Death and Decay} are typical examples. If a ground spell still stops Mouse Look so you can place it, add it here."],
  },
  {
    tab = "reticle",
    label = L["Reticle Targeting Macros"],
    title = L["Reticle Targeting Macros"],
    body = L["{!Action buttons that are macros cannot inherit Reticle Targeting on their own.}\n\nPress {+} to open the {Macro Composer}, write your macro there and it gets the targeting logic added for you.\n\nThen drag it from this list onto your action bars; {right-click} an icon to edit it."],
    details = L["Composed macros update automatically whenever you change your targeting options.\n\nKeep in mind that macros are limited to 255 characters."],
  },
  {
    tab = "reticle",
    section = L["TARGET LOCK"],
    title = L["Target Lock"],
    slides = { "targetlock", 4 },
    body = L["Lock onto a target with one tap so the reticle stops swapping. While locked, the cycle keys jump to nearby enemies, or to nearby allies in Support Mode.\n\n{Target Lock Behavior} decides whether tapping again unlocks ({Toggle}) or moves the lock to whatever is under the crosshair ({Switch Target}).\n\nSet your keys."],
    details = L["Target Lock uses the game's Focus Target, so other addons or macros that set a focus will interfere with it.\n• The reticle becomes a steady dot and a marker follows the locked nameplate\n• Reticle Targeting casts keep going to the locked unit\n• {Auto Target Lock} locks the enemy you attack on its own (the ally you heal, in Support Mode)"],
    infoDropLast = true,
    -- These keys can't be set while Reticle Targeting is off, so they don't block then.
    tasks = {
      {
        label = L["Set a Target Lock key"],
        done = function()
          return not CM.DB.char.reticleTargeting or Bound("Combat Mode - Toggle Focus Target")
        end,
      },
      {
        label = L["Set a Cycle Lock - Next key"],
        done = function()
          return not CM.DB.char.reticleTargeting or Bound("Combat Mode - Cycle Focus Next")
        end,
      },
      {
        label = L["Set a Cycle Lock - Previous key"],
        done = function()
          return not CM.DB.char.reticleTargeting or Bound("Combat Mode - Cycle Focus Previous")
        end,
      },
    },
  },
  {
    tab = "clickcasting",
    section = L["CLICK CASTING"],
    title = L["Click Casting"],
    slides = { "clickcasting", 3 },
    body = L["Turn your mouse clicks into actions while in Mouse Look, such as casting your action bar spells with {Left and Right Click}.\n\nPick what each click does, with or without a {modifier key}."],
    details = L["Binds only work while Mouse Look is on. With Reticle Targeting on, a bound spell targets the enemy under your crosshair first, and helpful spells keep your friendly target.\n\n{Account-Wide Binds} shares one set of binds between all your characters."],
  },
  {
    tab = "radialmenu",
    section = L["RADIAL MENU"],
    title = L["Radial Menu"],
    slides = { "radial", 4 },
    body = L["A wheel of your {spells, items, macros and shortcuts} that works in combat.\n\nHold its key, move the mouse toward a slice and release to use it.\n\n{Scroll} to switch between wheels."],
    details = L["Each wheel holds up to {8 slices}, and you can keep up to {5 wheels}. In the editor below:\n• {Click} a slice to pick a shortcut or emote\n• {Drop} a spell, item, mount or macro onto it\n• {Right-click} it to remove it\n• Drag it to move it\n\n{Esc} or {right-click} while the wheel is open cancels without using anything."],
    tasks = {
      {
        label = L["Set a Radial Menu key"],
        done = function()
          return Bound("Combat Mode - Radial Menu")
        end,
      },
    },
  },
  {
    tab = "radialmenu",
    label = L["Party Wheel Spells"],
    title = L["Party Wheel"],
    slides = { "partywheel", 5 },
    body = L["Hold the key of a {helpful spell} listed here to open a wheel of your group members. Move toward one and release to cast on them, or come back to the {center} to cast on yourself.\n\n{Tap} the key to cast on your friendly target, or yourself if you have none.\n\nType a {spell name or ID} to add it."],
    details = L["The wheel shows 8 members per page with portrait, health and role; {scroll} to change page. Dead, offline and out-of-range members are dimmed, and offline ones can't be picked.\n\nSpells that aren't in this list cast as usual. {Esc} or {right-click} closes the wheel without casting."],
    infoDropLast = true,
    warning = L["Needs Reticle Targeting."],
  },
  {
    tab = "allycycle",
    section = L["ALLY CYCLE"],
    sectionEnd = L["ALLY HUD"],
    preview = "ally",
    title = L["Ally Cycle"],
    slides = { "allycycle", 3 },
    body = L["Cycle through group members in Mouse Look so {helpful spells} go to the ally while {harmful ones} keep hitting your enemy.\n\nThe {Ally HUD} shows who is selected.\n\nSet your cycle keys."],
    details = L["The cycle skips offline members and those in another zone.\n• {Skip Self} leaves you out of the cycle\n• {Also Cycle Through} adds pets\n• {Keep Ally After Harm} keeps the ally after you cast a harmful spell\n• {Ally HUD} also shows health and role\n\nIn Support Mode, the ally you picked has priority over the one under your crosshair unless {Prioritize Crosshair Target} is on."],
    infoDropLast = true,
    tasks = {
      {
        label = L["Set an Ally Cycle - Next key"],
        done = function()
          return Bound(CM.AllyCycleBindUp or "Combat Mode - Ally Cycle Next")
        end,
      },
      {
        label = L["Set an Ally Cycle - Previous key"],
        done = function()
          return Bound(CM.AllyCycleBindDown or "Combat Mode - Ally Cycle Previous")
        end,
      },
    },
  },
  {
    tab = "supportmode",
    section = L["SUPPORT MODE"],
    title = L["Support Mode"],
    slides = { "supportmode", 3 },
    body = L["A support-focused mode that, when active, switches your main action bar to a dedicated {support page} and allows {helpful spells} to target the friendly unit under your crosshair.\n\nSet your key."],
    infoDropLast = true,
    details = L["While the mode is on, a helpful spell on a click-cast button goes to the first of these that exists:\n• Your {Target Lock} ally\n• Your friendly target (such as an {Ally Cycle} pick)\n• The ally under your crosshair\n• The ally in front of you\n\n{Prioritize Crosshair Target} puts the crosshair ally ahead of your friendly target. With no ally, the game's {Self Cast} setting decides whether it lands on you.\n\nHarmful spells keep targeting enemies, and {Nameplate Behavior} picks which nameplates show. It all works in combat."],
    warning = L["Needs Reticle Targeting."],
    -- The key can't be set while Reticle Targeting is off, so it doesn't block then.
    tasks = {
      {
        label = L["Set a Support Mode key"],
        done = function()
          return not CM.DB.char.reticleTargeting or Bound("Combat Mode - Support Mode")
        end,
      },
    },
  },
  {
    tab = "autocursorunlock",
    section = L["AUTO UNLOCK"],
    title = L["Auto Unlock"],
    slides = { "autounlock", 5, 0.5 },
    body = L["Mouse Look pauses when you open {bags, the map or other windows}, then resumes.\n\nAdd {mounts or extra windows} that should pause it too."],
    infoDropLast = true,
    details = L["Two lists let you add your own:\n• {Unlock Mounts}: mounts that act as vendors, so your cursor is free while you use them\n• {Extra Frames}: any other window; type its name to search, or use the inspect button to find it\n\nFor fully custom rules, the Advanced tab accepts a Lua condition."],
  },
}

-- Frames of the live crosshair + HUD preview the Crosshair / Ally Cycle tabs force on screen. Steps
-- marked `preview` leave them undimmed (outlined) and keep the balloon off them.
-- Per `preview` kind: the frames to leave undimmed and how far to pad around them (the Assist HUD's key /
-- name text hangs outside its frame, so those labels are listed too instead of padding the frame wide,
-- which would swallow the crosshair).
local PREVIEW_KINDS = {
  crosshair = {
    frames = function()
      return { _G.CombatModeCrosshairFrame }
    end,
    padX = 14,
    padY = 14,
  },
  assist = {
    frames = function()
      local frame = CM.GetAssistedHighlightFrame and CM.GetAssistedHighlightFrame()
      if not frame then
        return {}
      end
      return { frame, frame.keybindText, frame.nameText }
    end,
    padX = 14,
    padY = 14,
  },
  ally = {
    frames = function()
      return { _G.CombatModeAllyCycleHUD }
    end,
    padX = 16,
    padY = 14,
  },
}

local function PreviewFrames(kind)
  local def = PREVIEW_KINDS[kind]
  return def and def.frames() or {}, def and def.padX, def and def.padY
end

--- Texture paths of a step's `slides = { key, count }` (Assets/wizard/<key>_1..count), or nil.
local function SlidePaths(slides)
  if not slides then
    return nil
  end
  local paths = {}
  for n = 1, slides[2] do
    paths[n] = CM.Constants.WizardSlidePath .. slides[1] .. "_" .. n .. ".blp"
  end
  return paths
end

local active = false
local current = 0
local combatWatcher

local function StopWatchingCombat()
  if combatWatcher then
    combatWatcher:UnregisterAllEvents()
  end
end

--- Waits for `event` once, then calls `handler`.
local function WatchCombat(event, handler)
  combatWatcher = combatWatcher or CreateFrame("Frame")
  combatWatcher:UnregisterAllEvents()
  combatWatcher:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    handler()
  end)
  combatWatcher:RegisterEvent(event)
end

--- Ends the wizard from any step and marks it as seen (finished and skipped are the same).
function Wizard.Finish()
  active = false
  StopWatchingCombat()
  UI.HideSpotlight()
  Options.CancelKeybindCapture()
  CM.DB.global.seenWizard = true
  Options.Sync()
  -- Upgrades see the changelog after the tour (no-op when this version was already seen).
  C_Timer.After(0.5, function()
    if CM.Config and CM.Config.MaybeShowChangelogOnNewVersion then
      CM.Config.MaybeShowChangelogOnNewVersion()
    end
  end)
end

local ShowStep

function ShowStep(i)
  local step = STEPS[i]
  if not step then
    Wizard.Finish()
    return
  end
  current = i
  -- Fade the old highlight away while the tab scrolls, so it never chases a moving widget.
  UI.FadeOutSpotlight()
  local targets
  if step.section then
    targets = Options.FocusSection(step.tab, step.section)
    -- `sectionEnd`: the highlight runs on to the end of that later section of the same tab.
    if targets and step.sectionEnd then
      for _, section in ipairs(Options.sections) do
        if section.tab == step.tab and section.label == step.sectionEnd then
          targets[2] = section.lastFrame
          break
        end
      end
    end
  else
    local frame = Options.FocusControl(step.tab, step.label, step.group)
    targets = { frame }
    for _, label in ipairs(step.also or {}) do
      local control = Options.FindControl(step.tab, label, step.group)
      if control then
        targets[#targets + 1] = control.frame
      end
    end
  end
  -- Unknown section: fall back to the tab's sidebar button.
  targets = targets or { Options.GetTabButton(step.tab) }
  local last = i == #STEPS
  local scroll = Options.GetTabScroll(step.tab)
  local waited = SETTLE_DELAY
  local function show()
    if not active or current ~= i then
      return
    end
    local options = CM.GetOptionsFrame()
    if not (options and options:IsShown() and targets[1]) then
      Wizard.Finish()
      return
    end
    UI.ShowSpotlight(targets, {
      title = step.title,
      body = step.body,
      warning = step.warning,
      slides = SlidePaths(step.slides),
      slideHold = step.slides and step.slides[3],
      slideFade = step.slides and step.slides[4],
      step = i .. " / " .. #STEPS,
      nextLabel = last and L["Finish"] or L["Next"],
      isLast = last,
      canGoBack = i > 1,
      tasks = step.tasks,
      clip = Options.GetTabScroll(step.tab),
      alsoHighlight = step.preview and function()
        return PreviewFrames(step.preview)
      end or nil,
      onNext = function()
        Options.CancelKeybindCapture()
        ShowStep(i + 1)
      end,
      onBack = function()
        Options.CancelKeybindCapture()
        ShowStep(i - 1)
      end,
      onSkip = Wizard.Finish,
    })
  end
  -- Show the new step once the scroll has landed (or after a timeout).
  local function WaitForScroll()
    if not active or current ~= i then
      return
    end
    local moving = scroll
      and scroll.cmGetTargetScroll
      and abs((scroll:GetVerticalScroll() or 0) - scroll.cmGetTargetScroll()) > 1
    if moving and waited < SCROLL_MAX_WAIT then
      waited = waited + SCROLL_POLL
      C_Timer.After(SCROLL_POLL, WaitForScroll)
    else
      -- One more beat so the final scroll position is laid out before measuring.
      C_Timer.After(SCROLL_POLL, show)
    end
  end
  C_Timer.After(SETTLE_DELAY, WaitForScroll)
end

--- The step that explains the section headed `section` (a ctx:Header title) or the option labelled
--- `label` on tab `tab`, or nil. Options puts an "i" button on those headers / rows.
function Wizard.FindStep(tab, section, label)
  for _, step in ipairs(STEPS) do
    if step.tab == tab then
      if section and step.section == section then
        return step
      end
      if label and not step.section and step.label == label then
        return step
      end
    end
  end
end

--- A step's body for the info popup: without its last paragraph when `infoDropLast` (the
--- "Set your key" style instruction, which only makes sense in the tour), plus `details`.
local function InfoBody(step)
  local body = step.body
  if step.infoDropLast then
    body = body:match("^(.*)\n\n") or body
  end
  if step.details then
    body = body .. "\n\n" .. step.details
  end
  return body
end

--- Shows a step's explanation alone (slides, text, warning) in a centred popup with a Close
--- button: no dim, step count or Back / Next. Ignored while the tour runs.
function Wizard.ShowInfo(step)
  if active or not step then
    return
  end
  UI.ShowSpotlight({}, {
    info = true,
    title = step.title,
    body = InfoBody(step),
    warning = step.warning,
    slides = SlidePaths(step.slides),
    slideHold = step.slides and step.slides[3],
    slideFade = step.slides and step.slides[4],
    onSkip = UI.HideSpotlight,
  })
end

--- Starts (or restarts) the tour from the first step. Waits for combat to end.
function Wizard.Start()
  if InCombatLockdown() then
    WatchCombat("PLAYER_REGEN_ENABLED", Wizard.Start)
    return
  end
  if not CM.OpenOptions then
    return
  end
  UI.HideSpotlight()
  active = true
  CM.OpenOptions()
  WatchCombat("PLAYER_REGEN_DISABLED", Wizard.Finish)
  -- Let the options window lay out before measuring the first target.
  C_Timer.After(0.25, function()
    if active then
      ShowStep(1)
    end
  end)
end
