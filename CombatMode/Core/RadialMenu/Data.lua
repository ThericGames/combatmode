---------------------------------------------------------------------------------------
--  Core/RadialMenu/Data.lua — RADIALMENU — wheel storage, layout constants, entry info
---------------------------------------------------------------------------------------
--  What it does: Owns the player's wheels (DB.char.radialMenu.wheels), the shared layout
--  constants (CM.RadialLayout) and the helpers that turn a slice entry into a name / icon /
--  secure action. Every mutation ends in CM.RadialRefresh (re-store the secure attributes).
--  Architecture / how it works:
--    • Wheel = { name = "optional title", count = n, slots = { [1..8] = entry } }, slots may have holes; the wheel
--      shows its filled slots only, compacted in order (like a wheel of 3 = three thirds).
--    • Entry = { kind = "spell" | "item" | "macro" | "action", id = number | string }.
--      "action" ids are keys of CM.RadialActions (Actions.lua).
--    • A slot is its 1st entry plus more = { entry, ... } (up to MAX_ACTIONS in all), scrolled
--      through on the open wheel. Read it with CM.RadialSlotActions.
--    • CM.RadialEntrySecure(entry) → type, value, isMacroText: what the slice's
--      SecureActionButton needs (spell name, "item:ID", macro name, or "/click" text).
--    • CM.RadialCompact(wheel) → each filled slot's action list, in order (what the secure side stores).
--  Does not: Draw anything, own secure frames or bindings, or build the editor window.
--  Related: Core/RadialMenu/{Actions,Secure,View,RadialMenu}.lua, UI/Options/Tabs/TabRadialMenu.lua, Constants/DatabaseDefaults.lua
---------------------------------------------------------------------------------------
local _, CM = ...
local L = CM.L
local _G = _G

-- WoW API
local C_Item = _G.C_Item
local C_Spell = _G.C_Spell
local CreateFrame = _G.CreateFrame
local GetMacroInfo = _G.GetMacroInfo

-- Lua stdlib
local format = _G.string.format
local ipairs = _G.ipairs
local math = _G.math
local unpack = _G.unpack
local select = _G.select
local type = _G.type

-- Shared by Secure.lua and View.lua. Two looks (CM.RadialStyle, global.radialStyle): "forever" is the
-- original framed art, 512 x 512 with its crown (the ring the icons sit in) from 75 to 213 from the
-- middle; "minimal" is Blizzard's radial vignette (a ring at 84) as one 1024 px background drawn 1:1, with
-- the hairline dividers prerendered per slice count (512 px) and its highlight wedge (84 to 208).
-- `overlay` places the wedge (slice 1 of n)
-- as { width, height, x, y } with x, y the canvas centre from the wheel's (y up); `off` = the grey
-- overlay on unusable slices (art `radial_off_N`), `bg` = drawn size, `dead` = dead zone radius,
-- `art` = texture file prefix (radial_<art>{bg,sel}_N.tga), `ring` = editor hit ring start.
CM.RadialLayout = {
  MAX_WHEELS = 5,
  MAX_SLICES = 8,
  MAX_ACTIONS = 5, -- actions one slice can hold
  ART = 512,
  FRAME = 2048, -- secure frame: big enough that the cursor is always over it (aim math)
  ICON_RADIUS = 148,
  -- Highlight colour of the aimed slice per wheel (white art, tinted), so wheels read apart at a glance.
  WHEEL_COLORS = {
    { 0.35, 0.65, 1 },
    { 0.45, 0.85, 0.45 },
    { 0.85, 0.5, 1 },
    { 1, 0.62, 0.25 },
    { 1, 0.45, 0.5 },
  },
  NAME_MAX = 10, -- wheel name length, so titles never need an ellipsis
  SLOT = 46,
  STYLES = {
    forever = {
      art = "",
      perCount = true, -- radial_bg_<n>.tga per slice count
      bg = 512,
      dead = 50,
      ring = 60,
      off = true,
      overlay = {
        [1] = { 512, 512, 0, 0 },
        [2] = { 512, 256, 0, 110 },
        [3] = { 512, 256, 0, 130 },
        [4] = { 512, 256, 0, 137 },
        [5] = { 256, 256, 0, 140 },
        [6] = { 256, 256, 0, 142 },
        [7] = { 256, 256, 0, 142 },
        [8] = { 256, 256, 0, 143 },
      },
    },
    minimal = {
      art = "minimal_",
      perCount = false, -- one background for every count, dividers are their own texture
      bg = 1024,
      dead = 80, -- just inside the background's ring
      ring = 80,
      off = false,
      overlay = {
        [1] = { 512, 512, 0, -47 },
        [2] = { 512, 256, 0, 81 },
        [3] = { 512, 256, 0, 81 },
        [4] = { 512, 256, 0, 81 },
        [5] = { 256, 256, 0, 81 },
        [6] = { 256, 256, 0, 81 },
        [7] = { 256, 256, 0, 81 },
        [8] = { 256, 256, 0, 81 },
      },
    },
  },
}

