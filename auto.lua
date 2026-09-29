local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local CrystalsFolder = workspace:WaitForChild("Things"):WaitForChild("Crystals")

-- Mining remote (recipe from the open-source Mine a Mountain script)
local Remotes = ReplicatedStorage:FindFirstChild("Remotes") or ReplicatedStorage:WaitForChild("Remotes", 5)
local HoldComplete = Remotes and Remotes:FindFirstChild("CrystalHoldComplete")
local SellRequest = Remotes and Remotes:FindFirstChild("SellRequest")
local GoHome = Remotes and Remotes:FindFirstChild("GoHome")
local ToggleFavorite = Remotes and Remotes:FindFirstChild("ToggleFavorite")

-- Server hop: paste the raw URL of this script (e.g. your gist raw link) to auto-resume after hopping
local SCRIPT_URL = "https://raw.githubusercontent.com/erfinbadrian/roblox/refs/heads/main/auto.lua"

-- Anti-AFK so the farm survives the 20-min idle kick
local VirtualUser = game:GetService("VirtualUser")
LocalPlayer.Idled:Connect(function()
	VirtualUser:CaptureController()
	VirtualUser:ClickButton2(Vector3.new())
end)

if PlayerGui:FindFirstChild("CrystalFinderGui") then
	PlayerGui.CrystalFinderGui:Destroy()
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

	for _, offset in ipairs(offsets) do
		character:PivotTo(targetCFrame + offset)
		task.wait(0.1)

		local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
		if root and (root.Position - (targetCFrame.Position + offset)).Magnitude < 12 then
			return true
		end
	end

	return false
end

-- Mine one crystal: fire the game remote, then zero the prompt and fire it
local function grabCrystal(crystal)
	local sent = false
	if HoldComplete then
		sent = pcall(function()
			HoldComplete:FireServer(crystalPart(crystal))
		end)
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

-- Grab while hovering in place: no ground needed, the character is CFrame-locked
-- in mid-air for the duration of the attempt (falls normally afterwards)
local function hoverGrab(crystal)
	local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		grabCrystal(crystal)
		return
	end

	local hoverCFrame = root.CFrame
	local holding = true
	local conn = RunService.Heartbeat:Connect(function()
		if not holding then return end
		local r = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		if r then r.CFrame = hoverCFrame end
	end)

	task.wait(0.25)
	grabCrystal(crystal)

	-- One retry if the first fire did not take
	task.wait(0.5)
	if crystal.Parent and crystalAttr(crystal, "Collected") ~= true then
		grabCrystal(crystal)
	end

	local deadline = os.clock() + 1.2
	while os.clock() < deadline and crystal.Parent and crystalAttr(crystal, "Collected") ~= true do
		task.wait(0.1)
	end

	holding = false
	conn:Disconnect()
end

-- Teleport from the search list also mines the crystal
local function tpAndMine(crystal)
	if teleportTo(crystal) then
		hoverGrab(crystal)
	end
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
-- 3. SEARCH LOGIC FOR PROXIMITYPROMPT
--------------------------------------------------------------------------------

local function scanCrystals()
	for _, child in ipairs(scrollFrame:GetChildren()) do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	local minPrice = parsePrice(inputBox.Text)
	local crystalList = {}

	for _, crystal in ipairs(CrystalsFolder:GetChildren()) do
		local prompt = crystal:FindFirstChildWhichIsA("ProximityPrompt", true)
		
		if prompt then
			-- Текст может быть как в ObjectText, так и в ActionText
			local fullText = prompt.ObjectText .. " " .. prompt.ActionText
			local numericPrice, rawPriceStr = extractPriceFromPromptText(fullText)

			if numericPrice >= minPrice then
				table.insert(crystalList, {
					Object = crystal,
					Name = crystal.Name,
					Price = numericPrice,
					FullText = fullText,
					RawPrice = rawPriceStr
				})
			end
		end
	end

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

--------------------------------------------------------------------------------
-- 4. AUTO FARM LOOP
--------------------------------------------------------------------------------

local farming = false

local function setStatus(text, color)
	statusLabel.Text = text
	statusLabel.TextColor3 = color or Color3.fromRGB(220, 220, 220)
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

-- Sell everything except favorited crystals
local function sellAll()
	setStatus("Selling...", Color3.fromRGB(255, 200, 60))

	if not GoHome or not SellRequest then
		setStatus("Sell failed: remotes not found", Color3.fromRGB(255, 90, 90))
		task.wait(2)
		return
	end

	local sellableBefore = sellableWeight()

	local function unfavorite(container)
		if not container then return end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and child:GetAttribute("Favorited") == true then
				child:SetAttribute("Favorited", false)
				if ToggleFavorite then
					pcall(function() ToggleFavorite:FireServer(child, false) end)
				end
			end
		end
	end
	unfavorite(LocalPlayer:FindFirstChildOfClass("Backpack"))
	unfavorite(LocalPlayer.Character)

	pcall(function() GoHome:FireServer("sell") end)
	task.wait(0.6)
	pcall(function() SellRequest:FireServer("all") end)
	task.wait(3)

	local soldKg = math.max(0, sellableBefore - sellableWeight())
	setStatus(string.format("Sold %.1f kg (favorites kept)", soldKg), Color3.fromRGB(120, 220, 150))
