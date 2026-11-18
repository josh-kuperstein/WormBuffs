-- WormBuffs: loud, clickable "you are missing X" icons for your own buffs.
-- Built around WoW Forever's addon rules: auras can't be read in combat, and
-- secure (click-to-cast) buttons can't be changed in combat. So all checks run
-- out of combat; during a fight the icons freeze as they were at the pull and
-- refresh the moment combat ends.

local ADDON_NAME = ...
local PREFIX = "|cff9d7a4fWormBuffs|r: "

local SIZE, GAP = 56, 60          -- icon size and gap between icons
local MAX_ICONS = 8

-- Each entry is satisfied if ANY of its names is on you. Entries only apply if
-- you know at least one of the spells, so these lists are safe to over-fill.
--
-- A "weapon" entry is a temporary enchant on your main hand instead of a buff.
-- `create` is the spell that makes the item; the entry applies if you know it.
-- Only a temporary enchant whose name contains names[1] counts, so a weapon
-- oil or a permanent enchant doesn't hide a missing spellstone.
--
-- `since` marks defaults added after 1.0. Characters that already have saved
-- settings get those entries added once, on their next login.
local DEFAULTS_REV = 2
local CLASS_DEFAULTS = {
  WARLOCK = {
    { names = { "Demon Armor", "Demon Skin" } },
    { names = { "Soul Link" }, needsPet = true },
    { names = { "Spellstone" }, weapon = true, create = "Create Spellstone", since = 2 },
  },
  MAGE = {
    { names = { "Arcane Intellect", "Arcane Brilliance" } },
    { names = { "Mage Armor", "Ice Armor", "Frost Armor" } },
  },
  PRIEST = {
    { names = { "Power Word: Fortitude", "Prayer of Fortitude" } },
    { names = { "Inner Fire" } },
  },
  DRUID = {
    { names = { "Mark of the Wild", "Gift of the Wild" } },
  },
  WARRIOR = {
    { names = { "Battle Shout" } },
  },
}

local db
local anchor
local icons = {}
local lastMissing = {}
local testMode = false
local pendingUpdate = false
local updateQueued = false

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg) end

local function CopyEntries(src)
  local out = {}
  for i, e in ipairs(src or {}) do
    local names = {}
    for j, n in ipairs(e.names) do names[j] = n end
    out[i] = { names = names, needsPet = e.needsPet or nil, weapon = e.weapon or nil, create = e.create }
  end
  return out
end

------------------------------------------------------------------------
-- Game lookups
------------------------------------------------------------------------

-- Returns spell info if the player knows a spell by this name, else nil.
local function KnownSpell(name)
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(name)
    if info and info.spellID then
      if IsPlayerSpell then
        local ok, known = pcall(IsPlayerSpell, info.spellID)
        if ok and known == false then return nil end
      end
      return info
    end
  end
  return nil
end

-- true = buff present, false = missing, nil = can't tell right now (secret/unavailable)
local function HasBuff(name)
  if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
    local ok, data = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", name, "HELPFUL")
    if not ok then return nil end
    if data == nil then return false end
    if issecretvalue and issecretvalue(data) then return nil end
    return true
  elseif AuraUtil and AuraUtil.FindAuraByName then
    local ok, found = pcall(AuraUtil.FindAuraByName, name, "player", "HELPFUL")
    if not ok then return nil end
    return found ~= nil
  end
  return nil
end

local MAIN_HAND = 16

-- Checks the main hand for a temporary enchant whose name contains `text`.
-- GetWeaponEnchantInfo only says whether *some* temporary enchant is there
-- (permanent enchants never count), so the name comes from the weapon's
-- tooltip, where it shows as a line like "Grand Spellstone (59 min)". That
-- keeps weapon oils and other stones from passing as a spellstone.
-- Returns true/false, or nil + reason when it can't tell. Also returns what it
-- saw, for /wbuffs debug.
local function MainHandHasEnchant(text)
  if not GetWeaponEnchantInfo then return nil, "GetWeaponEnchantInfo missing" end
  local ok, has, _, _, enchantID = pcall(GetWeaponEnchantInfo)
  if not ok then return nil, "GetWeaponEnchantInfo failed" end
  if issecretvalue and (issecretvalue(has) or issecretvalue(enchantID)) then return nil, "hidden right now" end
  if not has then return false, "no temporary enchant" end

  if not (C_TooltipInfo and C_TooltipInfo.GetInventoryItem) then return nil, "C_TooltipInfo missing" end
  local okTip, data = pcall(C_TooltipInfo.GetInventoryItem, "player", MAIN_HAND)
  if not okTip or not data or not data.lines then return nil, "couldn't read weapon tooltip" end
  for _, line in ipairs(data.lines) do
    local t = line.leftText
    if t and issecretvalue and issecretvalue(t) then return nil, "hidden right now" end
    -- The enchant line ends in a duration in parentheses; the weapon's own
    -- name and stats don't, so a weapon called "...Spellstone..." won't match.
    if t and t:find(text, 1, true) and t:find("%(.+%)%s*$") then
      return true, string.format("found \"%s\" (enchant %s)", t, tostring(enchantID))
    end
  end
  return false, "temporary enchant " .. tostring(enchantID) .. " isn't a " .. text
