-- auto-dig.lua round 3: PURE INTEL. Zero writes, zero fires. Do NOT run rounds 1-2 again.
-- Steps: REJOIN the game first (clears the corrupted 1e9 state that broke digging),
-- execute THIS file, then dig 5+ times at the digsite.
-- Output: power_trace3.txt + dec_<name>.lua files in the executor workspace.

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
  pcall(function() writefile("power_trace3.txt", table.concat(LOG, "\n")) end)
end

local function ispow(s)
  s = string.lower(tostring(s))
  return s:find("power") or s:find("strength") or s:find("shovel") or s:find("dig")
end

------------------------------------------------------------ 1. decompile sweep
local roots = { PLR = PLR, RS = RS, WS = workspace }
local targets = {
  { "MiningSwing", "PLR.PlayerScripts.Client.Digging.MiningSwing" },
  { "HoldToDig", "PLR.PlayerScripts.Client.Digging.HoldToDig" },
  { "DiggingRoot", "PLR.PlayerScripts.Client.Digging" },
  { "DigPowerMultiplier", "PLR.PlayerScripts.Client.DigPowerMultiplier" },
  { "Progression", "PLR.PlayerScripts.Client.Progression" },
  { "MobileDigEligibility", "PLR.PlayerScripts.Client.Digging.MobileDigEligibility" },
  { "Shared_DigMath", "RS.Shared.DigMath" },
  { "Shared_DigStats", "RS.Shared.DigStats" },
  { "Shared_MobileDigConfig", "RS.Shared.MobileDigConfig" },
  { "Shared_ShovelPowerCompensation", "RS.Shared.ShovelPowerCompensation" },
  { "Cmdr_setdigpower", "RS.CmdrClient.Commands.setdigpower" },
}
for _, t in ipairs(targets) do
  pcall(function()
    local rootName, rest = string.match(t[2], "^(%w+)%.(.+)$")
    local obj = roots[rootName]
    for seg in string.gmatch(rest, "[^.]+") do obj = obj and obj[seg] end
    if not obj then log("NOT FOUND %s", t[2]) return end
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
  if ispow(k) or k == "AdminShovelOwned" or k == "VerifiedDigPower" then
    log("attr %s -> %s", k, tostring(PLR:GetAttribute(k)))
  end
end)
local ls = PLR:FindFirstChild("leaderstats")
if ls then
  for _, v in ipairs(ls:GetChildren()) do
    if v:IsA("NumberValue") or v:IsA("IntValue") then
      v.Changed:Connect(function(n) log("leaderstats.%s -> %s", v.Name, tostring(n)) end)
    end
  end
end

------------------------------------------------------------ 3. remote spy, log only
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

local mining = { Start = 0, Aim = 0, Stop = 0, other = 0 }
local old
old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
  local m = getnamecallmethod()
  if m == "FireServer" or m == "InvokeServer" then
    local args = { ... }
    local parts = {}
    for _, a in ipairs(args) do parts[#parts + 1] = ser(a) end
    log("remote %s %s (%s)", m, self:GetFullName(), table.concat(parts, ", "))
    if self.Parent == RS:FindFirstChild("DiggingRemotes") and type(args[1]) == "string" then
      mining[args[1]] = (mining[args[1]] or 0) + 1
    end
    local now = tick()
    if now - LASTDUMP > 2 then dump() LASTDUMP = now end
  end
  return old(self, ...)
end))
log("spy armed (log only, no mutation)")

log("=== READY: dig 5+ times at the digsite NOW ===")
task.delay(60, function() log("mining counts: Start=%d Aim=%d Stop=%d other=%d", mining.Start, mining.Aim, mining.Stop, mining.other) dump() end)
task.delay(180, dump)
