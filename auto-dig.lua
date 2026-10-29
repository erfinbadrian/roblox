-- auto-dig.lua round 5: clean probe rerun. REJOIN FIRST, dig once with NO scripts to
-- confirm normal digging works, then stand at the digsite and execute this.
-- GUARD: aborts if the phantom 1e9 corruption is still present (means you did not rejoin).
-- WARNING: tier probe may open a Robux window. CLOSE it, never confirm.
-- Output: power_trace5.txt

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
  pcall(function() writefile("power_trace5.txt", table.concat(LOG, "\n")) end)
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

------------------------------------------------------------ guard
local dp = PLR:GetAttribute("DigPower")
local sl = PLR:GetAttribute("ShovelLevel")
if dp == 1000000000 or sl == 1000000000 then
  log("ABORT: phantom 1e9 values still present (DigPower=%s ShovelLevel=%s). REJOIN the game, dig once without scripts, then run this again.", tostring(dp), tostring(sl))
  dump()
  return
end
log("guard passed: DigPower=%s tier=%s ShovelLevel=%s", tostring(dp),
  tostring(PLR:GetAttribute("DigPowerMultiplierTier")), tostring(sl))

------------------------------------------------------------ watchers
PLR.AttributeChanged:Connect(function(k)
  local lk = string.lower(k)
  if string.find(lk, "power") or string.find(lk, "shovel")
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

local mineEffects = 0
pcall(function()
  RS.DiggingRemotes.Effect.OnClientEvent:Connect(function(...)
    mineEffects += 1
    local parts = {}
    for _, a in ipairs({ ... }) do parts[#parts + 1] = ser(a) end
    if mineEffects <= 10 or mineEffects % 10 == 0 then
      log("Effect #%d (%s)", mineEffects, table.concat(parts, ", "))
    end
  end)
end)

local old
old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
  local m = getnamecallmethod()
  if m == "FireServer" or m == "InvokeServer" then
    if self.Name == "Mining" or self.Name == "Dig" or self.Name == "MobileDigEnrollment"
      or self.Name == "UpgradeDigPowerMultiplier" then
      local parts = {}
      for _, a in ipairs({ ... }) do parts[#parts + 1] = ser(a) end
      log("OUT %s %s (%s)", m, self.Name, table.concat(parts, ", "))
    end
    local now = tick()
    if now - LASTDUMP > 2 then dump() LASTDUMP = now end
  end
  return old(self, ...)
end))
log("spy armed")

------------------------------------------------------------ probes
local function hrp() return PLR.Character and PLR.Character:FindFirstChild("HumanoidRootPart") end
local function snap(label)
  log("%s: DigPower=%s effects=%d", label, tostring(PLR:GetAttribute("DigPower")), mineEffects)
end

task.delay(3, function() -- probe 1: mobile enrollment
  pcall(function()
    snap("pre-enroll")
    RS.MobileDigEnrollment:FireServer(true, false, false)
    log("probe1 fired")
  end)
end)

task.delay(10, function() -- probe 2: tier upgrade (real tier + 1). CLOSE any Robux popup.
  pcall(function()
    local cur = PLR:GetAttribute("DigPowerMultiplierTier") or 0
    snap("pre-tier")
    log("probe2: tier=%s invoking %s", tostring(cur), tostring(math.floor(cur) + 1))
    local ok, res = pcall(function() return RS.UpgradeDigPowerMultiplier:InvokeServer(math.floor(cur) + 1) end)
    log("probe2 result ok=%s type=%s res=%s", tostring(ok), typeof(res), ser(res))
    task.wait(3)
    log("probe2 after: tier=%s DigPower=%s",
      tostring(PLR:GetAttribute("DigPowerMultiplierTier")), tostring(PLR:GetAttribute("DigPower")))
  end)
end)

task.delay(22, function() -- probe 3: deep Dig, 25 studs down
  pcall(function()
    local h = hrp() if not h then log("probe3: no character") return end
    local p = h.Position - Vector3.new(0, 25, 0)
    snap("pre-deepdig")
    log("probe3: firing Dig at %s", ser(p))
    RS.DiggingRemotes.Dig:FireServer(p, Vector3.new(0, 1, 0), Vector3.new(0, -1, 0), "Down")
    task.wait(3)
    snap("post-deepdig")
  end)
end)

task.delay(32, function() -- probe 4: spoofed Mining stream, 10 studs down
  pcall(function()
    local h = hrp() if not h then log("probe4: no character") return end
    local p = h.Position - Vector3.new(0, 10, 0)
    local M = RS.DiggingRemotes.Mining
    snap("pre-spoof")
    log("probe4: 2s spoofed stream at %s", ser(p))
    M:FireServer("Start", p.X, p.Y, p.Z, 0, -1, 0, "Aim")
    for _ = 1, 13 do
      task.wait(0.15)
      pcall(function() M:FireServer("Aim", p.X, p.Y, p.Z, 0, -1, 0, "Aim") end)
    end
    M:FireServer("Stop")
    task.wait(2)
    snap("post-spoof")
  end)
end)

log("=== READY: stand at the digsite. 4 probes over the next 35s. Close any Robux popup. ===")
task.delay(50, dump)
task.delay(100, dump)
