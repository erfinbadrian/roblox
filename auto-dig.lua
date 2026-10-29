-- auto-dig.lua: trace + probe "Power" in the digging game.
-- Round 1: find every client-side place Power lives, try inflating it, spy the dig remote.
-- Run: execute once, wait for "WRITE ATTEMPTS" section to finish, then dig ONE time.
-- Output: console + power_trace.txt in the executor workspace. Send that file back.

local PLR = game:GetService("Players").LocalPlayer
local BIG = 1e9
local LOG = {}
local LASTLINE, LASTLINE_T, LASTDUMP = "", 0, 0

local function log(fmt, ...)
  local ok, line = pcall(string.format, fmt, ...)
  line = ok and line or tostring(fmt)
  LOG[#LOG + 1] = line
  print("[power] " .. line)
end

local function dump()
  pcall(function() writefile("power_trace.txt", table.concat(LOG, "\n")) end)
end

local function ispow(s)
  s = string.lower(tostring(s))
  return s:find("power") or s:find("strength") or s:find("shovel") or s:find("dig")
end

local VALH, ATTRH, TBLC, UPVL = {}, {}, {}, {} -- write targets

------------------------------------------------------------ 1. snapshot
pcall(function()
  log("game: %s (place %s)", game.MarketplaceService:GetProductInfo(game.PlaceId).Name, tostring(game.PlaceId))
end)
log("player %s", tostring(PLR.Name))

local ls = PLR:FindFirstChild("leaderstats")
if ls then
  for _, v in ipairs(ls:GetChildren()) do
    local num = v:IsA("NumberValue") or v:IsA("IntValue")
    log("leaderstats %s %s = %s", v.ClassName, v.Name, num and tostring(v.Value) or "-")
    if num then
      v.Changed:Connect(function(n) log("leaderstats.%s -> %s", v.Name, tostring(n)) end)
      if ispow(v.Name) then VALH[#VALH + 1] = v end
    end
  end
end

local function attrs(o, label)
  if not o then return end
  for k, val in pairs(o:GetAttributes()) do
    if ispow(k) then
      log("%s attr %s = %s (%s)", label, k, tostring(val), typeof(val))
      if typeof(val) == "number" then ATTRH[#ATTRH + 1] = { o = o, k = k, was = val } end
    end
  end
end
attrs(PLR, "player")
attrs(PLR.Character, "character")
attrs(PLR.Character and PLR.Character:FindFirstChildOfClass("Tool"), "tool")
PLR.AttributeChanged:Connect(function(k)
  if ispow(k) then log("player attr %s -> %s", k, tostring(PLR:GetAttribute(k))) end
end)

------------------------------------------------------------ 2. instance name scan
pcall(function()
  for _, d in ipairs(game:GetDescendants()) do
    if ispow(d.Name) then
      local num = d:IsA("NumberValue") or d:IsA("IntValue")
      log("instance %s %s%s", d.ClassName, d:GetFullName(), num and (" = " .. tostring(d.Value)) or "")
      if num then VALH[#VALH + 1] = d end
    end
  end
end)

------------------------------------------------------------ 3. gc scan (functions + tables)
log("gc scan start, may take a few seconds")
pcall(function()
  for _, o in ipairs(getgc(true)) do
    local t = type(o)
    if t == "function" then
      local ok, info = pcall(debug.getinfo, o)
      if ok and info and info.what == "Lua" then
        for i = 1, 30 do
          local ok2, n, val = pcall(debug.getupvalue, o, i)
          if not ok2 or n == nil then break end
          if ispow(n) then
            log("upvalue %s = %s @ %s:%s", tostring(n), tostring(val), tostring(info.short_src), tostring(info.linedefined))
            if type(val) == "number" then UPVL[#UPVL + 1] = { f = o, i = i, n = tostring(n) } end
          end
        end
      end
    elseif t == "table" then
      pcall(function()
        for k, val in pairs(o) do
          if type(k) == "string" and ispow(k) then
            log("gc table [%s] = %s", k, tostring(val))
            if type(val) == "number" then TBLC[#TBLC + 1] = { t = o, k = k } end
          end
        end
      end)
    end
  end
end)
log("gc scan done: %d values, %d attrs, %d tables, %d upvalues", #VALH, #ATTRH, #TBLC, #UPVL)
dump()

------------------------------------------------------------ 4. remote spy
local function ser(v, d)
  d = d or 0
  local t = typeof(v)
  if t == "Instance" then return v.Name .. ":" .. v.ClassName end
  if t == "table" and d < 2 then
    local p = {}
    for k, val in pairs(v) do p[#p + 1] = tostring(k) .. "=" .. ser(val, d + 1) end
    return "{" .. table.concat(p, ",") .. "}"
  end
  return tostring(v):sub(1, 120)
end

local spyOk, spyErr = pcall(function()
  local old
  old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
    local m = getnamecallmethod()
    if m == "FireServer" or m == "InvokeServer" then
      local parts = {}
      for _, a in ipairs({ ... }) do parts[#parts + 1] = ser(a) end
      local line = ("%s %s (%s)"):format(m, self:GetFullName(), table.concat(parts, ", "))
      local now = tick()
      if line ~= LASTLINE or now - LASTLINE_T > 0.5 then
        log("remote %s", line)
        LASTLINE, LASTLINE_T = line, now
      end
      if now - LASTDUMP > 2 then dump() LASTDUMP = now end
    end
    return old(self, ...)
  end))
end)
log(spyOk and "remote spy installed" or ("remote spy FAILED: " .. tostring(spyErr)))

------------------------------------------------------------ 5. write attempts (batch, then read back)
log("=== WRITE ATTEMPTS target %g ===", BIG)
local applied = {}
for _, v in ipairs(VALH) do
  pcall(function()
    local b = v.Value
    v.Value = BIG
    applied[#applied + 1] = { "value " .. v:GetFullName(), tostring(b), function() return tostring(v.Value) end }
  end)
end
for _, h in ipairs(ATTRH) do
  pcall(function()
    h.o:SetAttribute(h.k, BIG)
    applied[#applied + 1] = { "attr " .. h.k, tostring(h.was), function() return tostring(h.o:GetAttribute(h.k)) end }
  end)
end
for _, h in ipairs(TBLC) do
  pcall(function()
    local b = h.t[h.k]
    h.t[h.k] = BIG
    applied[#applied + 1] = { "table[" .. h.k .. "]", tostring(b), function() return tostring(h.t[h.k]) end }
  end)
end
for _, h in ipairs(UPVL) do
  pcall(function()
    local _, b = debug.getupvalue(h.f, h.i)
    debug.setupvalue(h.f, h.i, BIG)
    applied[#applied + 1] = { "upvalue[" .. h.n .. "]", tostring(b), function()
      local _, n2 = debug.getupvalue(h.f, h.i)
      return tostring(n2)
    end }
  end)
end

task.wait(1.5)
for _, a in ipairs(applied) do
  pcall(function() log("%s: %s -> %g -> now %s", a[1], a[2], BIG, a[3]()) end)
end
dump()

log("=== done. DIG ONE TIME NOW, then send power_trace.txt ===")
task.delay(45, dump)
task.delay(120, dump)