local LAYOUT = CM.RadialLayout

--- The active look (global.radialStyle: "forever" | "minimal"); unknown values fall back to minimal.
function CM.RadialStyle()
  local g = CM.DB and CM.DB.global
  return LAYOUT.STYLES[g and g.radialStyle or "minimal"] or LAYOUT.STYLES.minimal
end

--- Size of both live wheels (global.radialScale); the options editor ignores it.
function CM.RadialScale()
  local g = CM.DB and CM.DB.global
  return g and g.radialScale or 1
end

local ART_DIR = "Interface\\AddOns\\CombatMode\\Assets\\radial\\radial_"
local DIV_SIZE = 512 -- radial_minimal_div_<n>.tga canvas, drawn 1:1 (rotating a hairline in game blurs it)

--- Draws the active look's background for `n` slices at `scale` (the options editor draws it smaller).
function CM.RadialPaintBackground(tex, n, scale)
  local style = CM.RadialStyle()
  tex:SetSize(style.bg * scale, style.bg * scale)
  tex:SetTexture(ART_DIR .. style.art .. (style.perCount and ("bg_" .. n) or "bg") .. ".tga")
end

--- The divider overlay texture of looks that draw their dividers apart from the background.
function CM.RadialCreateDividers(parent)
  local tex = parent:CreateTexture(nil, "BACKGROUND", nil, 1)
  tex:SetPoint("CENTER")
  tex:Hide()
  return tex
end

--- Shows the dividers for `n` slices centred on `anchor`; hidden for looks that bake them in.
function CM.RadialPlaceDividers(tex, anchor, n, scale)
  local style = CM.RadialStyle()
  if style.perCount or n < 2 then
    tex:Hide()
    return
  end
  tex:ClearAllPoints()
  tex:SetPoint("CENTER", anchor, "CENTER")
  tex:SetSize(DIV_SIZE * scale, DIV_SIZE * scale)
  tex:SetTexture(ART_DIR .. style.art .. "div_" .. n .. ".tga")
  tex:Show()
end

