---------------------------------------------------------------------------------------
--  Core/FreeLook/CameraOrbit.lua — FREELOOK — hold to peek with the native camera
---------------------------------------------------------------------------------------
--  What it does
--  Hold the configured key to look around. Release it to restore the saved view.
--  Architecture
--  A propagating keyboard handler releases steering before the native camera drag
--  receives the same key press. Save and restore the view with steering released so
--  WoW uses the same camera coordinate space for both operations.
--  Does not own the ordinary Mouse Look toggle, which lives in FreeLookController.
--  Related files are FreeLookController.lua, Runtime.lua, TabGeneral.lua and Bindings.xml.
---------------------------------------------------------------------------------------
local _, CM = ...
local _G = _G

local C_Timer = _G.C_Timer
local GetCVar = _G.C_CVar.GetCVar
local InCombatLockdown = _G.InCombatLockdown
local GetBindingAction = _G.GetBindingAction
local GetBindingKey = _G.GetBindingKey
local IsAltKeyDown = _G.IsAltKeyDown
local IsControlKeyDown = _G.IsControlKeyDown
local IsShiftKeyDown = _G.IsShiftKeyDown
local IsKeyDown = _G.IsKeyDown
local SaveView = _G.SaveView
local SetView = _G.SetView
local MouselookStop = _G.MouselookStop
local ClearOverrideBindings = _G.ClearOverrideBindings
local SetOverrideBinding = _G.SetOverrideBinding

local CAMERA_BINDING = "Combat Mode - Free Look"
local NATIVE_DRAG = "CAMERAORSELECTORMOVE"
local RETURN_VIEW = 5
local RESTORE_TIME = 0.06

local frame = _G.CreateFrame("Frame", nil, _G.UIParent)
local firstKey, secondKey
local heldKey
local restoring = false
local skipPoll = false
local initialDragThreshold
local desired = false

function CM.CanOrbitCamera()
  return SaveView and SetView and IsKeyDown and frame.SetPropagateKeyboardInput
end

function CM.IsCameraOrbitKeyboardBind(key)
  if not key or key == "" then
    return false
  end
  local baseKey = key:match("[^-]+$") or key
  return not (baseKey:match("^BUTTON%d+$") or baseKey:match("^MOUSEWHEEL") or baseKey:match("^PAD"))
end

local function RefreshBindings()
  if InCombatLockdown() then
    return
  end
  local first, second
  if desired and CM.CanOrbitCamera() and CM.DbBool(CM.DB.global.cameraOrbitEnabled, false) then
    first, second = GetBindingKey(CAMERA_BINDING)
    first = CM.IsCameraOrbitKeyboardBind(first) and first or nil
    second = CM.IsCameraOrbitKeyboardBind(second) and second or nil
  end
  if first == firstKey and second == secondKey then
    return
  end
  firstKey, secondKey = first, second
  ClearOverrideBindings(frame)
  if first then
    SetOverrideBinding(frame, true, first, NATIVE_DRAG)
  end
  if second then
    SetOverrideBinding(frame, true, second, NATIVE_DRAG)
  end
  if first or second then
    frame:SetPropagateKeyboardInput(true)
  end
  frame:EnableKeyboard(first ~= nil or second ~= nil)
end

function CM.SetCameraOrbitAvailable(available)
  available = available and true or false
  if desired ~= available then
    desired = available
    RefreshBindings()
  end
end

CM.RefreshCameraOrbitBinding = RefreshBindings

function CM.IsCameraOrbitActive()
  return heldKey ~= nil or restoring
end

local function RestoreDragThreshold()
  if initialDragThreshold ~= nil then
    CM.SetCVar("CursorFreelookStartDelta", initialDragThreshold)
    initialDragThreshold = nil
  end
end

function CM.CancelCameraOrbit()
  heldKey = nil
  restoring = false
  frame:SetScript("OnUpdate", nil)
  RestoreDragThreshold()
end

local function ResumeAiming()
  if restoring then
    restoring = false
    CM.ReconcileFreeLook()
  end
end

local function PollRelease()
  if skipPoll then
    skipPoll = false
    return
  end
  if IsKeyDown(heldKey, true) then
    return
  end

  heldKey = nil
  restoring = true
  frame:SetScript("OnUpdate", nil)
  local blendStyle = GetCVar("cameraViewBlendStyle")
  if blendStyle ~= nil then
    CM.SetCVar("cameraViewBlendStyle", 2)
  end
  SetView(RETURN_VIEW)
  if blendStyle ~= nil then
    CM.SetCVar("cameraViewBlendStyle", blendStyle)
  end
  RestoreDragThreshold()
  C_Timer.After(RESTORE_TIME, ResumeAiming)
end

frame:SetScript("OnKeyDown", function(self, key)
  if heldKey or restoring or not desired then
    return
  end
  local chord = (IsAltKeyDown() and "ALT-" or "")
    .. (IsControlKeyDown() and "CTRL-" or "")
    .. (IsShiftKeyDown() and "SHIFT-" or "")
    .. key
  if (chord ~= firstKey and chord ~= secondKey) or GetBindingAction(chord, true) ~= NATIVE_DRAG then
    return
  end
  if not CM.IsMouselooking() or CM.ShouldFreeLookBeOff() then
    return
  end

  heldKey = key
  skipPoll = true
  initialDragThreshold = GetCVar("CursorFreelookStartDelta")
  if initialDragThreshold ~= nil then
    CM.SetCVar("CursorFreelookStartDelta", 0)
  end
  CM.SetCursorFreelookCenteringCVar(false)
  MouselookStop()
  SaveView(RETURN_VIEW)
  self:SetScript("OnUpdate", PollRelease)
end)

frame:RegisterEvent("UPDATE_BINDINGS")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_LEAVING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LEAVING_WORLD" or event == "PLAYER_LOGOUT" then
    CM.CancelCameraOrbit()
    CM.SetCameraOrbitAvailable(false)
  else
    RefreshBindings()
  end
end)
