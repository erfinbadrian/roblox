local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
-- Queued teleport scripts can run before LocalPlayer exists, indexing it then
-- crashes on nil. PlayerAdded:Wait() covers that ultra-early join window
local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local CrystalsFolder = workspace:WaitForChild("Things"):WaitForChild("Crystals")
-- Dropped crystals (out of a player's bag) live in their own folder when it
-- exists; the reference scans it too, those items are invisible to a
-- Crystals-only scan
local DroppedCrystalsFolder = workspace:FindFirstChild("DroppedCrystals")
	or workspace:WaitForChild("DroppedCrystals", 5)
local crystalFolders = { CrystalsFolder, DroppedCrystalsFolder }

-- Mining remote (recipe from the open-source Mine a Mountain script)
local Remotes = ReplicatedStorage:FindFirstChild("Remotes") or ReplicatedStorage:WaitForChild("Remotes", 5)
local HoldComplete = Remotes and Remotes:FindFirstChild("CrystalHoldComplete")
local SellRequest = Remotes and Remotes:FindFirstChild("SellRequest")
local GoHome = Remotes and Remotes:FindFirstChild("GoHome")
local ToggleFavorite = Remotes and Remotes:FindFirstChild("ToggleFavorite")
local DigRequest = Remotes and Remotes:FindFirstChild("DigRequest")

-- Server hop: paste the raw URL of this script (e.g. your gist raw link) to auto-resume after hopping
local SCRIPT_URL = "https://raw.githubusercontent.com/erfinbadrian/roblox/refs/heads/main/auto.lua"

-- Skip if this script fully loaded seconds ago (auto-exec loader + queue_on_teleport
-- can both fire on the same join; the second run would duplicate the farm loop)
if shared.CRYSTAL_LOADED_AT and os.time() - shared.CRYSTAL_LOADED_AT < 5 then
	return
end
shared.CRYSTAL_LOADED_AT = os.time()

-- Anti-AFK so the farm survives the 20-min idle kick
local VirtualUser = game:GetService("VirtualUser")
LocalPlayer.Idled:Connect(function()
	VirtualUser:CaptureController()
	VirtualUser:ClickButton2(Vector3.new())
end)

if PlayerGui:FindFirstChild("CrystalFinderGui") then
	PlayerGui.CrystalFinderGui:Destroy()
end
if PlayerGui:FindFirstChild("CrystalTraceGui") then
	PlayerGui.CrystalTraceGui:Destroy()
end

--------------------------------------------------------------------------------
-- 1. HELPER FUNCTIONS
--------------------------------------------------------------------------------

-- Парсинг цены из любого формата ($500k, $500,000, 10t, 1qa)
local PRICE_MULTIPLIERS = { k = 1e3, m = 1e6, b = 1e9, t = 1e12, qa = 1e15 }

local function parsePrice(val)
	if not val then return 0 end
	local str = tostring(val):gsub(",", ""):lower()

	local numStr, unit = str:match("(%d+%.?%d*)%s*([a-z]*)")
	if not numStr then return 0 end

	local number = tonumber(numStr) or 0
	return number * (PRICE_MULTIPLIERS[unit] or 1)
end

-- Извлечение цены из строки ProximityPrompt (например: "[S] Peastone • 0.5kg • $500,000")
local function extractPriceFromPromptText(text)
	if not text then return 0, "" end
	
	-- Ищем часть с подписью $... (включая суффиксы t/T и qa/QA)
	local priceMatch = text:match("%$[%d%.,kKmMbBtTqQaA]+")
	if priceMatch then
		return parsePrice(priceMatch), priceMatch
	end
	
	return 0, ""
end

-- Trace overlay: print() does not reliably reach the Macsploit console, so draw
-- the last lines on screen (top-left) and also warn() them for the F9 console
local DEBUG = true
local traceLabel, traceScroll
local traceAuto = true
local traceLines = {}
local function dlog(msg)
	if not DEBUG then return end
	msg = "[CF] " .. msg
	warn(msg)
	if rconsoleprint then pcall(rconsoleprint, msg .. "\n") end
	traceLines[#traceLines + 1] = msg
	if #traceLines > 500 then table.remove(traceLines, 1) end
	if traceLabel then
		traceLabel.Text = table.concat(traceLines, "\n")
		if traceAuto and traceScroll then
			traceScroll.CanvasPosition = Vector2.new(0, 1e6)
		end
	end
	-- full log as a real file: open "Documents/Macsploit Workspace/crystal_farm_log.txt"
	if writefile then pcall(writefile, "crystal_farm_log.txt", table.concat(traceLines, "\n")) end
end

do
	local traceGui = Instance.new("ScreenGui")
	traceGui.Name = "CrystalTraceGui"
	traceGui.ResetOnSpawn = false
	traceGui.Parent = PlayerGui

	traceScroll = Instance.new("ScrollingFrame")
	traceScroll.Position = UDim2.new(0, 10, 0, 10)
	traceScroll.Size = UDim2.new(0, 460, 0, 140)
	traceScroll.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	traceScroll.BackgroundTransparency = 0.35
	traceScroll.BorderSizePixel = 0
	traceScroll.ScrollBarThickness = 4
	traceScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	traceScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	traceScroll.Parent = traceGui

	traceLabel = Instance.new("TextLabel")
	traceLabel.Size = UDim2.new(1, -8, 0, 0)
	traceLabel.BackgroundTransparency = 1
	traceLabel.TextColor3 = Color3.fromRGB(120, 255, 120)
	traceLabel.TextSize = 12
	traceLabel.Font = Enum.Font.Code
	traceLabel.TextXAlignment = Enum.TextXAlignment.Left
	traceLabel.TextYAlignment = Enum.TextYAlignment.Top
	traceLabel.TextWrapped = true
	traceLabel.AutomaticSize = Enum.AutomaticSize.Y
	traceLabel.Text = ""
	traceLabel.Parent = traceScroll

	-- auto-follow the newest line, but stop following while scrolled up
	traceScroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		local max = traceScroll.AbsoluteCanvasSize.Y - traceScroll.AbsoluteWindowSize.Y
		traceAuto = max - traceScroll.CanvasPosition.Y < 24
	end)
end

local function formatPrice(number)
	local formatted = tostring(math.floor(number))
	while true do  
		local k
		formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
		if k == 0 then break end
	end
	return "$" .. formatted
end

-- Resolve the crystal BasePart the game's remotes expect (Value/WeightKg/Collected live on it)
local function crystalPart(crystal)
	if crystal:IsA("BasePart") then return crystal end

	local prompt = crystal:FindFirstChildWhichIsA("ProximityPrompt", true)
	local holder = prompt and prompt.Parent
	if holder and holder:IsA("BasePart") then return holder end

	for _, d in ipairs(crystal:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("Value") ~= nil then return d end
	end
	for _, d in ipairs(crystal:GetDescendants()) do
		if d:IsA("BasePart") then return d end
	end
	return crystal
end

-- Read a crystal attribute whether it lives on the model or the part
local function crystalAttr(crystal, name)
	local v = crystal:GetAttribute(name)
	if v ~= nil then return v end
	return crystalPart(crystal):GetAttribute(name)
end

-- Flight, FlyGuiV3 recipe: BodyGyro + BodyVelocity on the root with PlatformStand
-- while airborne, no noclip and no forced humanoid states. Stopping destroys the
-- bodies and returns the humanoid to normal, so the character grabs crystals as
-- a plain standing/falling avatar, exactly like a real player
local floatTarget = nil
local floatConn = nil
local flyBV, flyBG

local function flyStop()
	if flyBV then
		-- Kill residual speed: landing with leftover flight velocity is what
		-- triggers the game's RagdollRequest/FallDamage on every engine cut
		local root = flyBV.Parent
		if root and root:IsA("BasePart") then
			pcall(function() root.AssemblyLinearVelocity = Vector3.zero end)
		end
		pcall(function() flyBV:Destroy() end)
		flyBV = nil
	end
	if flyBG then
		pcall(function() flyBG:Destroy() end)
		flyBG = nil
	end
	local humanoid = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
	end
end

local function floatHeartbeat()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	if floatTarget then
		if not flyBV or flyBV.Parent ~= root then
			flyStop()
			flyBG = Instance.new("BodyGyro")
			flyBG.P = 9e4
			flyBG.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
			flyBG.CFrame = root.CFrame
			flyBG.Parent = root

			flyBV = Instance.new("BodyVelocity")
			flyBV.MaxForce = Vector3.new(9e9, 9e9, 9e9)
			flyBV.Velocity = Vector3.new(0, 0.1, 0)
			flyBV.Parent = root
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.PlatformStand = true
		end

		local delta = floatTarget.Position - root.Position
		local dist = delta.Magnitude
		if dist > 0.5 then
			flyBV.Velocity = delta.Unit * math.min(dist * 4, 120)
			flyBG.CFrame = CFrame.lookAt(root.Position, floatTarget.Position)
		else
			flyBV.Velocity = Vector3.zero
		end
	else
		flyStop()
	end
end

local function startFloat()
	if floatConn then return end
	-- Drop a leftover lock from a previous execution of this script
	if getgenv and getgenv().CRYSTAL_FLOAT_CONN then
		pcall(function() getgenv().CRYSTAL_FLOAT_CONN:Disconnect() end)
		getgenv().CRYSTAL_FLOAT_CONN = nil
	end
	floatConn = RunService.Heartbeat:Connect(floatHeartbeat)
	if getgenv then
		getgenv().CRYSTAL_FLOAT_CONN = floatConn
	end
end

local function stopFloat()
	if floatConn then
		floatConn:Disconnect()
		floatConn = nil
	end
	if getgenv and getgenv().CRYSTAL_FLOAT_CONN == floatConn then
		getgenv().CRYSTAL_FLOAT_CONN = nil
	end
	floatTarget = nil
	flyStop()
end

-- Teleport with fallback offsets: crystals embedded in terrain need a clear spot,
-- and we verify the avatar actually arrived (server/physics can snap it back)
local function teleportTo(object)
	local character = LocalPlayer.Character
	if not character then return false end

	local targetCFrame = nil
	if object:IsA("BasePart") then
		targetCFrame = object.CFrame
	elseif object:IsA("Model") then
		targetCFrame = object:GetPivot()
	end
	if not targetCFrame then return false end

	-- Close offsets first: the server enforces its own prompt distance, so a 20-stud-high
	-- arrival point can pass our check but be out of the game's collect range
	local offsets = {
		Vector3.new(0, 3, 0),
		Vector3.new(5, 3, 0), Vector3.new(-5, 3, 0), Vector3.new(0, 3, 5), Vector3.new(0, 3, -5),
		Vector3.new(0, 7, 0),
		Vector3.new(9, 6, 0), Vector3.new(-9, 6, 0), Vector3.new(0, 6, 9), Vector3.new(0, 6, -9),
		Vector3.new(0, 12, 0), Vector3.new(0, 20, 0),
	}

	-- Skip spots inside walls: spawning in geometry makes physics fling the character
	-- RespectCanCollide: decorations/VFX must not block, only solid walls.
	-- Crystals are not walls: dropped items pile up and would block every offset
	local clearParams = OverlapParams.new()
	clearParams.FilterType = Enum.RaycastFilterType.Exclude
	clearParams.FilterDescendantsInstances = { character, object, CrystalsFolder, DroppedCrystalsFolder }
	clearParams.RespectCanCollide = true

	for i, offset in ipairs(offsets) do
		local goal = targetCFrame.Position + offset
		if #workspace:GetPartBoundsInRadius(goal, 2.5, clearParams) == 0 then
			-- Set the flight goal before the pivot so engines catch the spot instantly
			floatTarget = targetCFrame + offset
			character:PivotTo(floatTarget)
			task.wait(0.1)

			local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
			local dist = root and (root.Position - goal).Magnitude or math.huge
			if dist < 12 then
				dlog(string.format("tp ok: offset %d/%d, landed %.1f studs off", i, #offsets, dist))
				return true
			end
			dlog(string.format("tp retry: offset %d was %.1f studs off (server snapped back?)", i, dist))
		end
	end

	-- Last resort: force the high spot over the target. Crowded targets can block
	-- every "clear" offset, and open air above is fine because the flight holds it
	floatTarget = targetCFrame + Vector3.new(0, 20, 0)
	character:PivotTo(floatTarget)
	task.wait(0.1)
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if root and (root.Position - floatTarget.Position).Magnitude < 12 then
		dlog("tp forced: high spot over a crowded target")
		return true
	end
	dlog("tp failed: no clear spot held")
	floatTarget = nil
	return false
end

-- Backpack weight vs capacity (base math from the reference script)
local function backpackWeight()
	local total = 0
	local function scan(container)
		if not container then return end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and child:GetAttribute("Tier") ~= nil then
				total += tonumber(child:GetAttribute("WeightKg")) or 0
			end
		end
	end
	scan(LocalPlayer:FindFirstChildOfClass("Backpack"))
	scan(LocalPlayer.Character)
	return total
end

-- Weight of crystals that would actually sell (favorites are kept)
local function sellableWeight()
	local total = 0
	local function scan(container)
		if not container then return end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and child:GetAttribute("Tier") ~= nil and child:GetAttribute("Favorited") ~= true then
				total += tonumber(child:GetAttribute("WeightKg")) or 0
			end
		end
	end
	scan(LocalPlayer:FindFirstChildOfClass("Backpack"))
	scan(LocalPlayer.Character)
	return total
end

local function ownsGamepass(name)
	local folder = LocalPlayer:FindFirstChild("GamepassesOwned")
	local flag = folder and folder:FindFirstChild(name)
	return flag ~= nil and flag:IsA("BoolValue") and flag.Value == true
end

local function hasActiveRune(keyword)
	local data = LocalPlayer:FindFirstChild("PlayerData")
	local plot = data and data:FindFirstChild("PlotData")
	local runes = plot and plot:FindFirstChild("Runes")
	if not runes then return false end
	for _, child in ipairs(runes:GetChildren()) do
		local runeName = child:GetAttribute("RuneName")
		if type(runeName) == "string" and runeName:find(keyword, 1, true) then
			if (tonumber(child:GetAttribute("Remaining")) or 0) > 0 then
				return true
			end
		end
	end
	return false
end

local function backpackFree()
	if LocalPlayer:GetAttribute("InfBackpack") == true then
		return math.huge
	end
	local data = LocalPlayer:FindFirstChild("PlayerData")
	local stats = data and data:FindFirstChild("RealStats")
	local capacity = 10
	if stats then
		local base = stats:FindFirstChild("CarryWeight")
		local bonus = stats:FindFirstChild("CarryWeightBonus")
		if base then capacity = base.Value end
		if bonus then capacity += bonus.Value end
	end
	if ownsGamepass("CarryKgPlus4") then capacity *= 4 end
	if hasActiveRune("Weight") then capacity *= 2 end
	return capacity - backpackWeight()
end

-- Mine one crystal: fire the game remote, then zero the prompt and fire it
local function grabCrystal(crystal)
	local sent = false
	if HoldComplete then
		sent = pcall(function()
			HoldComplete:FireServer(crystalPart(crystal))
		end)
	end

	-- Buried crystals (MinedHP nil) refuse HoldComplete forever, the log showed
	-- the farm bouncing T7 to T7 collecting nothing. Dig them out: DigRequest's
	-- exact signature is unknown, so fire both shapes it plausibly takes (the
	-- part, or a world position), pcalls keep a wrong shape harmless
	if DigRequest and crystalAttr(crystal, "MinedHP") == nil then
		local p = crystalPart(crystal)
		pcall(function() DigRequest:FireServer(p) end)
		pcall(function() DigRequest:FireServer(p.Position) end)
	end

	local prompt = crystal:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt then
		local saved = {
			hold = prompt.HoldDuration,
			sight = prompt.RequiresLineOfSight,
			enabled = prompt.Enabled,
			range = prompt.MaxActivationDistance,
		}
		pcall(function()
			prompt.HoldDuration = 0
			prompt.RequiresLineOfSight = false
			prompt.Enabled = true
			prompt.MaxActivationDistance = 1000
		end)

		if typeof(fireproximityprompt) == "function" then
			sent = pcall(fireproximityprompt, prompt, 1) or sent
		else
			sent = pcall(function()
				prompt:InputHoldBegin()
				prompt:InputHoldEnd()
			end) or sent
		end

		task.delay(0.2, function()
			if prompt.Parent then
				prompt.HoldDuration = saved.hold
				prompt.RequiresLineOfSight = saved.sight
				prompt.Enabled = saved.enabled
				prompt.MaxActivationDistance = saved.range
			end
		end)
	end

	return sent
end

-- Fly to the crystal, stop flying, then grab it as a normal character. Retries
-- (fly in again) if the server still refuses, then gives up so the loop moves on
local function hoverGrab(crystal)
	-- Let the flight finish first: if the teleport was rubber-banded, the mover
	-- is still flying the character in and the server would reject an out-of-range grab
	local part = crystalPart(crystal)
	local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	if root and part.Parent then
		local deadline = os.clock() + 1.5
		while os.clock() < deadline and part.Parent do
			local r = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
			if not r or (r.Position - part.Position).Magnitude <= 12 then break end
			task.wait(0.05)
		end
		local r = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		dlog(string.format("grab: %.1f studs away, target %s '%s' HP=%s",
			(r and part.Parent) and (r.Position - part.Position).Magnitude or -1,
			part.ClassName, part.Name, tostring(crystalAttr(crystal, "MinedHP"))))
	end

	-- Trace: dump target state once so every run is comparable. bagFree matters:
	-- the server silently refuses collection when the crystal is heavier than
	-- the remaining capacity (the reference skips those too)
	dlog(string.format("attrs: %s Value=%s WeightKg=%s Tier=%s MinedHP=%s Collected=%s bagFree=%s",
		part:GetFullName(), tostring(part:GetAttribute("Value")), tostring(part:GetAttribute("WeightKg")),
		tostring(part:GetAttribute("Tier")), tostring(part:GetAttribute("MinedHP")),
		tostring(part:GetAttribute("Collected")), tostring(backpackFree())))
	if (tonumber(part:GetAttribute("WeightKg")) or 0) > backpackFree() then
		dlog("grab will be refused: bag has less free weight than this crystal, sell first")
	end

	-- Keep flying at the crystal the whole time, engines only cut after it is
	-- collected. No digging, no pickaxe: both successful grabs needed nothing else.
	-- Big crystals need many holds, and HP drops can arrive in bursts seconds
	-- apart. Zero progress for 3s past the base 10s = server refusal, move on.
	-- But once HP has actually dropped we are mid-mine: a 10s gap between drops
	-- is normal chewing, abandoning there left crystals half-mined and sent the
	-- farm after the next bigger spawn
	local grabStart = os.clock()
	local hardEnd = grabStart + 60
	local lastHP = crystalAttr(crystal, "MinedHP")
	local progressAt = grabStart
	local madeProgress = false
	while os.clock() < hardEnd and crystal.Parent
		and crystalAttr(crystal, "Collected") ~= true do
		floatTarget = CFrame.new(part.Position + Vector3.new(0, 5, 0))

		-- Mining speed = hold-remote ticks per second. Big crystals chew for
		-- minutes at the old 5 ticks/s, so double it; the stall detector above
		-- still backs off if the server starts throttling the spam
		for _ = 1, 6 do
			grabCrystal(crystal)
			task.wait(0.1)
		end

		local hp = crystalAttr(crystal, "MinedHP")
		local now = os.clock()
		if hp ~= nil and lastHP ~= nil and hp < lastHP then
			lastHP = hp
			progressAt = now
			madeProgress = true
			-- Still making progress at the cap means a huge crystal: keep going,
			-- 30s at a time, up to 3 minutes total
			if now + 30 > hardEnd then
				hardEnd = math.min(now + 30, grabStart + 600)
			end
		elseif now - grabStart > 10 and now - progressAt > (madeProgress and 20 or (DigRequest and 8 or 3)) then
			dlog("grab stalled: no MinedHP progress for "
				.. (madeProgress and 20 or (DigRequest and 8 or 3)) .. "s, moving on")
			break
		end
	end
	dlog(string.format("grab done: collected=%s",
		tostring(not crystal.Parent or crystalAttr(crystal, "Collected") == true)))
end

-- Teleport from the search list also mines the crystal (hovers only for the grab)
local function tpAndMine(crystal)
	-- Shield on BEFORE the teleport: without it the character lands in a wall
	-- with collisions on for a frame and gets thrown by physics
	startFloat()
	if teleportTo(crystal) then
		hoverGrab(crystal)
	end
	stopFloat()
end

--------------------------------------------------------------------------------
-- 2. CREATE UI
--------------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "CrystalFinderGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = PlayerGui

local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(0, 420, 0, 500)
mainFrame.Position = UDim2.new(0.5, -210, 0.5, -250)
mainFrame.BackgroundColor3 = Color3.fromRGB(30, 32, 40)
mainFrame.BorderSizePixel = 0
mainFrame.Active = true
mainFrame.Draggable = true
mainFrame.Parent = screenGui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 12)
mainCorner.Parent = mainFrame

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, 0, 0, 45)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "💎 Crystal Finder (Prompt Scanner)"
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.TextSize = 18
titleLabel.Font = Enum.Font.GothamBold
titleLabel.Parent = mainFrame

-- Floating hide/show button, parented to the ScreenGui so it stays visible when the panel is hidden
local toggleBtn = Instance.new("TextButton")
toggleBtn.Size = UDim2.new(0, 130, 0, 32)
toggleBtn.Position = UDim2.new(1, -145, 0, 12)
toggleBtn.BackgroundColor3 = Color3.fromRGB(30, 32, 40)
toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
toggleBtn.Text = "💎 Hide Panel"
toggleBtn.TextSize = 13
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.Parent = screenGui

local toggleCorner = Instance.new("UICorner")
toggleCorner.CornerRadius = UDim.new(0, 8)
toggleCorner.Parent = toggleBtn

toggleBtn.MouseButton1Click:Connect(function()
	mainFrame.Visible = not mainFrame.Visible
	toggleBtn.Text = mainFrame.Visible and "💎 Hide Panel" or "💎 Show Panel"
end)

local inputBox = Instance.new("TextBox")
inputBox.Size = UDim2.new(0.65, -15, 0, 38)
inputBox.Position = UDim2.new(0, 15, 0, 50)
inputBox.BackgroundColor3 = Color3.fromRGB(42, 45, 56)
inputBox.TextColor3 = Color3.fromRGB(255, 255, 255)
inputBox.PlaceholderText = "Min price (500k, 500,000)"
inputBox.PlaceholderColor3 = Color3.fromRGB(150, 150, 160)
inputBox.Text = "500k"
inputBox.TextSize = 14
inputBox.Font = Enum.Font.Gotham
inputBox.Parent = mainFrame

local inputCorner = Instance.new("UICorner")
inputCorner.CornerRadius = UDim.new(0, 8)
inputCorner.Parent = inputBox

local searchBtn = Instance.new("TextButton")
searchBtn.Size = UDim2.new(0.35, -20, 0, 38)
searchBtn.Position = UDim2.new(0.65, 5, 0, 50)
searchBtn.BackgroundColor3 = Color3.fromRGB(98, 84, 243)
searchBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
searchBtn.Text = "Search"
searchBtn.TextSize = 14
searchBtn.Font = Enum.Font.GothamBold
searchBtn.Parent = mainFrame

local searchCorner = Instance.new("UICorner")
searchCorner.CornerRadius = UDim.new(0, 8)
searchCorner.Parent = searchBtn

local farmBtn = Instance.new("TextButton")
farmBtn.Size = UDim2.new(0.45, -15, 0, 38)
farmBtn.Position = UDim2.new(0, 15, 0, 94)
farmBtn.BackgroundColor3 = Color3.fromRGB(46, 175, 110)
farmBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
farmBtn.Text = "▶ Start Auto Farm"
farmBtn.TextSize = 14
farmBtn.Font = Enum.Font.GothamBold
farmBtn.Parent = mainFrame

local farmCorner = Instance.new("UICorner")
farmCorner.CornerRadius = UDim.new(0, 8)
farmCorner.Parent = farmBtn

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(0.55, -20, 0, 38)
statusLabel.Position = UDim2.new(0.45, 0, 0, 94)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Idle"
statusLabel.TextColor3 = Color3.fromRGB(160, 160, 170)
statusLabel.TextSize = 12
statusLabel.TextWrapped = true
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = mainFrame

local hopBtn = Instance.new("TextButton")
hopBtn.Size = UDim2.new(0, 64, 0, 32)
hopBtn.Position = UDim2.new(0, 15, 0, 136)
hopBtn.BackgroundColor3 = Color3.fromRGB(98, 84, 243)
hopBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
hopBtn.Text = "Hop"
hopBtn.TextSize = 13
hopBtn.Font = Enum.Font.GothamBold
hopBtn.Parent = mainFrame

local hopCorner = Instance.new("UICorner")
hopCorner.CornerRadius = UDim.new(0, 8)
hopCorner.Parent = hopBtn

local favInput = Instance.new("TextBox")
favInput.Size = UDim2.new(0, 150, 0, 32)
favInput.Position = UDim2.new(0, 86, 0, 136)
favInput.BackgroundColor3 = Color3.fromRGB(42, 45, 56)
favInput.TextColor3 = Color3.fromRGB(255, 255, 255)
favInput.PlaceholderText = "Fav >= 1b (empty = off)"
favInput.PlaceholderColor3 = Color3.fromRGB(150, 150, 160)
favInput.Text = ""
favInput.TextSize = 12
favInput.Font = Enum.Font.Gotham
favInput.ClearTextOnFocus = false
favInput.Parent = mainFrame

local favCorner = Instance.new("UICorner")
favCorner.CornerRadius = UDim.new(0, 8)
favCorner.Parent = favInput

local hopIdleInput = Instance.new("TextBox")
hopIdleInput.Size = UDim2.new(1, -258, 0, 32)
hopIdleInput.Position = UDim2.new(0, 243, 0, 136)
hopIdleInput.BackgroundColor3 = Color3.fromRGB(42, 45, 56)
hopIdleInput.TextColor3 = Color3.fromRGB(255, 255, 255)
hopIdleInput.PlaceholderText = "Auto hop after N min idle (empty = off)"
hopIdleInput.PlaceholderColor3 = Color3.fromRGB(150, 150, 160)
hopIdleInput.Text = ""
hopIdleInput.TextSize = 12
hopIdleInput.Font = Enum.Font.Gotham
hopIdleInput.ClearTextOnFocus = false
hopIdleInput.Parent = mainFrame

local hopIdleCorner = Instance.new("UICorner")
hopIdleCorner.CornerRadius = UDim.new(0, 8)
hopIdleCorner.Parent = hopIdleInput

local scrollFrame = Instance.new("ScrollingFrame")
scrollFrame.Size = UDim2.new(1, -30, 1, -189)
scrollFrame.Position = UDim2.new(0, 15, 0, 174)
scrollFrame.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
scrollFrame.BorderSizePixel = 0
scrollFrame.ScrollBarThickness = 6
scrollFrame.ScrollBarImageColor3 = Color3.fromRGB(98, 84, 243)
scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
scrollFrame.Parent = mainFrame

local scrollCorner = Instance.new("UICorner")
scrollCorner.CornerRadius = UDim.new(0, 8)
scrollCorner.Parent = scrollFrame

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 8)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = scrollFrame

local listPadding = Instance.new("UIPadding")
listPadding.PaddingTop = UDim.new(0, 8)
listPadding.PaddingBottom = UDim.new(0, 8)
listPadding.PaddingLeft = UDim.new(0, 8)
listPadding.PaddingRight = UDim.new(0, 8)
listPadding.Parent = scrollFrame

listLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
	scrollFrame.CanvasSize = UDim2.new(0, 0, 0, listLayout.AbsoluteContentSize.Y + 16)
end)