-- Preset wheels: first-run content, and what the editor's "+" menu can add back later.
-- Each entry is one slice: an action id, or a list of ids for a slice with several. Actions this
-- client lacks are left out, and so is a slice that is left with none.
local function PresetWheel(name, entries)
  local slots = {}
  for _, entry in ipairs(entries) do
    local slot
    for _, id in ipairs(type(entry) == "table" and entry or { entry }) do
      if CM.RadialActions.IsAvailable(id) then
        local action = { kind = "action", id = id }
        if not slot then
          slot = action
        else
          slot.more = slot.more or {}
          slot.more[#slot.more + 1] = action
        end
      end
    end
    slots[#slots + 1] = slot -- nil adds nothing
  end
  return { name = name, count = #slots, slots = slots }
end

local PRESETS = {
  {
    key = "interface",
    label = L["Interface"],
    build = function()
      local build = _G.GetBuildInfo and select(4, _G.GetBuildInfo()) or 0
      local isForever = type(build) == "number" and build >= 16000 and build < 20000
      local modern = _G.WOW_PROJECT_ID == _G.WOW_PROJECT_MAINLINE or isForever
      -- The spellbook alone beside Talents; clients without it get "Spellbook & Talents".
      local spellbook = CM.RadialActions.IsAvailable("spellbookonly") and "spellbookonly"
        or "spellbook"
      return PresetWheel(L["Interface"], {
        { "character", "reputation", "currency" },
        { "talents", spellbook },
        { "bags", "professions" },
        "legacy",
        { "gamemenu", "macros", "acmoptions" },
        -- The other clients have no calendar: the World Map takes its place.
        { "questlog", modern and "calendar" or "map" },
        { "groupfinder", "social", "guild" },
        { "collections", "toybox" },
      })
    end,
  },
  {
    key = "emotes",
    label = L["Emotes"],
    build = function()
      return PresetWheel(L["Emotes"], {
        "emote_hello",
        "emote_thank",
        "emote_bye",
        "emote_cheer",
        "emote_sit",
        "emote_dance",
        "emote_cry",
        "emote_ready",
      })
    end,
  },
  {
    key = "misc",
    label = L["Misc"],
    build = function()
      return PresetWheel(L["Misc"], {
        { "readycheck", "rolepoll", "countdown" },
        "duel",
        "invitetarget",
        "inspect",
        "reloadui",
      })
    end,
  },
}

--- { { key, label }, ... } of the preset wheels, in menu order.
function CM.RadialPresetList()
  return PRESETS
end

local function PresetWheels()
  local wheels = {}
  for i, preset in ipairs(PRESETS) do
    wheels[i] = preset.build()
  end
  return wheels
end

local function RadialDb()
  local char = CM.DB and CM.DB.char
  if not char then
    return nil
  end
  if type(char.radialMenu) ~= "table" then
    char.radialMenu = { wheels = {} }
  end
  if type(char.radialMenu.wheels) ~= "table" then
    char.radialMenu.wheels = {}
  end
  -- Seeded once per character, so deleting every wheel later doesn't bring the presets back.
  if not char.radialMenu.presetsSeeded then
    char.radialMenu.presetsSeeded = true
    if #char.radialMenu.wheels == 0 then
      char.radialMenu.wheels = PresetWheels()
    end
  end
  return char.radialMenu
end

function CM.RadialGetWheels()
  local db = RadialDb()
  return db and db.wheels or {}
end

local function Changed()
  if CM.RadialRefresh then
    CM.RadialRefresh()
  end
end

--- New wheel appended, or inserted before `atIndex`; returns its index. `presetKey` (see
--- CM.RadialPresetList) fills it from a preset, otherwise it is an empty 4-slice wheel.
function CM.RadialCreateWheel(atIndex, presetKey)
  local db = RadialDb()
  if not db or #db.wheels >= LAYOUT.MAX_WHEELS then
    return nil
  end
  local index = math.max(1, math.min(atIndex or (#db.wheels + 1), #db.wheels + 1))
  local wheel
  for _, preset in ipairs(PRESETS) do
    if preset.key == presetKey then
      wheel = preset.build()
    end
  end
  table.insert(
    db.wheels,
    index,
    wheel or { name = format(L["Wheel %d"], index), count = 4, slots = {} }
  )
  Changed()
  return index
end

--- r, g, b highlight colour of wheel `index`.
function CM.RadialWheelColor(index)
  local color = LAYOUT.WHEEL_COLORS[index] or LAYOUT.WHEEL_COLORS[1]
  return color[1], color[2], color[3]
end

--- First `count` UTF-8 characters of `text` (continuation bytes are 128..191), so CJK / Cyrillic names never split.
local function Utf8Prefix(text, count)
  local seen = 0
  for i = 1, #text do
    local byte = text:byte(i)
    if byte < 128 or byte > 191 then
      seen = seen + 1
      if seen > count then
        return text:sub(1, i - 1)
      end
    end
  end
  return text
end

--- Wheel title shown in the editor and in the middle of the open wheel.
function CM.RadialWheelName(wheel, index)
  local name = wheel and wheel.name
  if type(name) == "string" and name ~= "" then
    return Utf8Prefix(name, LAYOUT.NAME_MAX)
  end
  return format(L["Wheel %d"], index or 1)
end

--- Blank names fall back to "Wheel <index>".
function CM.RadialRenameWheel(index, name)
  local wheel = CM.RadialGetWheels()[index]
  if not wheel then
    return
  end
  name = type(name) == "string" and name:match("^%s*(.-)%s*$") or ""
  wheel.name = name ~= "" and Utf8Prefix(name, LAYOUT.NAME_MAX) or nil
  Changed()
end

--- Slices the editor shows for a wheel (1..MAX_SLICES); empty ones are left out of the live wheel.
function CM.RadialSliceCount(wheel)
  if not wheel then
    return 0
  end
  local count = wheel.count
  if type(count) ~= "number" then
    count = 0
    for slot = 1, LAYOUT.MAX_SLICES do
      if wheel.slots and wheel.slots[slot] then
        count = slot
      end
    end
  end
  return math.max(1, math.min(LAYOUT.MAX_SLICES, count))
end

function CM.RadialAddSlice(index)
  local wheel = CM.RadialGetWheels()[index]
  local count = CM.RadialSliceCount(wheel)
  if not wheel or count >= LAYOUT.MAX_SLICES then
    return false
  end
  wheel.count = count + 1
  Changed()
  return true
end

--- Removes slice `slot` and shifts the later ones down. A wheel always keeps at least one slice.
function CM.RadialRemoveSlice(index, slot)
  local wheel = CM.RadialGetWheels()[index]
  local count = CM.RadialSliceCount(wheel)
  if not wheel or count <= 1 or slot < 1 or slot > count then
    return false
  end
  wheel.slots = wheel.slots or {}
  for i = slot, count - 1 do
    wheel.slots[i] = wheel.slots[i + 1]
  end
  wheel.slots[count] = nil
  wheel.count = count - 1
  Changed()
  return true
end

--- Entry for whatever the cursor carries (spell, item / toy, macro, mount), or nil.
function CM.RadialEntryFromCursor()
  local kind, a, b, c = _G.GetCursorInfo()
  local function known(id)
    return C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
  end
  if kind == "spell" then
    local id = type(c) == "number" and c or (type(b) == "number" and b or nil)
    if id and known(id) then
      return { kind = "spell", id = id }
    end
  elseif kind == "item" then
    if type(a) == "number" then
      return { kind = "item", id = a }
    end
  elseif kind == "macro" then
    local name = type(a) == "number" and GetMacroInfo(a) or nil
    if name then
      return { kind = "macro", id = name }
    end
  elseif kind == "mount" then
    local mounts = _G.C_MountJournal
    local mountId = type(a) == "number" and a or nil
    if mounts and mountId and mounts.GetMountInfoByID then
      local _, spellId = mounts.GetMountInfoByID(mountId)
      if type(spellId) == "number" and known(spellId) then
        return { kind = "spell", id = spellId }
      end
    end
  end
  return nil
end

function CM.RadialDeleteWheel(index)
  local db = RadialDb()
  if not db or not db.wheels[index] then
    return
  end
  table.remove(db.wheels, index)
  Changed()
end

--- Moves wheel `from` to position `to` (the other wheels shift to make room).
function CM.RadialMoveWheel(from, to)
  local db = RadialDb()
  local total = db and #db.wheels or 0
  if
    type(from) ~= "number"
    or type(to) ~= "number"
    or from == to
    or from < 1
    or to < 1
    or from > total
    or to > total
  then
    return
  end
  table.insert(db.wheels, to, table.remove(db.wheels, from))
  Changed()
end

local function ValidEntry(entry)
  if type(entry) ~= "table" then
    return false
  end
  if entry.kind == "spell" or entry.kind == "item" then
    return type(entry.id) == "number"
  end
  if entry.kind == "macro" or entry.kind == "action" then
    return type(entry.id) == "string" and entry.id ~= ""
  end
  return false
end

--- Only the saved fields: a slot's own table also carries `more`.
local function CopyEntry(entry)
  return { kind = entry.kind, id = entry.id }
end

--- A slot's valid actions in order (copies); empty for a nil slot.
function CM.RadialSlotActions(slot)
  local actions = {}
  local function add(entry)
    if #actions < LAYOUT.MAX_ACTIONS and ValidEntry(entry) then
      actions[#actions + 1] = CopyEntry(entry)
    end
  end
  if type(slot) == "table" then
    add(slot)
    if type(slot.more) == "table" then
      for _, entry in ipairs(slot.more) do
        add(entry)
      end
    end
  end
  return actions
end

--- The wheel and slot's actions, or nil for a bad index.
local function SlotForEdit(index, slot)
  local wheel = CM.RadialGetWheels()[index]
  if not wheel or type(slot) ~= "number" or slot < 1 or slot > LAYOUT.MAX_SLICES then
    return nil
  end
  wheel.slots = wheel.slots or {}
  return wheel, CM.RadialSlotActions(wheel.slots[slot])
end

--- Saves an action list: the 1st in the slot itself (the old one-action shape), the rest in `more`.
local function StoreActions(wheel, slot, actions)
  local first = actions[1]
  if first and #actions > 1 then
    first.more = {}
    for i = 2, #actions do
      first.more[i - 1] = actions[i]
    end
  end
  wheel.slots[slot] = first
  Changed()
end

--- Appends an action to a slot; returns its position, or nil when full / invalid.
function CM.RadialAddAction(index, slot, entry)
  local wheel, actions = SlotForEdit(index, slot)
  if not wheel or #actions >= LAYOUT.MAX_ACTIONS or not ValidEntry(entry) then
    return nil
  end
  actions[#actions + 1] = CopyEntry(entry)
  StoreActions(wheel, slot, actions)
  return #actions
end

--- Replaces action `pos`; entry = nil removes it (the later ones move up).
function CM.RadialSetAction(index, slot, pos, entry)
  local wheel, actions = SlotForEdit(index, slot)
  if not wheel or not actions[pos] or (entry ~= nil and not ValidEntry(entry)) then
    return false
  end
  if entry then
    actions[pos] = CopyEntry(entry)
  else
    table.remove(actions, pos)
  end
  StoreActions(wheel, slot, actions)
  return true
end

--- Moves action `pos` to the front: the one every open of the wheel starts on.
function CM.RadialMakeFirstAction(index, slot, pos)
  local wheel, actions = SlotForEdit(index, slot)
  if not wheel or pos == 1 or not actions[pos] then
    return false
  end
  table.insert(actions, 1, table.remove(actions, pos))
  StoreActions(wheel, slot, actions)
  return true
end

--- entry = nil empties the slot (all its actions).
function CM.RadialSetSlot(index, slot, entry)
  local wheel = CM.RadialGetWheels()[index]
  if not wheel or type(slot) ~= "number" or slot < 1 or slot > LAYOUT.MAX_SLICES then
    return
  end
  if entry ~= nil and not ValidEntry(entry) then
    return
  end
  wheel.slots = wheel.slots or {}
  wheel.slots[slot] = entry and { kind = entry.kind, id = entry.id } or nil
  Changed()
end

--- Rearranges the slices: new position `p` takes the entry that was in slot `order[p]` (a
--- permutation of 1..count; slots may have holes).
function CM.RadialReorderSlots(index, order)
  local wheel = CM.RadialGetWheels()[index]
  if not wheel or not wheel.slots then
    return
  end
  local count = CM.RadialSliceCount(wheel)
  local seen, moved = {}, {}
  for position = 1, count do
    local source = order[position]
    if type(source) ~= "number" or source < 1 or source > count or seen[source] then
      return
    end
    seen[source] = true
    moved[position] = wheel.slots[source]
  end
  for position = 1, count do
    wheel.slots[position] = moved[position]
  end
  Changed()
end

--- The action lists of the wheel's filled slots, in order, no holes.
function CM.RadialCompact(wheel)
  local list = {}
  if wheel and wheel.slots then
    for slot = 1, LAYOUT.MAX_SLICES do
      local actions = CM.RadialSlotActions(wheel.slots[slot])
      if #actions > 0 then
        list[#list + 1] = actions
      end
    end
  end
  return list
end

--- Slice `i` of `n`: clockwise from 12 o'clock; direction x right, y up.
function CM.RadialSlotDir(i, n)
  local a = (i - 1) * 2 * math.pi / n
  return math.sin(a), math.cos(a)
end

function CM.RadialSlotAngle(i, n)
  return (i - 1) * 2 * math.pi / n
end

local function SpellName(id)
  if C_Spell and C_Spell.GetSpellName then
    return C_Spell.GetSpellName(id)
  end
  return _G.GetSpellInfo and (_G.GetSpellInfo(id))
end

local function SpellIcon(id)
  if C_Spell and C_Spell.GetSpellTexture then
    return (C_Spell.GetSpellTexture(id))
  end
  return _G.GetSpellTexture and (_G.GetSpellTexture(id))
end

--- name, icon (file id / path), icon text, art (radial_art_ name) for an entry; nil name when unknown.
function CM.RadialEntryInfo(entry)
  if not entry then
    return nil, nil
  end
  if entry.kind == "spell" then
    return SpellName(entry.id) or ("spell:" .. entry.id), SpellIcon(entry.id)
  elseif entry.kind == "item" then
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(entry.id)
    local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(entry.id)
    return name or ("item:" .. entry.id), icon
  elseif entry.kind == "macro" then
    local _, icon = GetMacroInfo(entry.id)
    return entry.id, icon
  elseif entry.kind == "action" then
    local action = CM.RadialActions and CM.RadialActions.byId[entry.id]
    if action then
      return action.label, action.icon, action.iconText, action.art
    end
    return entry.id, nil
  end
  return nil, nil
end

-- Slot art is Blizzard's gamepad action bar circle slot (radial_slot_{disc,border}_<state>.tga, states
-- normal / selected / disabled, plus radial_slot_shadow.tga). Discs and normal / disabled borders are
-- 64px images that fill the slot; the selected border (yellow glow) and the shadow sit on 128px canvases
-- around 80px / 88px art, so every texture is drawn at (canvas / 64) x the slot size. The icon sits just
-- under the border's body.
local SLOT_ART_PATH = "Interface\\AddOns\\CombatMode\\Assets\\radial\\radial_slot_"
local SLOT_ART_BASE = 64
local SLOT_ART_WIDE = 128
local SLOT_ICON_SCALE = 0.9
-- Blizzard's radial menu icons (Assets/radial/radial_art_<name>[_disabled].tga, 128px canvases) replace
-- the circle slot for the actions that have one; the art has a little padding, so draw it larger.
local ART_ICON_PATH = "Interface\\AddOns\\CombatMode\\Assets\\radial\\radial_art_"
local ART_ICON_SCALE = 1.35
local PLAIN_ICON_SCALE = 1.1 -- icon files without padding (the logo, game menu art), still drawn without a slot
-- Action dots: small round dots on an arc around the slot's outward side (away from the wheel's
-- centre), gold and glowing for the current one. Sizes and radii are fractions of the slot size.
-- Art: scripts/art/make-radial-dots.py.
local ACTION_PIP = {
  dotArt = "Interface\\AddOns\\CombatMode\\Assets\\radial\\radial_dot.tga",
  glowArt = "Interface\\AddOns\\CombatMode\\Assets\\radial\\radial_dot_glow.tga",
  size = 0.12, -- dot diameter
  canvas = 16 / 12, -- radial_dot.tga: canvas size over the dot's diameter
  glow = 2.4, -- glow (and shadow) canvas, in dot diameters
  radius = 0.648, -- from the slot's centre to the dot centres
  artRadius = 0.778, -- ...further out around the larger icon art
  step = math.rad(13.6), -- angle between neighbouring dots
  off = { 0.34, 0.33, 0.39 },
  on = { 1, 0.82, 0.16 },
  onGlow = { 1, 0.72, 0.1, 0.45 }, -- additive; the alpha sets its strength
  offShadow = { 0, 0, 0, 0.3 }, -- the glow art in black behind the other dots
}

--- The action dots of one slot: textures on `over`, around `host`'s centre; `size` = the slot's.
local function BuildActionPips(host, over, size)
  local pips = {}
  local dots = {} -- each with its drop shadow as dot.shadow
  local glow -- behind the lit dot, made when first needed
  local count = 0
  local dirX, dirY = 0, -1 -- the middle of the arc, from the slot's centre (y up)
  local radius = size * ACTION_PIP.radius
  local diameter = size * ACTION_PIP.size

  -- Off the pixel grid: snapping a texture this small makes its round edge step.
  local function NewTexture(sublevel, file, width)
    local tex = over:CreateTexture(nil, "OVERLAY", nil, sublevel)
    tex:SetTexture(file, "CLAMP", "CLAMP", "TRILINEAR")
    tex:SetSize(width, width)
    if tex.SetSnapToPixelGrid then
      tex:SetSnapToPixelGrid(false)
      tex:SetTexelSnappingBias(0)
    end
    return tex
  end

  local function Place()
    local middle = math.atan2(dirY, dirX)
    -- Run the dots whichever way reads left to right, or top to bottom on the sides; on the two
    -- diagonals where those disagree, top to bottom wins.
    local rightward, upward = -math.sin(middle), math.cos(middle) -- counter-clockwise from the middle
    local reading = rightward - upward
    if math.abs(reading) < 0.001 then
      reading = -upward
    end
    local turn = reading > 0 and 1 or -1
    for i = 1, count do
      local angle = middle + turn * (i - (count + 1) / 2) * ACTION_PIP.step
      dots[i]:ClearAllPoints()
      dots[i]:SetPoint("CENTER", host, "CENTER", radius * math.cos(angle), radius * math.sin(angle))
    end
  end

  --- Centres the arc on the direction `x`, `y` (y up): the slice's outward side on a wheel.
  function pips.SetDirection(x, y)
    if x ~= dirX or y ~= dirY then
      dirX, dirY = x, y
      Place()
    end
  end

  --- `fraction` of the slot size from its centre to the dots.
  function pips.SetRadius(fraction)
    if size * fraction ~= radius then
      radius = size * fraction
      Place()
    end
  end

  --- One dot per action, `current` lit; hidden below 2.
  function pips.Set(total, current)
    count = (total and total > 1) and math.min(total, LAYOUT.MAX_ACTIONS) or 0
    for i = #dots + 1, count do
      local dot = NewTexture(2, ACTION_PIP.dotArt, diameter * ACTION_PIP.canvas)
      -- Below the glow's layer, so a neighbour's shadow never dims the lit dot's glow.
      dot.shadow = NewTexture(0, ACTION_PIP.glowArt, diameter * ACTION_PIP.glow)
      dot.shadow:SetVertexColor(unpack(ACTION_PIP.offShadow))
      dot.shadow:SetPoint("CENTER", dot, "CENTER")
      dots[i] = dot
    end
    for i, dot in ipairs(dots) do
      dot:SetVertexColor(unpack(i == current and ACTION_PIP.on or ACTION_PIP.off))
      dot:SetShown(i <= count)
      dot.shadow:SetShown(i <= count and i ~= current)
    end
    Place()
    local lit = current and current <= count and dots[current]
    if lit then
      if not glow then
        glow = NewTexture(1, ACTION_PIP.glowArt, diameter * ACTION_PIP.glow)
        glow:SetBlendMode("ADD")
        glow:SetVertexColor(unpack(ACTION_PIP.onGlow))
      end
      glow:ClearAllPoints()
      glow:SetPoint("CENTER", lit, "CENTER")
    end
    if glow then
      glow:SetShown(lit and true or false)
    end
  end

  return pips
end

--- Round slot chrome shared by the wheel and the editor: shadow and disc behind, border over
--- everything. Sets host.icon (circle-masked), host.border, host.SetSlotState("normal" |
--- "selected" | "disabled") which swaps the disc / border art, host.SetSlotArt, host.SetSlotRing
--- (own frame: glow only), host.SetActionPips(count, current) and host.SetPipDirection(x, y);
--- returns a frame above the icon / cooldown for the border, labels and counts. `host` must
--- already have its size.
function CM.RadialBuildSlotChrome(host)
  local size = host:GetWidth()
  local base = size
  local wide = size * SLOT_ART_WIDE / SLOT_ART_BASE

  local shadow = host:CreateTexture(nil, "BACKGROUND", nil, -2)
  shadow:SetTexture(SLOT_ART_PATH .. "shadow.tga")
  shadow:SetSize(wide, wide)
  shadow:SetPoint("CENTER")

  local disc = host:CreateTexture(nil, "BACKGROUND", nil, -1)
  disc:SetTexture(SLOT_ART_PATH .. "disc_normal.tga")
  disc:SetSize(base, base)
  disc:SetPoint("CENTER")

  host.icon = host:CreateTexture(nil, "ARTWORK")
  host.icon:SetSize(size * SLOT_ICON_SCALE, size * SLOT_ICON_SCALE)
  host.icon:SetPoint("CENTER")
  host.iconMask = host:CreateMaskTexture()
  host.iconMask:SetAllPoints(host.icon)
  CM.SetAtlasMask(host.iconMask, "CircleMaskScalable")
  host.icon:AddMaskTexture(host.iconMask)

  local over = CreateFrame("Frame", nil, host)
  over:SetAllPoints()
  over:SetFrameLevel(host:GetFrameLevel() + 6)
  host.over = over
  host.border = over:CreateTexture(nil, "ARTWORK")
  host.border:SetTexture(SLOT_ART_PATH .. "border_normal.tga")
  host.border:SetSize(base, base)
  host.border:SetPoint("CENTER")

  -- Entries with Blizzard icon art (host.SetSlotArt) are drawn as that art alone: no disc, border or
  -- shadow, and the disabled art when unusable.
  host.art = over:CreateTexture(nil, "ARTWORK")
  host.art:SetSize(size * ART_ICON_SCALE, size * ART_ICON_SCALE)
  host.art:SetPoint("CENTER")
  host.art:Hide()

  local state = "normal"
  local artName
  local ringIcon, ringGlow
  local pips = BuildActionPips(host, over, base)
  local function Apply()
    pips.SetRadius(artName and ACTION_PIP.artRadius or ACTION_PIP.radius)
    local plain = artName == nil
    shadow:SetShown(plain and not ringIcon)
    disc:SetShown(plain)
    host.border:SetShown(plain and (not ringIcon or state == "selected"))
    host.icon:SetShown(plain)
    host.art:SetShown(not plain)
    local iconSize = ringIcon or size * SLOT_ICON_SCALE
    host.icon:SetSize(iconSize, iconSize)
    if plain and ringIcon then
      -- Ring mode: the host draws its own frame; only the selected glow is kept, sized to that frame,
      -- and the disc fills the opening so the glow doesn't show through the portrait's soft edge.
      disc:SetTexture(SLOT_ART_PATH .. "disc_normal.tga")
      disc:SetSize(iconSize, iconSize)
      host.border:SetTexture(SLOT_ART_PATH .. "border_selected.tga")
      host.border:SetSize(ringGlow, ringGlow)
    elseif plain then
      disc:SetTexture(SLOT_ART_PATH .. "disc_" .. state .. ".tga")
      disc:SetSize(base, base)
      host.border:SetTexture(SLOT_ART_PATH .. "border_" .. state .. ".tga")
      local borderSize = state == "selected" and wide or base
      host.border:SetSize(borderSize, borderSize)
    elseif artName:find("\\", 1, true) then
      -- A plain icon file (logo, game menu art): drawn alone, greyed when unusable.
      host.art:SetTexture(artName)
      host.art:SetDesaturated(state == "disabled")
      host.art:SetSize(size * PLAIN_ICON_SCALE, size * PLAIN_ICON_SCALE)
    else
      -- radial_art_<name>[_disabled].tga; a name that already ends in _disabled is always the grey art.
      local grey = state == "disabled" and not artName:find("_disabled$")
      host.art:SetTexture(ART_ICON_PATH .. artName .. (grey and "_disabled" or "") .. ".tga")
      host.art:SetDesaturated(false)
      host.art:SetSize(size * ART_ICON_SCALE, size * ART_ICON_SCALE)
    end
  end
  function host.SetSlotState(newState)
    if newState == state then
      return
    end
    state = newState
    Apply()
  end
  --- `name` = a radial_art_<name> file pair, or nil for the circle slot.
  function host.SetSlotArt(name)
    if name == artName then
      return
    end
    artName = name
    Apply()
  end
  --- Ring mode for hosts that draw their own round frame (the Party Wheel's health ring): no shadow
  --- or border, the normal disc behind the icon at `iconSize`, and only the selected glow, for a
  --- frame `frameSize` across. nil restores the circle slot.
  function host.SetSlotRing(iconSize, frameSize)
    if iconSize == ringIcon then
      return
    end
    ringIcon = iconSize
    ringGlow = frameSize and frameSize * SLOT_ART_WIDE / SLOT_ART_BASE
    Apply()
  end
  host.SetActionPips, host.SetPipDirection = pips.Set, pips.SetDirection
  return over
end

--- Paints an entry icon on a texture. The sentinel "portrait" draws the player's 2D portrait, "text" a
--- transparent icon (the slot's disc shows) with `text` written on `label` (a FontString from CM.RadialCreateIconLabel); anything else
--- is a file path / id.
function CM.RadialCreateIconLabel(parent, size)
  local label = parent:CreateFontString(nil, "OVERLAY")
  CM.ApplyOutlineSlug(label, (_G.GameFontNormalSmall:GetFont()), size)
  label:SetPoint("CENTER")
  label:SetWidth(size * 4.5)
  label:SetMaxLines(1)
  label:SetTextColor(0.95, 0.9, 0.8, 1)
  return label
end

-- Game icons (spells, items, Interface\Icons) have a bevelled square edge that the slot's full-size
-- circle mask leaves showing; they are cropped by this much per side. Addon art is drawn whole.
local GAME_ICON_TRIM = 0.08

function CM.RadialSetIcon(texture, icon, label, text)
  texture:SetTexCoord(0, 1, 0, 1)
  if label then
    label:SetText(text or "")
  end
  if icon == "text" then
    -- Transparent: the slot's disc art is the background behind the text.
    texture:SetColorTexture(0, 0, 0, 0)
  elseif icon == "portrait" then
    if _G.SetPortraitTexture then
      _G.SetPortraitTexture(texture, "player")
    end
  else
    texture:SetTexture(icon or 134400)
    if type(icon) ~= "string" or not icon:lower():find("interface\\addons\\", 1, true) then
      texture:SetTexCoord(GAME_ICON_TRIM, 1 - GAME_ICON_TRIM, GAME_ICON_TRIM, 1 - GAME_ICON_TRIM)
    end
  end
end

--- type, value, isMacroText for the slice's SecureActionButton (nil when it can't be built).
function CM.RadialEntrySecure(entry)
  if not entry then
    return nil
  end
  if entry.kind == "spell" then
    return "spell", SpellName(entry.id) or entry.id, false
  elseif entry.kind == "item" then
    return "item", "item:" .. entry.id, false
  elseif entry.kind == "macro" then
    return "macro", entry.id, false
  elseif entry.kind == "action" then
    local action = CM.RadialActions and CM.RadialActions.byId[entry.id]
    if not action then
      return nil
    end
    local text = CM.RadialActions.MacroText(action)
    if not text then
      return nil
    end
    return "macro", text, true
  end
  return nil
end
