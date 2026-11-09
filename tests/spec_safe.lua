-- tests/spec_safe.lua: the secret-value readers in Core/Runtime/Safe.lua.

local Stub = require("wowstub")

return function(check, CM, env)
  local Safe = CM.Safe
  check("public value is not secret", Safe.IsSecret(5), false)
  check("nil is not secret", Safe.IsSecret(nil), false)
  check("PublicBool true", Safe.PublicBool(true), true)
  check("PublicBool false", Safe.PublicBool(false), false)
  check("PublicBool rejects a non-boolean", Safe.PublicBool(1), nil)
  check("PublicTruthy accepts 1", Safe.PublicTruthy(1), true)
  check("PublicTruthy keeps false", Safe.PublicTruthy(false), false)
  check("PublicTruthy keeps nil", Safe.PublicTruthy(nil), nil)
  check("PublicNumber passes a number", Safe.PublicNumber(3, 9), 3)
  check("PublicNumber falls back", Safe.PublicNumber("3", 9), 9)
  check("PublicNumber has no default fallback", Safe.PublicNumber(nil), nil)

  if rawget(env, "issecretvalue") == nil then
    return -- Classic-family clients have no secrets, and the readers must cope with that
  end
  Stub.secrets[true] = true
  Stub.secrets[42] = true
  check("secret reads as secret", Safe.IsSecret(42), true)
  check("secret bool reads as nil", Safe.PublicBool(true), nil)
  check("secret truthy reads as nil", Safe.PublicTruthy(42), nil)
  check("secret number reads as the fallback", Safe.PublicNumber(42, 7), 7)
  Stub.secrets[true] = nil
  Stub.secrets[42] = nil
end
