-- tests/wowstub.lua: a fake WoW client, just enough for every addon file to load.
--
-- Any global the addon reads that isn't defined here comes back as a mock: indexing it, calling
-- it or doing arithmetic on it gives more mocks, so a file's main chunk runs without the game.
-- That proves the file compiles and that its load-time code doesn't throw. It proves nothing
-- about real API behavior or what happens once events fire: that still needs an in-game check.

local Stub = {
  secrets = {}, -- [value] = true makes issecretvalue(value) answer true; specs clear it after
}

local mockMeta = {}
local mockNames = setmetatable({}, { __mode = "k" })

local function Mock(name)
  local mock = setmetatable({}, mockMeta)
  mockNames[mock] = name
  return mock
end

local function Zero()
  return 0
end

-- Lua 5.1 can't compare a table with a number, even through a metamethod, so a call whose result
-- gets compared has to return a real number. Add names here when a load fails on one.
local NUMBER_RESULT = {
  GetBottom = true,
  GetCenter = true,
  GetEffectiveScale = true,
  GetHeight = true,
  GetLeft = true,
  GetNumChildren = true,
  GetNumPoints = true,
  GetNumRegions = true,
  GetRight = true,
  GetScale = true,
  GetTop = true,
  GetWidth = true,
}

-- Walks over children must end, so these calls return nothing.
local EMPTY_RESULT = { GetChildren = true, GetRegions = true }

-- Blizzard's methods and child keys are PascalCase. A lowercase or _private field is data the
-- addon stores on a frame, or a value in an API result, and starts out nil as it would in game.
mockMeta.__index = function(self, key)
  if key == "r" or key == "g" or key == "b" or key == "a" then
    return 1 -- every mock can stand in for a Blizzard color table
  end
  if type(key) ~= "string" or not string.find(key, "^%u") then
    return nil
  end
  local value = Mock(key)
  rawset(self, key, value)
  return value
end
mockMeta.__call = function(self)
  local name = mockNames[self]
  if NUMBER_RESULT[name] then
    return 0
  end
  if EMPTY_RESULT[name] then
    return
  end
  return Mock()
end
mockMeta.__concat = function()
  return ""
end
mockMeta.__unm = Zero
for _, op in ipairs({ "__add", "__sub", "__mul", "__div", "__mod", "__pow" }) do
  mockMeta[op] = Zero
end
mockMeta.__lt = function()
  return false
end
mockMeta.__le = function()
  return false
end

local PLAIN_LUA = {
  "assert",
  "bit",
  "collectgarbage",
  "error",
  "getfenv",
  "getmetatable",
  "ipairs",
  "loadstring",
  "math",
  "next",
  "pairs",
  "pcall",
  "print",
  "rawequal",
  "rawget",
  "rawset",
  "select",
  "setfenv",
  "setmetatable",
  "string",
  "table",
  "tonumber",
  "tostring",
  "type",
  "unpack",
  "xpcall",
}

local function Split(separator, text, limit)
  local parts, from = {}, 1
  while not limit or #parts < limit - 1 do
    local first, last = string.find(text, separator, from, true)
    if not first then
      break
    end
    parts[#parts + 1] = string.sub(text, from, first - 1)
    from = last + 1
  end
  parts[#parts + 1] = string.sub(text, from)
  return unpack(parts)
end

local function Wipe(t)
  for key in pairs(t) do
    t[key] = nil
  end
  return t
end

local function Mixin(object, ...)
  for index = 1, select("#", ...) do
    for key, value in pairs((select(index, ...))) do
      object[key] = value
    end
  end
  return object
end

local function CopyTable(source)
  local copy = {}
  for key, value in pairs(source) do
    copy[key] = type(value) == "table" and CopyTable(value) or value
  end
  return copy
end

local function Noop() end

-- A fresh client: build is the interface number select(4, GetBuildInfo()) reports. Retail and
-- Forever have secret values; the Classic-family clients don't have the API at all.
function Stub.NewEnv(build)
  local env = {}
  for _, name in ipairs(PLAIN_LUA) do
    env[name] = _G[name]
  end
  env._G = env

  -- WoW's global aliases for the standard library
  env.format = string.format
  env.gsub = string.gsub
  env.strbyte = string.byte
  env.strchar = string.char
  env.strfind = string.find
  env.strlen = string.len
  env.strlower = string.lower
  env.strmatch = string.match
  env.strrep = string.rep
  env.strsub = string.sub
  env.strupper = string.upper
  env.gmatch = string.gmatch
  env.strsplit = Split
  env.strtrim = function(text)
    return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
  end
  env.strjoin = function(separator, ...)
    return table.concat({ ... }, separator)
  end
  env.tinsert = table.insert
  env.tremove = table.remove
  env.sort = table.sort
  env.wipe = Wipe
  env.abs = math.abs
  env.ceil = math.ceil
  env.floor = math.floor
  env.max = math.max
  env.min = math.min
  env.date = os.date
  env.time = os.time
  env.Mixin = Mixin
  env.CreateFromMixins = function(...)
    return Mixin({}, ...)
  end
  env.CopyTable = CopyTable

  -- The answers load-time branches depend on
  local isRetail = build >= 100000
  local isForever = build >= 16000 and build < 20000
  env.WOW_PROJECT_MAINLINE = 1
  env.WOW_PROJECT_ID = isRetail and 1 or 2
  env.GetBuildInfo = function()
    return "0.0.0", "0", "Jan 1 2026", build
  end
  env.GetLocale = function()
    return "enUS"
  end
  env.GetTime = Zero
  env.GetScreenWidth = function()
    return 1920
  end
  env.GetScreenHeight = function()
    return 1080
  end
  env.InCombatLockdown = function()
    return false
  end
  env.geterrorhandler = function()
    return Noop
  end
  env.canaccessvalue = function()
    return true
  end
  env.canaccesstable = function()
    return true
  end
  env.hooksecurefunc = Noop
  env.CombatModeDB = {}

  local absent = {}
  if isRetail or isForever then
    env.issecretvalue = function(value)
      return value ~= nil and Stub.secrets[value] == true
    end
  else
    absent.issecretvalue = true
  end

  return setmetatable(env, {
    __index = function(self, key)
      if absent[key] then
        return nil
      end
      local value = Mock(key)
      rawset(self, key, value)
      return value
    end,
  })
end

return Stub
