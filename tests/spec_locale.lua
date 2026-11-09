-- tests/spec_locale.lua: the CM.L table in Locales/Locale.lua.

return function(check, CM)
  local L = CM.L
  check("unknown key reads as itself", L["spec only key"], "spec only key")
  L["spec true key"] = true
  check("true stores the key as its text", rawget(L, "spec true key"), "spec true key")
  L["spec text key"] = "translated"
  check("a string is stored", L["spec text key"], "translated")
  L["spec number key"] = 5
  check("anything else is ignored", rawget(L, "spec number key"), nil)
end
