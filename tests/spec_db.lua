-- tests/spec_db.lua: CM.DbBool in Core/Runtime/Runtime.lua (Forever can store 1/0 for booleans).

return function(check, CM)
  local DbBool = CM.DbBool
  check("nil takes a true default", DbBool(nil, true), true)
  check("nil takes a false default", DbBool(nil, false), false)
  check("nil with no default is false", DbBool(nil), false)
  check("false stays false", DbBool(false, true), false)
  check("0 is false", DbBool(0, true), false)
  check("true stays true", DbBool(true, false), true)
  check("1 is true", DbBool(1, false), true)
  check("any other value is true", DbBool("yes", false), true)
end