end

-- Finds a bag item whose name contains `text`. Returns its name and icon.
local function FindBagItem(text)
  if not (C_Container and C_Container.GetContainerNumSlots) then return nil end
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      local name = info and info.hyperlink and info.hyperlink:match("%[(.-)%]")
      if name and name:find(text, 1, true) then return name, info.iconFileID end
    end
  end
  return nil
end

-- Weapon entries: clicking applies the stone if you have one, else makes one.
local function EvaluateWeapon(entry)
  local createInfo = KnownSpell(entry.create)
  if not createInfo then return "notknown" end
  if not GetInventoryItemID("player", MAIN_HAND) then return "notknown" end  -- nothing to put it on
  local has = MainHandHasEnchant(entry.names[1])
  if has == nil then return "unknown" end
  if has then return "ok" end

  local stone, stoneIcon = FindBagItem(entry.names[1])
  local item = { name = entry.names[1], icon = stoneIcon or createInfo.iconID }
  if stone then
    item.macrotext = "/use " .. stone .. "\n/use " .. MAIN_HAND
    item.tip = "Click to put " .. stone .. " on your weapon."
  else
    item.spell = createInfo.name
    item.tip = "None in your bags. Click to make one, then click again."
  end
  return "missing", item
end

-- status: "ok" | "missing" | "notknown" | "unknown"; plus what to show/cast
local function Evaluate(entry)
  if entry.weapon then return EvaluateWeapon(entry) end
  local castInfo
  for _, n in ipairs(entry.names) do
    local info = KnownSpell(n)
    if info and not castInfo then castInfo = info end
  end
  if not castInfo then return "notknown" end

  for _, n in ipairs(entry.names) do
    local info = KnownSpell(n)
    local has = HasBuff(info and info.name or n)
    if has == nil then return "unknown" end
    if has then return "ok" end
  end
  return "missing", { name = castInfo.name, icon = castInfo.iconID, spell = castInfo.name }
end

------------------------------------------------------------------------
-- Display
------------------------------------------------------------------------

local function SavePosition()
  local p, _, rp, x, y = anchor:GetPoint()
  db.point = { p, rp, x, y }
end

local function ApplyPosition()
  anchor:ClearAllPoints()
  local pt = db.point
  if pt then
    anchor:SetPoint(pt[1], UIParent, pt[2], pt[3], pt[4])
  else
    anchor:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
  end
  anchor:SetScale(db.scale or 1)
end

local function ShowTooltip(self)
  if not self.spellName then return end
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
  GameTooltip:AddLine("Missing: " .. self.spellName, 1, 0.3, 0.3)
  if self.noPet then
    GameTooltip:AddLine("Summon a demon first.", 1, 1, 1)
  else
    GameTooltip:AddLine(self.tip or "Click to cast.", 1, 1, 1)
  end
  GameTooltip:Show()
end

