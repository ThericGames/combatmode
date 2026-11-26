---------------------------------------------------------------------------------------
--  Core/Crosshair/FocusFrameVisibility.lua — CROSSHAIR — optional focus frame hiding
---------------------------------------------------------------------------------------
--  What it does: Hides Blizzard's focus frame without clearing the focus unit.
--  Architecture / how it works:
--    • global.hideFocusFrame, default false; applied by bootstrap and the options toggle.
--    • Reparents to a hidden holder out of combat, preserving native unit visibility logic.
--    • PLAYER_REGEN_ENABLED retries the current preference after combat.
--    • Disabling or entering Edit Mode restores the original parent if still owned.
--  Does not: Clear focus, change bindings, hide third-party frames or replace unit watches.
--  Related: Core/Runtime/Bootstrap.lua, Core/Runtime/EventRouter.lua,
--  UI/Options/Tabs/TabReticleTargeting.lua, Constants/DatabaseDefaults.lua
---------------------------------------------------------------------------------------
local _, CM = ...
local _G = _G

local CreateFrame = _G.CreateFrame
local InCombatLockdown = _G.InCombatLockdown

local holder
local hiddenFrame
local originalParent
local knownFrame

function CM.ApplyFocusFrameVisibility()
  if InCombatLockdown() or not (CM.DB and CM.DB.global) then
    return
  end
  local hide = CM.DbBool(CM.DB.global.hideFocusFrame, false)
  local editMode = _G.EditModeManagerFrame
  local editing = editMode and editMode.IsEditModeActive and editMode:IsEditModeActive()
  if not hide or editing then
    if hiddenFrame and hiddenFrame:GetParent() == holder then
      hiddenFrame:SetParent(originalParent)
    end
    hiddenFrame = nil
    return
  end
  local frame = _G.FocusFrame
  if not frame or hiddenFrame then
    return
  end
  if frame == knownFrame and frame:GetParent() ~= originalParent then
    return
  end
  if not holder then
    holder = CreateFrame("Frame")
    holder:Hide()
  end
  knownFrame = frame
  originalParent = frame:GetParent()
  frame:SetParent(holder)
  hiddenFrame = frame
end

local events = _G.EventRegistry
if events and events.RegisterCallback then
  events:RegisterCallback("EditMode.Enter", CM.ApplyFocusFrameVisibility, CM)
  events:RegisterCallback("EditMode.Exit", CM.ApplyFocusFrameVisibility, CM)
end