--------------------------------------------------------------------------------
-- 3. HIDE CHEAP CRYSTALS (perf: hundreds of rendered crystals + hover tag GUIs = lag)
--------------------------------------------------------------------------------
local hiddenState = setmetatable({}, { __mode = "k" }) -- instance -> saved Transparency/Enabled

local function crystalPriceOf(crystal)
	local prompt = crystal:FindFirstChildWhichIsA("ProximityPrompt", true)
	local price = prompt and extractPriceFromPromptText(prompt.ObjectText .. " " .. prompt.ActionText) or 0
	if price == 0 then
		-- prompt text missing or not replicated yet: the Value attribute is the price
		price = tonumber(crystalAttr(crystal, "Value")) or 0
	end
	return price
end

local function setCrystalVisible(crystal, visible)
	local list = {}
	if crystal:IsA("BasePart") then
		list[1] = crystal
	else
		for _, d in ipairs(crystal:GetDescendants()) do
			if d:IsA("BasePart") or d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
				list[#list + 1] = d
			end
		end
	end
	for _, inst in ipairs(list) do
		local isPart = inst:IsA("BasePart")
		if visible then
			local saved = hiddenState[inst]
			if saved ~= nil then
				if isPart then inst.Transparency = saved else inst.Enabled = saved end
				hiddenState[inst] = nil
			end
		else
			if hiddenState[inst] == nil then
				hiddenState[inst] = isPart and inst.Transparency or inst.Enabled
			end
			if isPart then inst.Transparency = 1 else inst.Enabled = false end
		end
	end
end

local function refreshHide()
	local minPrice = parsePrice(inputBox.Text)
	for _, folder in ipairs(crystalFolders) do
		for _, crystal in ipairs(folder:GetChildren()) do
			setCrystalVisible(crystal, minPrice <= 0 or crystalPriceOf(crystal) >= minPrice)
		end
	end
end

if getgenv and getgenv().CRYSTAL_HIDE_CONN then
	pcall(function() getgenv().CRYSTAL_HIDE_CONN:Disconnect() end)
	getgenv().CRYSTAL_HIDE_CONN = nil
end
local hideConn = CrystalsFolder.ChildAdded:Connect(function(crystal)
	task.wait(0.5) -- let the prompt text replicate before judging its price
	local minPrice = parsePrice(inputBox.Text)
	setCrystalVisible(crystal, minPrice <= 0 or crystalPriceOf(crystal) >= minPrice)
end)
if getgenv then
	getgenv().CRYSTAL_HIDE_CONN = hideConn
end

-- Re-judge on a timer too: streamed-in parts come back visible, and a fresh
-- crystal judged before its prompt text replicated stays wrongly hidden/shown
if getgenv then
	getgenv().CRYSTAL_HIDE_GEN = (getgenv().CRYSTAL_HIDE_GEN or 0) + 1
end
local hideGen = (getgenv and getgenv().CRYSTAL_HIDE_GEN) or 1
task.spawn(function()
	while (getgenv and getgenv().CRYSTAL_HIDE_GEN or hideGen) == hideGen do
		task.wait(3)
		pcall(refreshHide)
	end
end)

--------------------------------------------------------------------------------
-- 4. SEARCH LOGIC FOR PROXIMITYPROMPT
--------------------------------------------------------------------------------

local function scanCrystals()
	refreshHide()
	for _, child in ipairs(scrollFrame:GetChildren()) do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	local minPrice = parsePrice(inputBox.Text)
	local crystalList = {}
	local withPrompt, total = 0, 0

	for _, folder in ipairs(crystalFolders) do
		for _, crystal in ipairs(folder:GetChildren()) do
			total += 1
			local prompt = crystal:FindFirstChildWhichIsA("ProximityPrompt", true)
			if prompt then
				withPrompt += 1
			end
			-- Текст может быть как в ObjectText, так и в ActionText
			local fullText = prompt and (prompt.ObjectText .. " " .. prompt.ActionText) or ""
			local numericPrice = crystalPriceOf(crystal)
			if numericPrice >= minPrice then
				table.insert(crystalList, {
					Object = crystal,
					Name = crystal.Name,
					Price = numericPrice,
					FullText = fullText,
				})
			end
		end
	end
	dlog(string.format("scan: %d total, %d with prompt, %d listed, min=%s",
		total, withPrompt, #crystalList, formatPrice(minPrice)))

	-- Сортировка по цене
	table.sort(crystalList, function(a, b) return a.Price > b.Price end)

	if #crystalList == 0 then
		local noResultLabel = Instance.new("TextLabel")
		noResultLabel.Size = UDim2.new(1, 0, 0, 50)
		noResultLabel.BackgroundTransparency = 1
		noResultLabel.Text = "No crystals found matching >= " .. formatPrice(minPrice)
		noResultLabel.TextColor3 = Color3.fromRGB(200, 200, 100)
		noResultLabel.TextSize = 13
		noResultLabel.Font = Enum.Font.Gotham
		noResultLabel.Parent = scrollFrame
		return
	end

	for _, item in ipairs(crystalList) do
		local card = Instance.new("Frame")
		card.Size = UDim2.new(1, 0, 0, 50)
		card.BackgroundColor3 = Color3.fromRGB(36, 39, 49)
		card.Parent = scrollFrame

		local cardCorner = Instance.new("UICorner")
		cardCorner.CornerRadius = UDim.new(0, 6)
		cardCorner.Parent = card

		local infoLabel = Instance.new("TextLabel")
		infoLabel.Size = UDim2.new(0.65, -10, 1, 0)
		infoLabel.Position = UDim2.new(0, 10, 0, 0)
		infoLabel.BackgroundTransparency = 1
		infoLabel.Text = string.format("%s\n<font color='#4EFEAA'>%s</font>", item.FullText ~= "" and item.FullText or item.Name, formatPrice(item.Price))
		infoLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
		infoLabel.TextSize = 12
		infoLabel.Font = Enum.Font.GothamMedium
		infoLabel.RichText = true
		infoLabel.TextXAlignment = Enum.TextXAlignment.Left
		infoLabel.Parent = card

		local tpBtn = Instance.new("TextButton")
		tpBtn.Size = UDim2.new(0.32, -10, 0, 32)
		tpBtn.Position = UDim2.new(0.68, 0, 0.5, -16)
		tpBtn.BackgroundColor3 = Color3.fromRGB(46, 175, 110)
		tpBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		tpBtn.Text = "TP + Mine"
		tpBtn.TextSize = 12
		tpBtn.Font = Enum.Font.GothamBold
		tpBtn.Parent = card

		local tpCorner = Instance.new("UICorner")
		tpCorner.CornerRadius = UDim.new(0, 6)
		tpCorner.Parent = tpBtn

		tpBtn.MouseButton1Click:Connect(function()
			tpAndMine(item.Object)
		end)
	end
end

searchBtn.MouseButton1Click:Connect(scanCrystals)
scanCrystals()

-- Auto refresh like the reference script (10s): streaming-late items appear
-- in the list without pressing Search again
if getgenv then
	getgenv().CRYSTAL_SCAN_GEN = (getgenv().CRYSTAL_SCAN_GEN or 0) + 1
end
local scanGen = (getgenv and getgenv().CRYSTAL_SCAN_GEN) or 1
task.spawn(function()
	while (getgenv and getgenv().CRYSTAL_SCAN_GEN or scanGen) == scanGen do
		task.wait(10)
		pcall(scanCrystals)
	end
end)

--------------------------------------------------------------------------------
-- 4. AUTO FARM LOOP
--------------------------------------------------------------------------------

local farming = false

local function setStatus(text, color)
	statusLabel.Text = text
	statusLabel.TextColor3 = color or Color3.fromRGB(220, 220, 220)
end

-- Sell everything except favorited crystals
local function sellAll()
	-- Release the hover: the server teleports the character to the seller,
	-- and a mid-air lock plus noclip would break that trip
	floatTarget = nil
	task.wait(0.1)
	setStatus("Selling...", Color3.fromRGB(255, 200, 60))

	if not GoHome or not SellRequest then
		setStatus("Sell failed: remotes not found", Color3.fromRGB(255, 90, 90))
		task.wait(2)
		return
	end

	local sellableBefore = sellableWeight()

	-- No unfavorite here: the game's SellRequest("all") skips favorited items,
	-- which is exactly what keeps the high-value favorites in the bag
	pcall(function() GoHome:FireServer("sell") end)
	task.wait(1)

	-- Fire until the bag stops shrinking: a sell fired while still traveling to
	-- the seller is silently ignored, one early shot left items behind
	local prev = sellableBefore
	for i = 1, 5 do
		pcall(function() SellRequest:FireServer("all") end)
		task.wait(1)
		local now = sellableWeight()
		if i >= 2 and now >= prev then break end
		prev = now
	end

	local soldKg = math.max(0, sellableBefore - sellableWeight())
	dlog(string.format("sold %.1f kg, %.1f kg sellable left (favorites kept)", soldKg, sellableWeight()))
	setStatus(string.format("Sold %.1f kg (favorites kept)", soldKg), Color3.fromRGB(120, 220, 150))
end

-- Crystals that refused collection or blocked the teleport: skip them for a
-- minute instead of hammering the same target while good ones wait
local failedUntil = setmetatable({}, { __mode = "k" })

local function findBest(minPrice)
	local best, bestPrice = nil, 0
	local top, topPrice = nil, 0 -- priciest overall, for the "why not the biggest" log
	local now = os.clock()
	for _, folder in ipairs(crystalFolders) do
		for _, crystal in ipairs(folder:GetChildren()) do
			if crystal.Parent and crystalAttr(crystal, "Collected") ~= true then
				local price = crystalPriceOf(crystal)
				if price > topPrice then
					top, topPrice = crystal, price
				end
				-- No MinedHP pre-filter: it wrongly excluded minable crystals
				-- (TP + Mine collects them fine). A buried one costs a single
				-- failed grab, then the blacklist skips it for minutes
				if (failedUntil[crystal] == nil or failedUntil[crystal] <= now)
					and price >= minPrice and price > bestPrice then
					best, bestPrice = crystal, price
				end
			end
		end
	end
	return best, bestPrice, top, topPrice
end

-- Favorite backpack crystals worth >= threshold (favorites are kept by sellAll)
local function autoFavorite()
	local threshold = parsePrice(favInput.Text)
	if threshold <= 0 then return end

	local function scan(container)
		if not container then return end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool")
				and child:GetAttribute("Favorited") ~= true
				and (tonumber(child:GetAttribute("Value")) or 0) >= threshold then
				child:SetAttribute("Favorited", true)
				if ToggleFavorite then
					pcall(function() ToggleFavorite:FireServer(child, true) end)
				end
			end
		end
	end
	scan(LocalPlayer:FindFirstChildOfClass("Backpack"))
	scan(LocalPlayer.Character)
end

-- Server hop: join a random open server, queue auto-resume if SCRIPT_URL is set
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local hopping = false
local hopTries = 0 -- re-hops after landing in the same server (no server list on this executor)
local function hopServer()
	if hopping then return end
	hopping = true
	setStatus("Hopping server...", Color3.fromRGB(255, 200, 60))

	local req = (syn and syn.request)
		or (http and http.request)
		or (type(http_request) == "function" and http_request)
		or (type(request) == "function" and request)

	local candidates = {}

	-- Feeder file from the Mac side (fetch_servers.sh): executor HTTP hangs
	-- forever here, so the server list arrives via readfile instead of a request
	if type(readfile) == "function" then
		local ok, raw = pcall(readfile, "server_list.json")
		if ok and type(raw) == "string" and raw ~= "" then
			local okJson, data = pcall(HttpService.JSONDecode, HttpService, raw)
			if okJson and type(data) == "table" and type(data.servers) == "table"
				and os.time() - (data.savedAt or 0) < 300 then
				for _, id in ipairs(data.servers) do
					if id ~= game.JobId then
						candidates[#candidates + 1] = id
					end
				end
				dlog("hop: " .. #candidates .. " candidate servers from feeder file")
			end
		end
	end

	if req and #candidates == 0 then
		-- Hard 10s timeout: a request that never resolves must not hang the hop
		local res, done, httpErr = nil, false, nil
		task.spawn(function()
			local ok, r = pcall(req, {
				Url = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=2&excludeFullGames=true&limit=100",
				Method = "GET",
			})
			if ok then res = r else httpErr = tostring(r) end
			done = true
		end)
		local t0 = os.clock()
		while not done and os.clock() - t0 < 10 do
			task.wait(0.1)
		end
		if res and res.Body then
			local okJson, data = pcall(HttpService.JSONDecode, HttpService, res.Body)
			if okJson and type(data) == "table" and type(data.data) == "table" then
				for _, server in ipairs(data.data) do
					if server.id ~= game.JobId and (server.playing or 0) < (server.maxPlayers or 0) then
						candidates[#candidates + 1] = server.id
					end
				end
				dlog(string.format("hop: %d candidate servers", #candidates))
			else
				dlog("hop: server list json unreadable")
			end
		else
			dlog("hop http failed or timed out: " .. tostring(httpErr or "silent for 10s"))
		end
	elseif #candidates == 0 then
		dlog("hop: no http function on this executor")
	end

	if #candidates == 0 then
		-- No list (HTTP unavailable or blocked): a plain Teleport still lands us
		-- on a fresh server instead of failing the hop outright
		dlog("hop: no server list, falling back to plain Teleport")
	end

	-- Auto-resume path 1: file config. The auto-exec loader re-runs this script on
	-- every join and restores it, no queue_on_teleport needed (Macsploit lacks it)
	if farming and type(writefile) == "function" then
		pcall(function()
			writefile("crystal_farm_cfg.json", HttpService:JSONEncode({
				min = inputBox.Text,
				fav = favInput.Text,
				idle = hopIdleInput.Text,
				autostart = true,
				lastJob = game.JobId,
				hopTries = hopTries,
				savedAt = os.time(),
			}))
		end)
	end

	-- Auto-resume path 2: queued script for executors that support it
	-- (some executors name it queueonteleport, try both)
	local queue_tp = (type(queue_on_teleport) == "function" and queue_on_teleport)
		or (type(queueonteleport) == "function" and queueonteleport)
	if SCRIPT_URL ~= "" and queue_tp then
		-- Self-diagnosing queued string: errors here are invisible in the console,
		-- so every step writes crystal_hop_trace.txt (read it after a dead hop)
		queue_tp(string.format([[
			local function trace(m)
				if writefile then pcall(writefile, "crystal_hop_trace.txt", tostring(m)) end
			end
			trace("queued ran " .. os.time())
			shared.CRYSTAL_CFG = {min=%q, fav=%q, idle=%q, autostart=%s, lastJob=%q, hopTries=%d}
			-- Local file first: game:HttpGet hangs forever on this executor, so the
			-- GitHub fetch is only the fallback when auto.lua is missing on disk
			local src
			if readfile then
				local okF, raw = pcall(readfile, "auto.lua")
				if okF and type(raw) == "string" and #raw > 0 then
					src = raw
					trace("file src " .. #raw .. " bytes")
				end
			end
			if not src then
				for i = 1, 3 do
					local ok, res = pcall(game.HttpGet, game, "%s")
					if ok and type(res) == "string" and #res > 0 then src = res break end
					trace("HttpGet " .. i .. " failed: " .. tostring(res))
					task.wait(2)
				end
			end
			if src then
				local okRun, err = pcall(loadstring(src))
				trace(okRun and "farm loadstring ok" or ("loadstring error: " .. tostring(err)))
			else
				trace("HttpGet gave up")
			end
		]], inputBox.Text, favInput.Text, hopIdleInput.Text, tostring(farming), game.JobId, hopTries, SCRIPT_URL))
		dlog("hop resume: queued via queue_on_teleport")
	else
		-- print() never reaches the Macsploit console, dlog does
		dlog("hop resume: no queue_on_teleport, relying on auto-exec loader + cfg file")
	end

	local function tpTo(id)
		if id then
			TeleportService:TeleportToPlaceInstance(game.PlaceId, id, LocalPlayer)
		else
			TeleportService:Teleport(game.PlaceId, LocalPlayer)
		end
	end
	local target = #candidates > 0 and candidates[math.random(#candidates)] or nil
	local okTp, errTp = pcall(tpTo, target)
	if not okTp then
		dlog("hop teleport failed: " .. tostring(errTp) .. ", retrying plain Teleport")
		pcall(tpTo, nil)
	end

	-- If we are still here after 6s the teleport never fired: unstick the farm
	-- instead of showing Hopping forever
	task.delay(6, function()
		if hopping then
			setStatus("Hop did not fire, farming on", Color3.fromRGB(255, 150, 90))
			hopping = false
		end
	end)
end

hopBtn.MouseButton1Click:Connect(function()
	task.spawn(hopServer)
end)

local function farmLoop()
	local fails = 0
	local lastFoundAt = os.clock()
	local waitLogAt = 0
	local whyLogAt = 0

	while farming do
		-- Re-read the min price every cycle so it can be changed while farming
		local minPrice = parsePrice(inputBox.Text)
		autoFavorite()
		local best, price, top, topPrice = findBest(minPrice)

		if not best then
			-- Say WHY nothing qualifies, a silent wait hides the cause:
			-- total low = crystals streamed out (standing too far, e.g. sell area),
			-- exposed low = everything still buried (MinedHP nil, server refuses)
			local total, exposed = 0, 0
			for _, folder in ipairs(crystalFolders) do
				for _, c in ipairs(folder:GetChildren()) do
					total += 1
					if crystalAttr(c, "MinedHP") ~= nil then exposed += 1 end
				end
			end
			if os.clock() - waitLogAt > 5 then
				waitLogAt = os.clock()
				dlog(string.format("no target: %d replicated, %d exposed, min=%s",
					total, exposed, formatPrice(minPrice)))
			end
			setStatus(string.format("Waiting: %d crystals, %d exposed", total, exposed))
			-- Auto-hop when nothing qualifying has spawned for N minutes
			local hopMin = tonumber(hopIdleInput.Text) or 0
			if hopMin > 0 and os.clock() - lastFoundAt > hopMin * 60 then
				lastFoundAt = os.clock()
				hopServer()
			end
			task.wait(1)
		else
			-- Bag full for this crystal: sell first, but only if something can actually sell
			local weight = tonumber(crystalAttr(best, "WeightKg")) or 0
			if weight > backpackFree() then
				if sellableWeight() > 0 then
					sellAll()
				else
					setStatus("Bag full of favorites, nothing to sell. Waiting (hop timer running)...", Color3.fromRGB(255, 200, 60))
					task.wait(2)
				end
			else
				setStatus("Mining: " .. best.Name .. " (" .. formatPrice(price) .. ")")
				-- A pricier crystal exists but was filtered: say why, once per 5s
				if top and top ~= best and topPrice > price and os.clock() - whyLogAt > 5 then
					whyLogAt = os.clock()
					dlog(string.format("pricier %s (%s) not targeted: buried=%s skipped=%s",
						top.Name, formatPrice(topPrice),
						tostring(crystalAttr(top, "MinedHP") == nil),
						tostring(failedUntil[top] ~= nil and failedUntil[top] > os.clock())))
				end

				-- Same engines-on/engines-off wrap as the TP + Mine button: the farm
				-- flew forever between crystals (PlatformStand nonstop), TP + Mine
				-- lands as a normal avatar after each grab
				-- Any real attempt counts as activity: the idle-hop timer used to
				-- run only on collects, so a T8 mined longer than the idle window
				-- hopped servers mid-mine
				lastFoundAt = os.clock()
				startFloat()
				if teleportTo(best) then
					hoverGrab(best)
					stopFloat()

					local collected = not best.Parent or crystalAttr(best, "Collected") == true
					if collected then
						fails = 0
						-- Only a successful collection resets the idle/hop timer
						lastFoundAt = os.clock()
					else
						fails += 1
						setStatus("Collect failed x" .. fails .. ": " .. best.Name, Color3.fromRGB(255, 150, 90))
						-- Buried (MinedHP nil) refuses every grab: park it 5 min.
						-- A normal refusal only gets 1 min
						local skipFor = crystalAttr(best, "MinedHP") == nil and 300 or 60
						failedUntil[best] = os.clock() + skipFor
						dlog("skip " .. best.Name .. " for " .. skipFor .. "s (collect refused)")
					end
				else
					stopFloat()
					fails += 1
					setStatus("Teleport blocked x" .. fails .. ": " .. best.Name, Color3.fromRGB(255, 150, 90))
					failedUntil[best] = os.clock() + 60
					dlog("skip " .. best.Name .. " for 60s (tp blocked)")
				end

				-- Refusals are not a full bag: sell on 3 fails only when the bag is
				-- truly full, else buried crystals would bus us to the seller nonstop
				if fails >= 3 and backpackFree() <= 0 and sellableWeight() > 0 then
					sellAll()
					fails = 0
				end
				task.wait(0.15)
			end
		end
	end
	setStatus("Auto farm stopped.", Color3.fromRGB(160, 160, 170))
end

local function startFarm()
	if farming then return end
	farming = true
	startFloat()
	farmBtn.Text = "■ Stop Auto Farm"
	farmBtn.BackgroundColor3 = Color3.fromRGB(220, 80, 80)
	task.spawn(farmLoop)
end

local function stopFarm()
	farming = false
	stopFloat()
	farmBtn.Text = "▶ Start Auto Farm"
	farmBtn.BackgroundColor3 = Color3.fromRGB(46, 175, 110)
end

farmBtn.MouseButton1Click:Connect(function()
	if farming then
		stopFarm()
	else
		startFarm()
	end
end)

-- Tell the Mac-side feeder (fetch_servers.sh) which place/job to list servers for
if type(writefile) == "function" then
	pcall(function()
		writefile("crystal_place.txt", game.PlaceId .. " " .. game.JobId)
	end)
end

-- Restore settings after a server hop: queued script config first,
-- else the cfg file written while hopping (auto-exec loader path)
local cfg = (shared.CRYSTAL_CFG) or (getgenv and getgenv().CRYSTAL_CFG) or nil
if not cfg and type(readfile) == "function" then
	local ok, raw = pcall(readfile, "crystal_farm_cfg.json")
	if ok and type(raw) == "string" and raw ~= "" then
		local okJson, data = pcall(HttpService.JSONDecode, HttpService, raw)
		-- Ignore stale configs: a hop config older than 10 min should not auto-start
		if okJson and type(data) == "table" and os.time() - (data.savedAt or 0) < 600 then
			cfg = data
		end
	end
end
if cfg then
	if cfg.min then inputBox.Text = cfg.min end
	if cfg.fav then favInput.Text = cfg.fav end
	if cfg.idle then hopIdleInput.Text = cfg.idle end
	if cfg.autostart then startFarm() end
	-- Plain Teleport (no server list on this executor) lets the matchmaker drop
	-- us right back into the SAME server. Same JobId after a hop = hop again, max 3
	hopTries = (cfg.lastJob == game.JobId) and (tonumber(cfg.hopTries) or 0) + 1 or 0
	if farming and hopTries > 0 and hopTries <= 3 then
		dlog(string.format("hop landed in the same server (try %d), re-hopping", hopTries))
		task.delay(3, hopServer)
	end
end