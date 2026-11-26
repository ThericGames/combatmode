-- Focus-frame hiding preserves native visibility and defers protected changes in combat.
return function(check, CM, env)
  local combat, editing = false, false
  local original = {}
  local parent = original
  local writes = 0
  local frame = {
    GetParent = function()
      return parent
    end,
    SetParent = function(_, value)
      assert(not combat, "must not reparent a protected frame in combat")
      parent = value
      writes = writes + 1
    end,
  }
  local testCM = { DB = { global = {} }, DbBool = CM.DbBool }
  local testEnv = setmetatable({
    FocusFrame = frame,
    EditModeManagerFrame = {
      IsEditModeActive = function()
        return editing
      end,
    },
    InCombatLockdown = function()
      return combat
    end,
    CreateFrame = function()
      return {
        Hide = function(self)
          self.hidden = true
        end,
      }
    end,
  }, { __index = env })
  testEnv._G = testEnv
  local path = debug.getinfo(CM.ApplyFocusFrameVisibility, "S").source:sub(2)
  local chunk = assert(loadfile(path))
  setfenv(chunk, testEnv)
  chunk("CombatMode", testCM)
  local apply = testCM.ApplyFocusFrameVisibility
  apply()
  check("default leaves frame alone", writes, 0)
  testCM.DB.global.hideFocusFrame = true
  combat = true
  apply()
  check("enable defers in combat", writes, 0)
  combat = false
  apply()
  check("hidden parent", parent.hidden, true)
  apply()
  check("repeated apply is idempotent", writes, 1)
  testCM.DB.global.hideFocusFrame = false
  combat = true
  apply()
  check("disable defers in combat", writes, 1)
  combat = false
  apply()
  check("restores original parent", parent, original)
  testCM.DB.global.hideFocusFrame = true
  apply()
  editing = true
  apply()
  check("Edit Mode restores native parent", parent, original)
  editing = false
  apply()
  check("leaving Edit Mode hides frame again", parent.hidden, true)
  local otherAddonParent = {}
  parent = otherAddonParent
  testCM.DB.global.hideFocusFrame = false
  apply()
  check("does not undo another addon parent", parent, otherAddonParent)
  testCM.DB.global.hideFocusFrame = true
  apply()
  check("re-enable preserves third-party ownership", parent, otherAddonParent)
  testCM.DB.global.hideFocusFrame = 0
  apply()
  check("numeric false leaves frame alone", parent, otherAddonParent)
end