local function CreateIcon(i)
  local b = CreateFrame("Button", "WormBuffsIcon" .. i, anchor, "SecureActionButtonTemplate")
  b:SetSize(SIZE, SIZE)
  b:RegisterForClicks("AnyUp", "AnyDown")
  b:SetAttribute("type", "spell")

  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetColorTexture(0, 0, 0, 0.9)
  bg:SetPoint("TOPLEFT", -2, 2)
  bg:SetPoint("BOTTOMRIGHT", 2, -2)

  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetAllPoints()
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  b.glow = b:CreateTexture(nil, "OVERLAY")
  b.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
  b.glow:SetBlendMode("ADD")
  b.glow:SetVertexColor(1, 0.15, 0.15)
  b.glow:SetPoint("CENTER")
  b.glow:SetSize(SIZE * 1.9, SIZE * 1.9)
  local ag = b.glow:CreateAnimationGroup()
  ag:SetLooping("BOUNCE")
  local a = ag:CreateAnimation("Alpha")
  a:SetFromAlpha(1)
  a:SetToAlpha(0.15)
  a:SetDuration(0.55)
  ag:Play()

  b.label = b:CreateFontString(nil, "OVERLAY")
  b.label:SetFont(STANDARD_TEXT_FONT, 15, "OUTLINE")
  b.label:SetPoint("TOP", b, "BOTTOM", 0, -6)
  b.label:SetWidth(SIZE + GAP - 4)
  b.label:SetTextColor(1, 0.25, 0.25)

  b:SetScript("OnEnter", ShowTooltip)
  b:SetScript("OnLeave", GameTooltip_Hide)
  b:Hide()
  icons[i] = b
  return b
end

