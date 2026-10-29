-- auto-dig.lua: auto-digger bot. Swings at TRUE legal cooldown (DigStats if requirable,
-- else a conservative 0.45s), digs straight down, recovers from boundaries, AFK cycles.
-- Run: join the game, execute once. Stop: rejoin, or run getgenv().DIG_STOP = true
-- Log: dig_farm_log.txt (boots, method choice, stalls, 5min rates)

local RS = game:GetService("ReplicatedStorage")
local PLR = game:GetService("Players").LocalPlayer

getgenv().DIG_STOP = false

local function raw(line)
  pcall(function() writefile("dig_farm_log.txt", line) end)
  print("[digger] " .. line)
end
raw("boot " .. os.date("%m-%d %H:%M:%S") .. " assist=" .. tostring(PLR:GetAttribute("MobileAssistedDig")))

local okDS, DigStats = pcall(function()
  return require(RS:WaitForChild("Shared"):WaitForChild("DigStats"))
end)
raw("DigStats require " .. (okDS and "ok" or "FAILED, using 0.45 fallback"))

local okR, M, D, S = pcall(function()
  local R = RS:WaitForChild("DiggingRemotes")
  return R:WaitForChild("Mining"), R:WaitForChild("Dig"), R:WaitForChild("Surface")
end)
if not okR then raw("REMOTES FAILED: " .. tostring(M)) return end

local function slog(line)
  pcall(function()
    local lines = {}
    local f = readfile("dig_farm_log.txt")
    if f then for l in string.gmatch(f, "[^\n]+") do lines[#lines + 1] = l end end
    lines[#lines + 1] = os.date("%m-%d %H:%M:%S ") .. line
    if #lines > 300 then lines = table.move(lines, #lines - 299, #lines, 1, {}) end
    writefile("dig_farm_log.txt", table.concat(lines, "\n"))
  end)
  print("[digger] " .. line)
end

local hits = 0
pcall(function()
  RS.DiggingRemotes.Effect.OnClientEvent:Connect(function(p)
    if p == PLR then hits += 1 end
  end)
end)

local function hrp() return PLR.Character and PLR.Character:FindFirstChild("HumanoidRootPart") end

-- ponytail: pcall per call; if the module dies in this executor, 0.45 is EconomyConfig's base cooldown
local function cooldown()
  local okc, v = pcall(function() return DigStats.cooldown(PLR) end)
  if okc and type(v) == "number" and v >= 0.05 then return v end
  return 0.45
end

local function swingDown()
  local h = hrp() if not h then return end
  local p = h.Position - Vector3.new(0, 8, 0)
  D:FireServer(p, Vector3.new(0, 1, 0), Vector3.new(0, -1, 0), "Down")
end

local function swingStream()
  local h = hrp() if not h then return end
  local p = h.Position - Vector3.new(0, 8, 0)
  M:FireServer("Start", p.X, p.Y, p.Z, 0, -1, 0, "Aim")
  M:FireServer("Aim", p.X, p.Y, p.Z, 0, -1, 0, "Aim")
  task.wait(0.1)
  M:FireServer("Stop")
end

local function measure(swing, seconds)
  local before, t0 = hits, os.clock()
  while os.clock() - t0 < seconds do
    pcall(swing)
    task.wait(cooldown() + 0.03)
  end
  return hits - before
end

local cycleCount = 0
task.spawn(function()
  task.wait(2)
  while not getgenv().DIG_STOP do
    while true do
      local h, hum = hrp(), PLR.Character and PLR.Character:FindFirstChildOfClass("Humanoid")
      if h and hum and hum.Health > 0 then break end
      task.wait(1)
    end

    local a = measure(swingDown, 15)
    local b = measure(swingStream, 15)
    local swing = (a >= b) and swingDown or swingStream
    slog(string.format("method=%s (Down:%d Stream:%d) power=%s",
      swing == swingDown and "Down" or "Stream", a, b, tostring(PLR:GetAttribute("DigPower"))))

    local lastHits, stalls = hits, 0
    while not getgenv().DIG_STOP and hrp() do
      pcall(swing)
      task.wait(cooldown() + 0.03)
      if hits > lastHits then
        lastHits, stalls = hits, 0
      else
        stalls += 1
        if stalls * (cooldown() + 0.03) > 15 then
          stalls = 0
          lastHits = hits
          slog(string.format("stall at y=%.0f hits=%d power=%s, rotating site",
            hrp() and hrp().Position.Y or 0, hits, tostring(PLR:GetAttribute("DigPower"))))
          S:FireServer("DigSite")
          task.wait(4)
          local h = hrp()
          if h then h.CFrame = h.CFrame + Vector3.new(math.random(-36, 36), 0, math.random(-36, 36)) end
          cycleCount += 1
          if cycleCount % 3 == 0 then
            slog("AFK cycle: home 4min")
            S:FireServer("Home")
            task.wait(240)
            S:FireServer("DigSite")
            task.wait(4)
          end
        end
      end
    end
    task.wait(2)
  end
end)

task.spawn(function()
  local lastP, lastH = PLR:GetAttribute("DigPower") or 0, 0
  while true do
    task.wait(300)
    local p = PLR:GetAttribute("DigPower") or 0
    slog(string.format("5min power=%s (+%d) blocks=%d (+%d)",
      tostring(p), p - lastP, hits, hits - lastH))
    lastP, lastH = p, hits
  end
end)

slog("bot loaded")
