-- tests/spec_user_condition.lua: CM.EvaluateUserLuaCondition in Core/Runtime/UserLuaCondition.lua.

return function(check, CM)
  local evaluate = CM.EvaluateUserLuaCondition
  local original = CM.DebugPrintThrottled
  local logged = 0
  CM.DebugPrintThrottled = function()
    logged = logged + 1
  end

  check("nil source is false", evaluate(nil, {}), false)
  check("empty source is false", evaluate("", {}), false)
  check("true result", evaluate("return true", {}), true)
  check("truthy result becomes true", evaluate("return 1", {}), true)
  check("no result is false", evaluate("local x = 1", {}), false)

  local cache = {}
  evaluate("return true", cache)
  local compiled = cache.func
  evaluate("return true", cache)
  check("same source reuses the compiled function", cache.func, compiled)
  evaluate("return false", cache)
  check("new source recompiles", cache.func ~= compiled, true)

  logged = 0
  check("a syntax error is false", evaluate("return (", {}), false)
  check("a runtime error is false", evaluate("error('x')", {}), false)
  check("both errors are logged", logged, 2)

  CM.DebugPrintThrottled = original
end
