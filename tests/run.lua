-- tests/run.lua: compiles and loads every addon file against tests/wowstub.lua, once per client in
-- CombatMode.toc, then runs the unit specs. Started by scripts/test.ps1: luajit tests/run.lua <repo>.
-- LuaJIT shares Lua 5.1's language and its limit of 200 locals per function.

local root = ...

package.path = root .. "/tests/?.lua;" .. package.path
local Stub = require("wowstub")

local ADDON = "CombatMode"
local SPECS = { "spec_safe", "spec_locale", "spec_user_condition", "spec_db", "spec_self_cast" }
local CLIENTS = {
  { name = "retail", pattern = "## Interface:%s*(%d+)" },
  { name = "forever", pattern = "## Interface%-Forever:%s*(%d+)" },
  { name = "mists", pattern = "## Interface%-Mists:%s*(%d+)" },
  { name = "cata", pattern = "## Interface%-Cata:%s*(%d+)" },
  { name = "titan", pattern = "## Interface%-Titan:%s*(%d+)" },
  { name = "wrath", pattern = "## Interface%-Wrath:%s*(%d+)" },
  { name = "bcc", pattern = "## Interface%-BCC:%s*(%d+)" },
  { name = "classic", pattern = "## Interface%-Classic:%s*(%d+)" },
}

local failures = 0
local fileCount = 0

local function Fail(where, message)
  failures = failures + 1
  print(("[FAIL] %s: %s"):format(where, message))
end

local function ReadAll(path)
  local handle = assert(io.open(path, "rb"))
  local text = handle:read("*a")
  handle:close()
  return text
end

local function ScriptsOf()
  local xml = ReadAll(("%s/%s/Embeds.xml"):format(root, ADDON)):gsub("<!%-%-.-%-%->", "")
  local scripts = {}
  for file in xml:gmatch('<Script%s+file="([^"]+)"') do
    scripts[#scripts + 1] = (file:gsub("\\", "/"))
  end
  return scripts
end

local function LoadFile(client, env, addonTable, file)
  local where = ("%s/%s (%s)"):format(ADDON, file, client)
  fileCount = fileCount + 1
  local chunk, syntaxError = loadfile(("%s/%s/%s"):format(root, ADDON, file))
  if not chunk then
    Fail(where, syntaxError)
    return
  end
  setfenv(chunk, env)
  local ok, loadError = xpcall(function()
    chunk(ADDON, addonTable)
  end, debug.traceback)
  if not ok then
    Fail(where, loadError)
  end
end

local function RunSpecs(client, CM, env)
  for _, name in ipairs(SPECS) do
    local spec = require(name)
    local function Check(label, actual, expected)
      if actual ~= expected then
        Fail(
          ("%s (%s)"):format(name, client),
          ("%s: expected %s, got %s"):format(label, tostring(expected), tostring(actual))
        )
      end
    end
    local ok, specError = xpcall(function()
      spec(Check, CM, env)
    end, debug.traceback)
    if not ok then
      Fail(("%s (%s)"):format(name, client), specError)
    end
  end
end

local function RunClient(client, build)
  local env = Stub.NewEnv(build)
  local addonTable = {}
  for _, file in ipairs(ScriptsOf()) do
    LoadFile(client, env, addonTable, file)
  end
  RunSpecs(client, addonTable, env)
end

local toc = ReadAll(("%s/%s/%s.toc"):format(root, ADDON, ADDON))
for _, client in ipairs(CLIENTS) do
  local build = assert(toc:match(client.pattern), "CombatMode.toc has no line for " .. client.name)
  RunClient(client.name, tonumber(build))
end

if failures > 0 then
  print(("%d test failure(s)."):format(failures))
  os.exit(1)
end
print(("[PASS] %d file loads across %d clients, plus unit specs."):format(fileCount, #CLIENTS))
os.exit(0)