end

local function findBest(minPrice)
	local best, bestPrice = nil, 0
	for _, crystal in ipairs(CrystalsFolder:GetChildren()) do
		if crystal.Parent and crystalAttr(crystal, "Collected") ~= true then
			local prompt = crystal:FindFirstChildWhichIsA("ProximityPrompt", true)
			if prompt then
				local price = extractPriceFromPromptText(prompt.ObjectText .. " " .. prompt.ActionText)
				if price >= minPrice and price > bestPrice then
					best, bestPrice = crystal, price
				end
			end
		end
	end
	return best, bestPrice
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
local function hopServer()
	if hopping then return end
	hopping = true
	setStatus("Hopping server...", Color3.fromRGB(255, 200, 60))

	local req = (syn and syn.request)
		or (http and http.request)
		or (type(http_request) == "function" and http_request)
		or (type(request) == "function" and request)

	local candidates = {}

	if req then
		local ok, res = pcall(req, {
			Url = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=2&excludeFullGames=true&limit=100",
			Method = "GET",
		})
		if ok and res and res.Body then
			local okJson, data = pcall(HttpService.JSONDecode, HttpService, res.Body)
			if okJson and type(data) == "table" and type(data.data) == "table" then
				for _, server in ipairs(data.data) do
					if server.id ~= game.JobId and (server.playing or 0) < (server.maxPlayers or 0) then
						candidates[#candidates + 1] = server.id
					end
				end
			end
		end
	end

	if #candidates == 0 then
		setStatus("Hop failed: no open servers or HTTP API unavailable", Color3.fromRGB(255, 90, 90))
		hopping = false
		return
	end

	-- Auto-resume in the next server: settings + farm state baked into the queued script
	if SCRIPT_URL ~= "" and type(queue_on_teleport) == "function" then
		queue_on_teleport(string.format(
			'getgenv().CRYSTAL_CFG={min=%q,fav=%q,autostart=%s};loadstring(game:HttpGet("%s"))()',
			inputBox.Text, favInput.Text, tostring(farming), SCRIPT_URL
		))
	else
		local reason = SCRIPT_URL == "" and "SCRIPT_URL is empty" or "executor has no queue_on_teleport"
		setStatus("Hopping WITHOUT auto-resume: " .. reason, Color3.fromRGB(255, 200, 60))
		print("[Crystal Farm] auto-resume unavailable: " .. reason)
	end

	pcall(function()
		TeleportService:TeleportToPlaceInstance(game.PlaceId, candidates[math.random(#candidates)], LocalPlayer)
	end)

	-- If the teleport never happened, allow retrying after 8s
	task.delay(8, function()
		hopping = false
	end)
end

hopBtn.MouseButton1Click:Connect(function()
	task.spawn(hopServer)
end)

local function farmLoop()
	local fails = 0
	local lastFoundAt = os.clock()

	while farming do
		-- Re-read the min price every cycle so it can be changed while farming
		local minPrice = parsePrice(inputBox.Text)
		autoFavorite()
		local best, price = findBest(minPrice)

		if not best then
			-- Auto-hop when nothing qualifying has spawned for N minutes
			local hopMin = tonumber(hopIdleInput.Text) or 0
			if hopMin > 0 and os.clock() - lastFoundAt > hopMin * 60 then
				lastFoundAt = os.clock()
				hopServer()
			end
			setStatus("Waiting for crystals >= " .. formatPrice(minPrice) .. "...")
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

				if teleportTo(best) then
					-- Hover in mid-air over the crystal: works with no ground below
					hoverGrab(best)

					local collected = not best.Parent or crystalAttr(best, "Collected") == true
					if collected then
						fails = 0
						-- Only a successful collection resets the idle/hop timer
						lastFoundAt = os.clock()
					else
						fails += 1
						setStatus("Collect failed x" .. fails .. ": " .. best.Name, Color3.fromRGB(255, 150, 90))
					end
				else
					fails += 1
					setStatus("Teleport blocked x" .. fails .. ": " .. best.Name, Color3.fromRGB(255, 150, 90))
				end

				if fails >= 3 and sellableWeight() > 0 then
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
	farmBtn.Text = "■ Stop Auto Farm"
	farmBtn.BackgroundColor3 = Color3.fromRGB(220, 80, 80)
	task.spawn(farmLoop)
end

local function stopFarm()
	farming = false
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

-- Restore settings after a server hop (baked in by queue_on_teleport)
local cfg = (getgenv and getgenv().CRYSTAL_CFG) or nil
if cfg then
	if cfg.min then inputBox.Text = cfg.min end
	if cfg.fav then favInput.Text = cfg.fav end
	if cfg.autostart then startFarm() end
end
