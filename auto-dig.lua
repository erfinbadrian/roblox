-- auto-dig.lua round 4: server-reaction probes. Zero local stat writes.
-- Stand at the DIGSITE on diggable ground BEFORE executing.
-- WARNING: probe 2 may open a Robux purchase window. CLOSE it, never confirm.
-- Output: power_trace4.txt + dec_DigPowerMultiplierConfig/ShovelCatalog/EconomyConfig.lua

local RS = game:GetService("ReplicatedStorage")
local PLR = game:GetService("Players").LocalPlayer
local LOG, LASTDUMP = {}, 0

local function log(fmt, ...)
  local ok, line = pcall(string.format, fmt, ...)
  line = ok and line or tostring(fmt)
  LOG[#LOG + 1] = line
  print("[power] " .. line)
end

local function dump()
  pcall(function() writefile("power_trace4.txt", table.concat(LOG, "\n")) end)
end

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

------------------------------------------------------------ 1. extra decompiles
local roots = { RS = RS }
for _, t in ipairs({
  { "DigPowerMultiplierConfig", "RS.Shared.DigPowerMultiplierConfig" },
  { "ShovelCatalog", "RS.Shared.ShovelCatalog" },
  { "EconomyConfig", "RS.Shared.EconomyConfig" },
}) do
  pcall(function()
    local obj = roots[t[2]:sub(1, 2)]
    for seg in string.gmatch(t[2]:sub(4), "[^.]+") do obj = obj and obj[seg] end
    if obj then
      local ok, src = pcall(function() return decompile(obj) end)
      if ok and type(src) == "string" and #src > 0 then
        pcall(function() writefile("dec_" .. t[1] .. ".lua", src) end)
        log("decompiled %s (%d chars)", t[1], #src)
      else
        log("decompile FAILED %s", t[1])
      end
    else
      log("NOT FOUND %s", t[2])
    end
  end)
end

------------------------------------------------------------ 2. watchers
log("baseline: DigPower=%s tier=%s ShovelLevel=%s DigPowerPerSwing=%s",
  tostring(PLR:GetAttribute("DigPower")), tostring(PLR:GetAttribute("DigPowerMultiplierTier")),
  tostring(PLR:GetAttribute("ShovelLevel")), tostring(PLR:GetAttribute("DigPowerPerSwing")))

PLR.AttributeChanged:Connect(function(k)
  if string.find(string.lower(k), "power") or string.find(string.lower(k), "shovel")
    or k == "MobileAssistedDig" or k == "MobileDigConfigReady" then
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

local evCount = 0
local function hookEvent(remote, name)
  pcall(function()
    remote.OnClientEvent:Connect(function(...)
      evCount += 1
      if evCount <= 30 or evCount % 10 == 0 then
        local parts = {}
        for _, a in ipairs({ ... }) do parts[#parts + 1] = ser(a) end
        log("event %s #%d (%s)", name, evCount, table.concat(parts, ", "))
      end
    end)
  end)
end
hookEvent(RS.DiggingRemotes and RS.DiggingRemotes:FindFirstChild("Effect"), "Effect")
hookEvent(RS:FindFirstChild("TrainingEffect"), "TrainingEffect")

local old
old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
  local m = getnamecallmethod()
  if m == "FireServer" or m == "InvokeServer" then
    local parts = {}
    for _, a in ipairs({ ... }) do parts[#parts + 1] = ser(a) end
    log("OUT %s %s (%s)", m, self:GetFullName(), table.concat(parts, ", "))
    local now = tick()
    if now - LASTDUMP > 2 then dump() LASTDUMP = now end
  end
  return old(self, ...)
end))
log("spy armed")

------------------------------------------------------------ 3. probes
local function hrp() return PLR.Character and PLR.Character:FindFirstChild("HumanoidRootPart") end

task.delay(2, function() -- probe 1: mobile enrollment (server cannot verify device)
  pcall(function()
    RS:WaitForChild("MobileDigEnrollment"):FireServer(true, false, false)
    log("probe1: MobileDigEnrollment(true,false,false) fired")
  end)
end)

task.delay(8, function() -- probe 2: upgrade tier invoke. CLOSE any Robux popup, do not buy.
  pcall(function()
    local cur = PLR:GetAttribute("DigPowerMultiplierTier")
    log("probe2: tier=%s, invoking tier %s", tostring(cur), tostring((cur or 0) + 1))
    local ok, res = pcall(function() return RS.UpgradeDigPowerMultiplier:InvokeServer((cur or 0) + 1) end)
    log("probe2 result ok=%s res=%s", tostring(ok), ser(res))
    task.wait(2)
    local now = PLR:GetAttribute("DigPowerMultiplierTier")
    log("probe2: tier after = %s, DigPower = %s", tostring(now), tostring(PLR:GetAttribute("DigPower")))
    if now ~= cur then
      log("probe2: TIER MOVED SERVER-SIDE, escalating +10")
      local ok2, res2 = pcall(function() return RS.UpgradeDigPowerMultiplier:InvokeServer((now or 0) + 10) end)
      log("probe2 escalate res=%s", ser(res2))
    end
  end)
end)

task.delay(20, function() -- probe 3: deep Dig (position trust)
  pcall(function()
    local h = hrp() if not h then log("probe3: no character") return end
    local p = h.Position - Vector3.new(0, 25, 0)
    log("probe3: Dig deep 25 studs at %s", ser(p))
    RS.DiggingRemotes.Dig:FireServer(p, Vector3.new(0, 1, 0), Vector3.new(0, -1, 0), "Down")
    task.wait(2)
    log("probe3: DigPower now %s", tostring(PLR:GetAttribute("DigPower")))
  end)
end)

task.delay(28, function() -- probe 4: spoofed Mining stream below feet
  pcall(function()
    local h = hrp() if not h then log("probe4: no character") return end
    local p = h.Position - Vector3.new(0, 10, 0)
    local M = RS.DiggingRemotes.Mining
    log("probe4: Mining spoof at %s", ser(p))
    M:FireServer("Start", p.X, p.Y, p.Z, 0, -1, 0, "Aim")
    for _ = 1, 15 do
      task.wait(0.15)
      pcall(function() M:FireServer("Aim", p.X, p.Y, p.Z, 0, -1, 0, "Aim") end)
    end
    M:FireServer("Stop")
    log("probe4: done, DigPower = %s", tostring(PLR:GetAttribute("DigPower")))
  end)
end)

log("=== READY: stand still at the digsite, 4 probes fire over the next 30s. Close any Robux popup. ===")
task.delay(45, dump)
task.delay(90, dump)
