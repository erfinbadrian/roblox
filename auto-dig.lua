-- auto-dig.lua v3: AFK-first power farm. The plot AFK zone is the power engine
-- (+~645/tick); digging only produces loot/cash. So: sit on the plot 25min, dig 5min, repeat.
-- Single instance: executing twice does nothing. Stop: rejoin, or getgenv().DIG_STOP = true
-- Log: dig_farm_log.txt

local RS = game:GetService("ReplicatedStorage")
local PLR = game:GetService("Players").LocalPlayer

-- duplicate guard: refuse only if another instance pinged recently (dead loops go stale)
local now = os.clock()
if getgenv().DIG_PING and now - getgenv().DIG_PING < 30 then
  print("[digger] already running (ping fresh), refusing duplicate")
  return
end
getgenv().DIG_PING = now -- stamp immediately: closes the rapid-execute window
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

local okEC, Economy = pcall(function()
  return require(RS:WaitForChild("Shared"):WaitForChild("EconomyConfig"))
end)

local function cooldown()
  local okc, v = pcall(function() return DigStats.cooldown(PLR) end)
  -- ponytail: legal cooldowns dip under 0.05 with fast shovels/potions; only reject NaN/inf/absurd
  if okc and type(v) == "number" and v == v and v > 0.005 and v < 10 then return v end
  return 0.45
end

-- expected seconds to break one block at frontier depth with current stats
local function blockExpected()
  local ok, t = pcall(function()
    local depth = -hrp().Position.Y
    local stages = Economy.Stages
    local health = stages[#stages].Health
    for _, s in ipairs(stages) do
      if depth <= s.Depth then health = s.Health break end
    end
    return math.min(health / math.max(DigStats.damage(PLR), 1) * cooldown() * 1.5 + 5, 300)
  end)
  if ok and type(t) == "number" and t == t then return t end
  return 60
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
      getgenv().DIG_PING = os.clock()
      -- active swing: ~60x the passive zone rate; game enforces its own cooldown server-side
      local ok = pcall(function() game:GetService("VirtualUser"):Button1Hold() end)
      if ok then
        task.wait(0.3)
        pcall(function() game:GetService("VirtualUser"):Button1Release() end)
      else
        local pos = game:GetService("UserInputService"):GetMouseLocation()
        pcall(function()
          game:GetService("VirtualInputManager"):SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
        end)
        task.wait(0.25)
        pcall(function()
          game:GetService("VirtualInputManager"):SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
        end)
      end
      task.wait(0.05)
      if not hrp() then task.wait(3) if hrp() then S:FireServer("Home") moveToAfkZone() end end
    end
    if getgenv().DIG_STOP then break end
    slog(string.format("AFK done power=%s (+%d)", tostring(PLR:GetAttribute("DigPower")),
      (PLR:GetAttribute("DigPower") or 0) - p0))

    -- dig phase: loot + cash
    S:FireServer("DigSite")
    task.wait(4)
    local anchor = hrp() and hrp().Position or nil
    if not swing then
      -- alternate short windows so both methods see the same depth range; Stream must strictly win
      local aTot, bTot = 0, 0
      for _ = 1, 6 do
        aTot += measure(swingDown, 5)
        bTot += measure(swingStream, 5)
      end
      swing = (bTot > aTot) and swingStream or swingDown
      slog(string.format("method=%s (Down:%d Stream:%d)",
        swing == swingDown and "Down" or "Stream", aTot, bTot))
    end
    local h0, d0, lastHit = hits, os.clock(), os.clock()
    while os.clock() - d0 < DIG_MIN * 60 and not getgenv().DIG_STOP and hrp() do
      getgenv().DIG_PING = os.clock()
      pcall(swing)
      task.wait(cooldown() + 0.03)
      if hits > lastHit then
        lastHit = hits
      elseif os.clock() - lastHit > blockExpected() then
        lastHit = os.clock()
        local hh = hrp()
        slog(string.format("stall y=%s hits=%d, rotating",
          hh and string.format("%.0f", hh.Position.Y) or "?", hits))
        S:FireServer("DigSite")
        task.wait(4)
        local h = hrp()
        if h then
          anchor = h.Position
          local step = Vector3.new(math.random(-36, 36), 0, math.random(-36, 36))
          local target = h.Position + step
          -- clamp total drift to 20 studs from the travel anchor: random walks leave the dig zone
          local off = target - anchor
          if off.Magnitude > 20 then target = anchor + off.Unit * 20 end
          h.CFrame = CFrame.new(target)
        end
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
    if getgenv().DIG_STOP then break end
    local p = PLR:GetAttribute("DigPower") or 0
    slog(string.format("5min power=%s (+%d) blocks=%d (+%d)",
      tostring(p), p - lastP, hits, hits - lastH))
    lastP, lastH = p, hits
  end
end)

slog("bot v3 loaded (AFK-first)")