-- list: array of { name=, icon=, noPet=, spell= or macrotext=, tip= }
local function Render(list)
  if InCombatLockdown() then pendingUpdate = true return end
  local n = math.min(#list, MAX_ICONS)
  local total = n * SIZE + math.max(n - 1, 0) * GAP
  for i = 1, math.max(n, #icons) do
    local b = icons[i] or (i <= n and CreateIcon(i))
    if b then
      local item = list[i]
      if i <= n and item then
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", anchor, "TOP", -total / 2 + (i - 1) * (SIZE + GAP), -4)
        b.icon:SetTexture(item.icon or 134400)
        b.icon:SetDesaturated(item.noPet and true or false)
        b.spellName = item.name
        b.noPet = item.noPet
        b.tip = item.tip
        local live = not testMode and not item.noPet
        if live and item.macrotext then
          b:SetAttribute("type", "macro")
          b:SetAttribute("macrotext", item.macrotext)
          b:SetAttribute("spell", nil)
        else
          b:SetAttribute("type", "spell")
          b:SetAttribute("spell", live and item.spell or nil)
          b:SetAttribute("macrotext", nil)
        end
        b.label:SetText("MISSING\n" .. string.upper(item.name) .. (item.noPet and "\n|cffffffff(no pet)|r" or ""))
        b:EnableMouse(db.locked)
        b:Show()
      else
        b:Hide()
        b.spellName = nil
      end
    end
  end
end

-- What each entry showed last time, so an entry the game won't answer for
-- right now keeps its icon (or lack of one) instead of guessing.
local lastShown = {}

local function Collect()
  local list = {}
  local shown = {}
  for _, entry in ipairs(db.watch) do
    if testMode then
      local info = KnownSpell(entry.create or entry.names[1])
      table.insert(list, { name = entry.weapon and entry.names[1] or (info and info.name) or entry.names[1],
        icon = info and info.iconID })
    else
      local status, item = Evaluate(entry)
      if status == "unknown" then
        item = lastShown[entry]
      elseif status ~= "missing" then
        item = nil
      elseif entry.needsPet and not UnitExists("pet") then
        item.noPet = true
      end
      shown[entry] = item
      if item then table.insert(list, item) end
    end
  end
  if not testMode then lastShown = shown end
  return list
end

local function Update()
  updateQueued = false
  if not db then return end
  if InCombatLockdown() then pendingUpdate = true return end
  pendingUpdate = false

  if not testMode and (UnitIsDeadOrGhost("player") or UnitOnTaxi("player")
      or (UnitInVehicle and UnitInVehicle("player"))) then
    Render({})
    wipe(lastMissing)
    return
  end

  local list = Collect()
  if not list then return end

  if db.sound and not testMode then
    local newOne = false
    local now = {}
    for _, item in ipairs(list) do
      now[item.name] = true
      if not lastMissing[item.name] then newOne = true end
    end
    if newOne and SOUNDKIT then PlaySound(SOUNDKIT.RAID_WARNING, "Master") end
    lastMissing = now
  end

  Render(list)
end

local function QueueUpdate()
  if updateQueued then return end
  updateQueued = true
  C_Timer.After(0.25, Update)
end

local function SetLocked(locked)
  if InCombatLockdown() then Print("Can't move things in combat.") return end
  db.locked = locked
  anchor:EnableMouse(not locked)
  anchor.handle:SetShown(not locked)
  anchor.handleText:SetShown(not locked)
  testMode = not locked
  Update()
end

------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------

local function CreateAnchor()
  anchor = CreateFrame("Frame", "WormBuffsAnchor", UIParent)
  anchor:SetSize(SIZE * 4 + GAP * 3, SIZE + 60)
  anchor:SetMovable(true)
  anchor:SetClampedToScreen(true)
  anchor:RegisterForDrag("LeftButton")
  anchor:SetScript("OnDragStart", function(self) if not InCombatLockdown() then self:StartMoving() end end)
  anchor:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() SavePosition() end)

  local h = anchor:CreateTexture(nil, "BACKGROUND")
  h:SetAllPoints()
  h:SetColorTexture(0.6, 0.45, 0.3, 0.35)
  anchor.handle = h
  local t = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  t:SetPoint("BOTTOM", anchor, "TOP", 0, 2)
  t:SetText("WormBuffs: drag to move, /wbuffs lock when done")
  anchor.handleText = t
  h:Hide(); t:Hide()
  ApplyPosition()
end

local function InitDB()
  WormBuffsCharDB = WormBuffsCharDB or {}
  db = WormBuffsCharDB
  local _, class = UnitClass("player")
  if db.watch == nil then
    db.watch = CopyEntries(CLASS_DEFAULTS[class])
  else
    -- Saved settings from an older version: add any defaults newer than them,
    -- once. A later /wbuffs remove sticks because the rev is saved.
    local rev = db.defaultsRev or 1
    local added = {}
    for _, e in ipairs(CLASS_DEFAULTS[class] or {}) do
      if (e.since or 1) > rev then
        table.insert(db.watch, CopyEntries({ e })[1])
        table.insert(added, e.names[1])
      end
    end
    if #added > 0 then
      C_Timer.After(5, function() Print("Now also watching: " .. table.concat(added, ", ") .. ". /wbuffs list to see all.") end)
    end
  end
  db.defaultsRev = DEFAULTS_REV
  if db.locked == nil then db.locked = true end
  if db.sound == nil then db.sound = true end
  db.scale = db.scale or 1
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

local function Trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function ListWatch()
  if #db.watch == 0 then Print("Not watching anything. Add one with /wbuffs add <spell name>") return end
  Print("Watching:")
  for i, e in ipairs(db.watch) do
    DEFAULT_CHAT_FRAME:AddMessage(string.format("  %d. %s%s", i, table.concat(e.names, " or "),
      (e.needsPet and " |cff888888(needs pet)|r" or "") .. (e.weapon and " |cff888888(on weapon)|r" or "")))
  end
end

local function Debug()
  if InCombatLockdown() then Print("Auras are hidden from addons in combat; try again after.") return end
  Print("Debug:")
  for i, e in ipairs(db.watch) do
    local status = Evaluate(e)
    local parts = {}
    if e.weapon then
      local has, why = MainHandHasEnchant(e.names[1])
      local stone = FindBagItem(e.names[1])
      table.insert(parts, string.format("%s [%s known:%s weapon:%s on weapon:%s (%s) in bags:%s]", e.names[1],
        e.create, KnownSpell(e.create) and "yes" or "no",
        GetInventoryItemID("player", MAIN_HAND) and "yes" or "no", tostring(has), why, stone or "none"))
    end
    for _, n in ipairs(e.weapon and {} or e.names) do
      local info = KnownSpell(n)
      local has = HasBuff(info and info.name or n)
      table.insert(parts, string.format("%s [known:%s buff:%s]", n, info and "yes" or "no", tostring(has)))
    end
    DEFAULT_CHAT_FRAME:AddMessage(string.format("  %d. %s -> |cffffff00%s|r", i, table.concat(parts, ", "), status))
  end
  -- What each visible icon will actually do when clicked.
  for i, b in ipairs(icons) do
    if b:IsShown() then
      local action = b:GetAttribute("macrotext") or b:GetAttribute("spell") or "nothing"
      DEFAULT_CHAT_FRAME:AddMessage(string.format("  icon %d: %s -> click type:%s does:%s",
        i, tostring(b.spellName), tostring(b:GetAttribute("type")), (action:gsub("\n", " | "))))
    end
  end
end

local HELP = {
  "/wbuffs list: show what's being watched",
  "/wbuffs add Demon Armor, Demon Skin: add a buff (comma = either one counts)",
  "/wbuffs remove <#>: stop watching entry #",
  "/wbuffs pet <#>: toggle 'needs a pet' on entry #",
  "/wbuffs unlock / lock: move the icons (shows a preview while unlocked)",
  "/wbuffs scale <0.5-3>: icon size",
  "/wbuffs sound: toggle the raid-warning sound",
  "/wbuffs reset: restore your class defaults",
  "/wbuffs debug: show why each buff is or isn't flagged",
}

SLASH_WORMBUFFS1 = "/wbuffs"
SLASH_WORMBUFFS2 = "/wormbuffs"
SlashCmdList.WORMBUFFS = function(msg)
  msg = Trim(msg or "")
  local cmd, rest = msg:match("^(%S+)%s*(.-)$")
  cmd = cmd and cmd:lower() or ""

  if cmd == "add" and rest ~= "" then
    local names = {}
    for raw in rest:gmatch("[^,]+") do
      local n = Trim(raw)
      if n ~= "" then table.insert(names, n) end
    end
    table.insert(db.watch, { names = names })
    Print("Added: " .. table.concat(names, " or "))
    local anyKnown = false
    for _, n in ipairs(names) do if KnownSpell(n) then anyKnown = true end end
    if not anyKnown then Print("|cffff8800Heads up:|r you don't seem to know that spell, so it won't alert. Check the spelling.") end
  elseif cmd == "remove" then
    local i = tonumber(rest)
    if i and db.watch[i] then
      local e = table.remove(db.watch, i)
      Print("Removed: " .. table.concat(e.names, " or "))
    else ListWatch() end
  elseif cmd == "pet" then
    local i = tonumber(rest)
    if i and db.watch[i] then
      db.watch[i].needsPet = not db.watch[i].needsPet or nil
      Print(table.concat(db.watch[i].names, " or ") .. (db.watch[i].needsPet and " now needs a pet." or " no longer needs a pet."))
    else ListWatch() end
  elseif cmd == "list" then
    ListWatch()
  elseif cmd == "unlock" then
    SetLocked(false)
    Print("Unlocked. Drag the box, then /wbuffs lock.")
    return
  elseif cmd == "lock" then
    SetLocked(true)
    Print("Locked.")
    return
  elseif cmd == "scale" then
    local s = tonumber(rest)
    if s and s >= 0.5 and s <= 3 then
      if InCombatLockdown() then Print("Can't resize in combat.") return end
      db.scale = s
      anchor:SetScale(s)
      Print("Scale set to " .. s)
    else Print("Usage: /wbuffs scale 1.2") end
  elseif cmd == "sound" then
    db.sound = not db.sound
    Print("Sound " .. (db.sound and "on." or "off."))
  elseif cmd == "reset" then
    local _, class = UnitClass("player")
    db.watch = CopyEntries(CLASS_DEFAULTS[class])
    Print("Restored class defaults.")
    ListWatch()
  elseif cmd == "debug" then
    Debug()
    return
  else
    Print("Commands:")
    for _, line in ipairs(HELP) do DEFAULT_CHAT_FRAME:AddMessage("  " .. line) end
    return
  end
  wipe(lastMissing)
  QueueUpdate()
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, unit)
  if event == "PLAYER_LOGIN" then
    InitDB()
    CreateAnchor()
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterEvent("SPELLS_CHANGED")
    self:RegisterEvent("PLAYER_DEAD")
    self:RegisterEvent("PLAYER_ALIVE")
    self:RegisterEvent("PLAYER_UNGHOST")
    self:RegisterUnitEvent("UNIT_AURA", "player")
    self:RegisterUnitEvent("UNIT_PET", "player")
    self:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")  -- weapon enchants come and go
    self:RegisterEvent("BAG_UPDATE_DELAYED")                     -- a stone was made or used
    -- Safety net in case an aura change slips past the events.
    C_Timer.NewTicker(3, function() if not InCombatLockdown() then QueueUpdate() end end)
    QueueUpdate()
  elseif event == "PLAYER_REGEN_ENABLED" then
    if pendingUpdate then Update() else QueueUpdate() end
  else
    QueueUpdate()
  end
end)
