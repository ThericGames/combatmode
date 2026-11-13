---------------------------------------------------------------------------------------
--  Core/Crosshair/FocusFrameVisibility.lua — CROSSHAIR — optional focus frame hiding
---------------------------------------------------------------------------------------
--  What it does: Hides Blizzard's focus frame without clearing the focus unit.
--  Architecture / how it works:
--    • char.hideFocusFrame, default false; applied by bootstrap and the options toggle.
--    • Reparents to a hidden holder out of combat, preserving native unit visibility logic.
--    • PLAYER_REGEN_ENABLED retries the current preference after combat.
--    • Disabling restores the original parent only if we still own the frame's parent.
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

function CM.ApplyFocusFrameVisibility()
  if InCombatLockdown() or not (CM.DB and CM.DB.char) then
    return
  end
  local hide = CM.DbBool(CM.DB.char.hideFocusFrame, false)
  if not hide then
    if hiddenFrame and hiddenFrame:GetParent() == holder then
      hiddenFrame:SetParent(originalParent)
    end
    hiddenFrame, originalParent = nil, nil
    return
  end
  local frame = _G.FocusFrame
  if not frame or hiddenFrame then
    return
  end
  if not holder then
    holder = CreateFrame("Frame")
    holder:Hide()
  end
  originalParent = frame:GetParent()
  frame:SetParent(holder)
  hiddenFrame = frame
end
