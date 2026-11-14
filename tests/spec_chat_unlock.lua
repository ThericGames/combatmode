return function(check, CM, env)
  local oldDB, oldAPI = CM.DB, env.ChatEdit_GetActiveWindow
  CM.DB = { global = { unlockWhileChatting = true, frameWatching = false } }
  env.ChatEdit_GetActiveWindow = nil
  check("missing chat API", CM.IsChatInputActive(), false)
  local active
  env.ChatEdit_GetActiveWindow = function()
    return active
  end
  check("closed chat", CM.IsChatInputActive(), false)
  local shown, focused, forbidden = true, true, false
  active = {
    IsShown = function()
      return shown
    end,
    HasFocus = function()
      return focused
    end,
    IsForbidden = function()
      return forbidden
    end,
  }
  check("typing unlocks even with frame watching off", CM.IsChatInputActive(), true)
  focused = false
  check("visible but unfocused input", CM.IsChatInputActive(), false)
  focused, shown = true, false
  check("hidden input", CM.IsChatInputActive(), false)
  shown, forbidden = true, true
  check("forbidden input", CM.IsChatInputActive(), false)
  forbidden = false
  CM.DB.global.unlockWhileChatting = false
  check("option disabled", CM.IsChatInputActive(), false)
  CM.DB.global.unlockWhileChatting = true
  active = nil
  check("send or escape releases condition", CM.IsChatInputActive(), false)
  CM.DB, env.ChatEdit_GetActiveWindow = oldDB, oldAPI
end
