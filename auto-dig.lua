-- auto-dig.lua v3: AFK-first power farm. The plot AFK zone is the power engine
-- (+~645/tick); digging only produces loot/cash. So: sit on the plot 25min, dig 5min, repeat.
-- Single instance: executing twice does nothing. Stop: rejoin, or getgenv().DIG_STOP = true
-- Log: dig_farm_log.txt

local RS = game:GetService("ReplicatedStorage")
local PLR = game:GetService("Players").LocalPlayer

if getgenv().DIG_BOT then
  print("[digger] already running, refusing duplicate")
  return
end
getgenv().DIG_BOT = true
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

-- after Home travel, stand on the nearest AfkShovelZone (own plot)
local function moveToAfkZone()
  pcall(function()
    local h = hrp() if not h then return end
    local best, bd = nil, 1e9
    for _, d in ipairs(workspace:GetDescendants()) do
      if d:IsA("Model") and d.Name == "AfkShovelZone" then
        local p = d:FindFirstChildWhichIsA("BasePart", true)
        if p then
          local dist = (p.Position - h.Position).Magnitude
          if dist < bd then bd, best = dist, p end
        end
      end
    end
    if best and bd < 300 then
      h.CFrame = CFrame.new(best.Position + Vector3.new(0, 4, 0))
      slog("on AFK zone")
    else
      slog("no AFK zone found nearby, staying put")
    end
  end)
end

local AFK_MIN, DIG_MIN = 25, 5
local swing = nil

task.spawn(function()
  task.wait(2)
  while not getgenv().DIG_STOP do
    while true do
      local h, hum = hrp(), PLR.Character and PLR.Character:FindFirstChildOfClass("Humanoid")
      if h and hum and hum.Health > 0 then break end
      task.wait(1)
    end

    -- AFK phase: the power engine
    S:FireServer("Home")
    task.wait(3)
    moveToAfkZone()
    local p0 = PLR:GetAttribute("DigPower") or 0
    slog(string.format("AFK %dmin start power=%s", AFK_MIN, tostring(p0)))
    local t0 = os.clock()
    while os.clock() - t0 < AFK_MIN * 60 and not getgenv().DIG_STOP do
      task.wait(10)
      if not hrp() then task.wait(3) if hrp() then S:FireServer("Home") moveToAfkZone() end end
    end
    if getgenv().DIG_STOP then break end
    slog(string.format("AFK done power=%s (+%d)", tostring(PLR:GetAttribute("DigPower")),
      (PLR:GetAttribute("DigPower") or 0) - p0))

    -- dig phase: loot + cash
    S:FireServer("DigSite")
    task.wait(4)
    if not swing then
      local a = measure(swingDown, 15)
      local b = measure(swingStream, 15)
      swing = (a >= b) and swingDown or swingStream
      slog(string.format("method=%s (Down:%d Stream:%d)",
        swing == swingDown and "Down" or "Stream", a, b))
    end
    local h0, d0, lastHit = hits, os.clock(), os.clock()
    while os.clock() - d0 < DIG_MIN * 60 and not getgenv().DIG_STOP and hrp() do
      pcall(swing)
      task.wait(cooldown() + 0.03)
      if hits > lastHit then
        lastHit = hits
      elseif os.clock() - lastHit > 12 then
        lastHit = os.clock()
        slog(string.format("stall y=%.0f hits=%d, rotating", hrp().Position.Y, hits))
        S:FireServer("DigSite")
        task.wait(4)
        local h = hrp()
        if h then h.CFrame = h.CFrame + Vector3.new(math.random(-36, 36), 0, math.random(-36, 36)) end
      end
    end
    slog(string.format("dig done blocks=%d power=%s", hits - h0, tostring(PLR:GetAttribute("DigPower"))))
  end
  slog("bot stopped")
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

slog("bot v3 loaded (AFK-first)")
