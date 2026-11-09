---------------------------------------------------------------------------------------
--  Core/Runtime/Safe.lua — RUNTIME — secret-value helpers
---------------------------------------------------------------------------------------
--  What it does: Publishes CM.Safe, the one definition of the readers every module uses on
--  values that can be secret in instances (.claude/rules/lua-safety.md).
--  Architecture / how it works:
--    • IsSecret(v): true only when the client says v is secret. A client without
--      issecretvalue has no secrets, so it reads false.
--    • PublicBool(v): true or false when v is a public boolean, else nil.
--    • PublicTruthy(v): true or false for any public non-nil value, nil when v is nil or
--      secret. For APIs that can answer 1 / nil instead of a boolean on older clients.
--    • PublicNumber(v, fallback): v when it is a public number, else fallback.
--    • Each checks type() or IsSecret before anything else touches the value, since
--      comparing a secret, even with nil, can raise an error.
--    • Loads right after Runtime.lua; modules alias what they use at file scope
--      (local IsSecret = CM.Safe.IsSecret).
--  Does not: Make a secret readable, or decide what a module does with an unknown answer.
--  Related: .claude/rules/lua-safety.md, scripts/check-repo.ps1, tests/spec_safe.lua
---------------------------------------------------------------------------------------
local _, CM = ...
local _G = _G

local issecretvalue = _G.issecretvalue
local type = _G.type

local Safe = {}
CM.Safe = Safe

local function IsSecret(value)
  return issecretvalue ~= nil and type(value) ~= "nil" and issecretvalue(value) == true
end
Safe.IsSecret = IsSecret

function Safe.PublicBool(value)
  if type(value) ~= "boolean" or IsSecret(value) then
    return nil
  end
  return value
end

function Safe.PublicTruthy(value)
  if type(value) == "nil" or IsSecret(value) then
    return nil
  end
  return value and true or false
end

function Safe.PublicNumber(value, fallback)
  if type(value) ~= "number" or IsSecret(value) then
    return fallback
  end
  return value
end
