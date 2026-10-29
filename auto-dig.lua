-- auto-dig.lua round 2: read the dig code, watch REAL digs, inflate on swing 4+.
-- KEEP CURRENT SESSION (do not rejoin): the 1e9 phantom values from round 1 are the experiment.
-- Script arms everything, then YOU go to the digsite and dig 5+ times.

local RS = game:GetService("ReplicatedStorage")
local PLR = game:GetService("Players").LocalPlayer
local LOG = {}
local LASTDUMP = 0

local function log(fmt, ...)
  local ok, line = pcall(string.format, fmt, ...)
  line = ok and line or tostring(fmt)
  LOG[#LOG + 1] = line
  print("[power] " .. line)
end

local function dump()
  pcall(function() writefile("power_trace2.txt", table.concat(LOG, "\n")) end)
end

local function ispow(s)
  s = string.lower(tostring(s))
  return s:find("power") or s:find("strength") or s:find("shovel") or s:find("dig")
end

------------------------------------------------------------ 1. decompile the dig path
local scripts = {
  { "MiningSwing", "PlayerScripts.Client.Digging.MiningSwing" },
  { "HoldToDig", "PlayerScripts.Client.Digging.HoldToDig" },
  { "DigPowerMultiplier", "PlayerScripts.Client.DigPowerMultiplier" },
  { "MobileDigEligibility", "PlayerScripts.Client.Digging.MobileDigEligibility" },
  { "Shared_DigMath", "ReplicatedStorage.Shared.DigMath" },
  { "Shared_ShovelPowerCompensation", "ReplicatedStorage.Shared.ShovelPowerCompensation" },
}
for _, t in ipairs(scripts) do
  pcall(function()
    local obj = game
    for seg in string.gmatch(t[2], "[^.]+") do obj = obj[seg] end
    local ok, src = pcall(function() return decompile(obj) end)
    if ok and type(src) == "string" and #src > 0 then
      pcall(function() writefile("dec_" .. t[1] .. ".lua", src) end)
      log("decompiled %s (%d chars)", t[1], #src)
    else
      log("decompile FAILED %s: %s", t[1], tostring(src))
    end
  end)
end
dump()

------------------------------------------------------------ 2. watchers
PLR.AttributeChanged:Connect(function(k)
  if ispow(k) or k == "AdminShovelOwned" then log("attr %s -> %s", k, tostring(PLR:GetAttribute(k))) end
end)
local ls = PLR:FindFirstChild("leaderstats")
if ls then
  for _, v in ipairs(ls:GetChildren()) do
    if v:IsA("NumberValue") or v:IsA("IntValue") then
      v.Changed:Connect(function(n) log("leaderstats.%s -> %s", v.Name, tostring(n)) end)
    end
  end
end

------------------------------------------------------------ 3. remote spy: log everything, inflate Dig args after 3 clean swings
local DIG = RS:FindFirstChild("DiggingRemotes") and RS.DiggingRemotes:FindFirstChild("Dig")
if not DIG then log("WARN: Dig remote not found") end
local digCount, X = 0, 1000

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

local old
old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
  local m = getnamecallmethod()
  if m == "FireServer" or m == "InvokeServer" then
    local args = { ... }
    local parts = {}
    for _, a in ipairs(args) do parts[#parts + 1] = ser(a) end
    log("remote %s %s (%s)", m, self:GetFullName(), table.concat(parts, ", "))
    if self == DIG and m == "FireServer" then
      digCount += 1
      if digCount > 3 then
        local mut, p = {}, {}
        for i, a in ipairs(args) do
          -- ponytail: coords are small ints, power values run 500+, may inflate a coord and fail a dig, the log shows it
          mut[i] = (type(a) == "number" and a >= 500 and a < 1e12) and a * X or a
          p[#p + 1] = ser(mut[i])
        end
        log("INFLATED dig #%d x%d -> (%s)", digCount, X, table.concat(p, ", "))
        local now = tick()
        if now - LASTDUMP > 2 then dump() LASTDUMP = now end
        return old(self, table.unpack(mut))
      end
    end
    local now = tick()
    if now - LASTDUMP > 2 then dump() LASTDUMP = now end
  end
  return old(self, ...)
end))
log("spy armed. Dig remote = %s", DIG and DIG:GetFullName() or "nil")

------------------------------------------------------------ 4. admin shovel probe
task.delay(3, function()
  pcall(function()
    local prompt
    for _, d in ipairs(workspace:GetDescendants()) do
      if d:IsA("ProximityPrompt") and string.find(d.Name, "AdminShovel") then prompt = d break end
    end
    if prompt then
      log("firing %s", prompt:GetFullName())
      fireproximityprompt(prompt)
      task.wait(2)
      log("AdminShovelOwned after fire = %s", tostring(PLR:GetAttribute("AdminShovelOwned")))
    else
      log("no AdminShovel prompt found")
    end
  end)
end)

log("=== READY: go to the DIGSITE and dig 5+ times NOW (not the AFK plot) ===")
task.delay(60, dump)
task.delay(180, dump)
