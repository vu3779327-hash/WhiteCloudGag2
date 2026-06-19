--[[
	Grow a Garden 2 — Auto Hub
	Features: Auto Harvest (fast) | Auto Buy Seeds | Auto Buy Gears |
	          Auto Sell | Auto Steal (Night) | Auto Collect Event Seeds
	Toggle UI: INSERT key
	Reverse-engineered from the live game's Networking (Packet) API.
]]

--========================== SERVICES ==========================--
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local CollectionService  = game:GetService("CollectionService")
local TweenService       = game:GetService("TweenService")

local LP = Players.LocalPlayer

--========================== KILL OLD INSTANCE ==========================--
if _G.__GAG2HUB and _G.__GAG2HUB.Destroy then
	pcall(_G.__GAG2HUB.Destroy)
end
local SELF = {}
_G.__GAG2HUB = SELF
local ALIVE = true
SELF.Destroy = function()
	ALIVE = false
end

--========================== NETWORKING ==========================--
local Net, StealFlags, FruitValueCalc
do
	local ok, err = pcall(function()
		Net            = require(ReplicatedStorage.SharedModules.Networking)
		StealFlags     = require(ReplicatedStorage.SharedModules.Flags.StealFlags)
		FruitValueCalc = require(ReplicatedStorage.SharedModules.FruitValueCalc)
	end)
	if not ok then
		warn("[GAG2 Hub] Failed to load game API: " .. tostring(err))
		return
	end
end

-- Sell-value of a harvest/steal target model (for "highest value first")
local function valueOf(m)
	local name = m:GetAttribute("CorePartName") or m:GetAttribute("SeedName")
	if not name then return 0 end
	local ok, v = pcall(FruitValueCalc, name, m:GetAttribute("SizeMulti") or 1,
		m:GetAttribute("Mutation"), LP, m:GetAttribute("DecayAlpha"))
	return (ok and type(v) == "number") and v or 0
end

--========================== STATE ==========================--
local F = {
	harvest        = false,
	prioHarvest    = false,   -- harvest highest-value first
	plant          = false,
	plantStack     = false,   -- stack all seeds on one spot
	plantPoint     = nil,     -- Vector3 chosen stack spot
	sell           = false,
	steal          = false,
	prioSteal      = false,   -- steal highest-value first
	antiSteal      = false,   -- hit intruders in your plot at night
	eventSeeds     = false,
	buySeeds       = false,
	buyGears       = false,
	buyPets        = false,   -- tame best-rarity wild pets
}
local seedSelected = {}   -- [name] = true
local gearSelected = {}   -- [name] = true

-- shared teleport lock so steal / event / tp-sell don't fight
local busy = false
local function acquire()
	local t0 = os.clock()
	while busy and ALIVE and os.clock() - t0 < 30 do task.wait() end
	busy = true
end
local function release() busy = false end

local function getHRP()
	local c = LP.Character
	return c and c:FindFirstChild("HumanoidRootPart"), c
end

local function safeInvoke(packet, ...)
	local args = table.pack(...)
	local ok, res = pcall(function()
		return packet:Fire(table.unpack(args, 1, args.n))
	end)
	if ok then return res end
	return nil
end

--========================== STOCK / ITEM LISTS ==========================--
local function stockFolder(shop)
	local sv = ReplicatedStorage:FindFirstChild("StockValues")
	local sh = sv and sv:FindFirstChild(shop)
	return sh and sh:FindFirstChild("Items")
end

local function listItems(shop)
	local out, f = {}, stockFolder(shop)
	if f then
		for _, v in ipairs(f:GetChildren()) do
			if v:IsA("ValueBase") then table.insert(out, v.Name) end
		end
		table.sort(out)
	end
	return out
end

local seedNames = listItems("SeedShop")
local gearNames = listItems("GearShop")
for _, n in ipairs(seedNames) do seedSelected[n] = true end
for _, n in ipairs(gearNames) do gearSelected[n] = true end

--========================== FEATURE LOOPS ==========================--

-- AUTO HARVEST (max speed) -------------------------------------
-- Runs every frame. Each ready fruit is fired at most once per 0.15s
-- so we never hammer the same fruit before the server removes it.
local harvestDebounce = {}
task.spawn(function()
	while ALIVE do
		if F.harvest then
			local myId = LP.UserId
			local tagged = CollectionService:GetTagged("HarvestPrompt")
			-- only our own ready fruit
			local list = {}
			for _, p in ipairs(tagged) do
				if p:IsA("ProximityPrompt") and p.Parent and p:IsDescendantOf(workspace) then
					local m = p.Parent:FindFirstAncestorWhichIsA("Model")
					if m and tonumber(m:GetAttribute("UserId")) == myId and m:GetAttribute("PlantId") then
						list[#list + 1] = { m = m, v = F.prioHarvest and valueOf(m) or 0 }
					end
				end
			end
			if F.prioHarvest then
				table.sort(list, function(a, b) return a.v > b.v end)
			end
			for _, e in ipairs(list) do
				if not F.harvest then break end
				local m = e.m
				local pid = m:GetAttribute("PlantId")
				local fid = m:GetAttribute("FruitId")
				local key = tostring(pid) .. "|" .. tostring(fid)
				local now = os.clock()
				if not harvestDebounce[key] or now - harvestDebounce[key] > 0.15 then
					harvestDebounce[key] = now
					pcall(function() Net.Garden.CollectFruit:Fire(pid, fid or "") end)
				end
			end
			if #tagged == 0 then table.clear(harvestDebounce) end
		end
		RunService.Heartbeat:Wait()
	end
end)

-- AUTO SELL (remote, no teleport) ------------------------------
-- Fires the same SellAll remote the game's "Sell Inventory!" button
-- uses, from wherever you're standing. Self-paces on the server
-- response, so there's no configurable interval.
task.spawn(function()
	while ALIVE do
		if F.sell then
			local preview = safeInvoke(Net.NPCS.PreviewSellAll)
			if preview and (preview.FruitCount or 0) > 0 then
				safeInvoke(Net.NPCS.SellAll)
			end
		end
		task.wait(0.2)
	end
end)

-- AUTO PLANT SEEDS --------------------------------------------
-- Spread mode: plants every seed onto free, spaced slots in your plot.
-- Stack mode: dumps every seed onto one chosen spot (Plant.PlantSeed).
local function groundPointUnder(pos)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = CollectionService:GetTagged("PlantArea")
	local r = workspace:Raycast(pos + Vector3.new(0, 12, 0), Vector3.new(0, -60, 0), params)
	return r and r.Position
end
local function currentStackPoint()
	if F.plantPoint then return F.plantPoint end
	local hrp = getHRP()
	if not hrp then return nil end
	return groundPointUnder(hrp.Position) or (hrp.Position - Vector3.new(0, 2.5, 0))
end

local function autoPlantOnce()
	local plotId = LP:GetAttribute("PlotId")
	local plot = plotId and workspace:FindFirstChild("Gardens") and workspace.Gardens:FindFirstChild("Plot" .. tostring(plotId))
	if not plot then return end

	-- collect seed tools (Backpack + Character)
	local seedTools = {}
	local function scan(c) if c then for _, t in ipairs(c:GetChildren()) do
		if t:IsA("Tool") and t:GetAttribute("SeedTool") ~= nil then table.insert(seedTools, t) end
	end end end
	scan(LP:FindFirstChildOfClass("Backpack"))
	scan(LP.Character)
	if #seedTools == 0 then return end

	-- STACK MODE: every seed onto a single spot
	if F.plantStack then
		local pt = currentStackPoint()
		if not pt then return end
		local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
		for _, tool in ipairs(seedTools) do
			if not (F.plant and F.plantStack) then break end
			local seedName = tool:GetAttribute("SeedTool")
			local count = tool:GetAttribute("Count") or 1
			if hum then pcall(function() hum:EquipTool(tool) end) end
			for _ = 1, count do
				if not (F.plant and F.plantStack) or not tool.Parent then break end
				pcall(function() Net.Plant.PlantSeed:Fire(pt, seedName, tool) end)
				task.wait(0.07)
			end
		end
		return
	end

	-- spatial buckets of existing plants for spacing checks
	local CELL, MIN2 = 2, 1.3 * 1.3
	local buckets = {}
	local function bk(cx, cz) return cx .. "," .. cz end
	local function addPt(p)
		local cx, cz = math.floor(p.X / CELL), math.floor(p.Z / CELL)
		local key = bk(cx, cz); local b = buckets[key]
		if not b then b = {}; buckets[key] = b end
		table.insert(b, p)
	end
	local function tooClose(p)
		local cx, cz = math.floor(p.X / CELL), math.floor(p.Z / CELL)
		for dx = -1, 1 do for dz = -1, 1 do
			local b = buckets[bk(cx + dx, cz + dz)]
			if b then for _, q in ipairs(b) do
				local ax, az = p.X - q.X, p.Z - q.Z
				if ax * ax + az * az < MIN2 then return true end
			end end
		end end
		return false
	end
	local plantsFolder = plot:FindFirstChild("Plants")
	if plantsFolder then for _, pl in ipairs(plantsFolder:GetChildren()) do
		local ok, cf = pcall(function() return pl:GetPivot() end)
		local p = ok and cf.Position or (pl:IsA("BasePart") and pl.Position)
		if p then addPt(p) end
	end end

	-- generate free planting slots over the flat PlantArea parts in my plot
	local GAP = 2.5
	local slots = {}
	for _, pa in ipairs(CollectionService:GetTagged("PlantArea")) do
		if pa:IsA("BasePart") and pa.Size.Y < 1 and pa:IsDescendantOf(plot) then
			local sx, sz = pa.Size.X, pa.Size.Z
			local lx = -sx / 2 + GAP / 2
			while lx < sx / 2 do
				local lz = -sz / 2 + GAP / 2
				while lz < sz / 2 do
					local world = (pa.CFrame * CFrame.new(lx, pa.Size.Y / 2 + 0.05, lz)).Position
					if not tooClose(world) then
						addPt(world)
						table.insert(slots, world)
					end
					lz = lz + GAP
				end
				lx = lx + GAP
			end
		end
	end
	if #slots == 0 then return end

	-- plant each seed tool's stack across free slots
	local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
	local si = 1
	for _, tool in ipairs(seedTools) do
		if not F.plant or si > #slots then break end
		local seedName = tool:GetAttribute("SeedTool")
		local count = tool:GetAttribute("Count") or 1
		if hum then pcall(function() hum:EquipTool(tool) end) end
		for _ = 1, count do
			if not F.plant or si > #slots then break end
			if not tool.Parent then break end
			local pos = slots[si]; si = si + 1
			pcall(function() Net.Plant.PlantSeed:Fire(pos, seedName, tool) end)
			task.wait(0.07)
		end
	end
end
task.spawn(function()
	while ALIVE do
		if F.plant then pcall(autoPlantOnce) end
		task.wait(0.6)
	end
end)

-- AUTO BUY SEEDS ----------------------------------------------
task.spawn(function()
	while ALIVE do
		if F.buySeeds then
			local f = stockFolder("SeedShop")
			if f then
				for _, v in ipairs(f:GetChildren()) do
					if v:IsA("ValueBase") and v.Value > 0 and seedSelected[v.Name] then
						local n = math.min(v.Value, 50)
						for _ = 1, n do
							pcall(function() Net.SeedShop.PurchaseSeed:Fire(v.Name) end)
							task.wait(0.06)
						end
					end
				end
			end
		end
		task.wait(1.5)
	end
end)

-- AUTO BUY GEARS ----------------------------------------------
task.spawn(function()
	while ALIVE do
		if F.buyGears then
			local f = stockFolder("GearShop")
			if f then
				for _, v in ipairs(f:GetChildren()) do
					if v:IsA("ValueBase") and v.Value > 0 and gearSelected[v.Name] then
						local n = math.min(v.Value, 50)
						for _ = 1, n do
							pcall(function() Net.GearShop.PurchaseGear:Fire(v.Name) end)
							task.wait(0.06)
						end
					end
				end
			end
		end
		task.wait(1.5)
	end
end)

-- AUTO BUY BEST WILD PET --------------------------------------
-- Wild pets roam the map (workspace.Map.WildPetRef). Unowned ones
-- (OwnerUserId == 0) can be tamed for their Price via WildPetTame.
-- Buys the highest-rarity affordable pet first.
local RARITY_RANK = {
	Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5,
	Mythic = 6, Mythical = 6, Godly = 7, Divine = 8, Secret = 9, Prismatic = 10,
}
local function pickBestWildPet(refFolder)
	local best, bestRank
	for _, ref in ipairs(refFolder:GetChildren()) do
		if ref:IsA("BasePart") and (ref:GetAttribute("OwnerUserId") or 0) == 0 then
			local r = ref:GetAttribute("Rarity")
			local rank = (r and RARITY_RANK[r]) or 0
			local price = ref:GetAttribute("Price") or 0
			if not best or rank > bestRank
				or (rank == bestRank and price > (best:GetAttribute("Price") or 0)) then
				best, bestRank = ref, rank
			end
		end
	end
	return best
end
task.spawn(function()
	while ALIVE do
		if F.buyPets then
			local map = workspace:FindFirstChild("Map")
			local refFolder = map and map:FindFirstChild("WildPetRef")
			local best = refFolder and pickBestWildPet(refFolder)
			local hrp = getHRP()
			if best and hrp then
				acquire()
				local saved = hrp.CFrame
				-- lock onto the (wandering) pet and tame until owned / gone / timeout
				local t0 = os.clock()
				while F.buyPets and best.Parent
					and (best:GetAttribute("OwnerUserId") or 0) == 0
					and os.clock() - t0 < 60 do
					local h2 = getHRP()
					if h2 then h2.CFrame = CFrame.new(best.Position + Vector3.new(0, 3, 2)) end
					pcall(function() Net.Pets.WildPetTame:Fire(best) end)
					task.wait(0.1)
				end
				local hb = getHRP()
				if hb then hb.CFrame = saved end
				release()
			end
		end
		task.wait(0.5)
	end
end)

-- AUTO COLLECT EVENT SEEDS ------------------------------------
task.spawn(function()
	while ALIVE do
		if F.eventSeeds then
			local map = workspace:FindFirstChild("Map")
			local locs = map and map:FindFirstChild("SeedPackSpawnServerLocations")
			if locs and #locs:GetChildren() > 0 then
				local hrp = getHRP()
				if hrp then
					acquire()
					local saved = hrp.CFrame
					for _, marker in ipairs(locs:GetChildren()) do
						if not F.eventSeeds then break end
						local cf = marker:IsA("BasePart") and marker.CFrame
							or (marker:IsA("Model") and select(1, pcall(function() return marker:GetPivot() end)) and marker:GetPivot())
						if cf then
							hrp.CFrame = cf + Vector3.new(0, 3, 0)
							task.wait(0.25)
						end
					end
					local h2 = getHRP()
					if h2 then h2.CFrame = saved end
					release()
				end
			end
		end
		task.wait(1)
	end
end)

-- AUTO STEAL (NIGHT) ------------------------------------------
local function gardenPos(g)
	if g:IsA("Model") then
		local ok, cf = pcall(function() return g:GetPivot() end)
		if ok then return cf.Position end
	end
	local bp = g:FindFirstChildWhichIsA("BasePart", true)
	return bp and bp.Position
end

local function isNight()
	local n = ReplicatedStorage:FindFirstChild("Night")
	return n ~= nil and n.Value == true
end

task.spawn(function()
	while ALIVE do
		if F.steal and isNight() then
			local hrp = getHRP()
			if hrp then
				acquire()
				local saved = hrp.CFrame
				-- gather every loaded, stealable target that isn't ours
				local list = {}
				for _, prompt in ipairs(CollectionService:GetTagged("StealPrompt")) do
					if prompt:IsA("ProximityPrompt") and prompt.Parent and prompt:IsDescendantOf(workspace) then
						local m = prompt.Parent:FindFirstAncestorWhichIsA("Model")
						if m then
							local uid = tonumber(m:GetAttribute("UserId"))
							local pid = m:GetAttribute("PlantId")
							local seed = m:GetAttribute("SeedName") or m:GetAttribute("CorePartName")
							if uid and uid ~= LP.UserId and pid and StealFlags.IsPlantStealable(seed) then
								list[#list + 1] = {
									m = m, pr = prompt, uid = uid, pid = pid,
									fid = m:GetAttribute("FruitId"), seed = seed,
									v = F.prioSteal and valueOf(m) or 0,
								}
							end
						end
					end
				end
				if F.prioSteal then
					table.sort(list, function(a, b) return a.v > b.v end)
				end
				for _, e in ipairs(list) do
					if not (F.steal and isNight()) then break end
					if e.m and e.m.Parent then
						local hold = e.pr.HoldDuration
						if hold == nil or hold == 0 then hold = StealFlags.GetStealHoldDuration(e.seed) end
						local h2 = getHRP()
						if h2 then h2.CFrame = e.m:GetPivot() * CFrame.new(0, 3, 0) end
						pcall(function() Net.Steal.BeginSteal:Fire(e.uid, e.pid, e.fid or "") end)
						if hold and hold > 0 then task.wait(hold + 0.15) end
						pcall(function() Net.Steal.CompleteSteal:Fire() end)
						task.wait(0.1)
					end
				end
				local hb = getHRP()
				if hb then hb.CFrame = saved end
				release()
			end
		end
		task.wait(F.steal and 0.5 or 1)
	end
end)

-- ANTI STEAL (night) ------------------------------------------
-- When another player is inside your plot at night, equip your shovel,
-- teleport onto them facing them, and hit them (server needs dist<=12,
-- facing dot>=0.3): Shovel.SwingShovel + Shovel.HitPlayer(userId).
local function findShovel()
	local function scan(c) if c then for _, t in ipairs(c:GetChildren()) do
		if t:IsA("Tool") and t:GetAttribute("Shovel") ~= nil then return t end
	end end end
	return scan(LP.Character) or scan(LP:FindFirstChildOfClass("Backpack"))
end
local function findIntruders()
	local pid = LP:GetAttribute("PlotId")
	local out = {}
	if not pid then return out end
	local gzd = ReplicatedStorage:FindFirstChild("GardenZoneData")
	if not gzd then return out end
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then
			local v = gzd:FindFirstChild(p.Name)
			local ch = p.Character
			if v and v.Value == pid and ch and ch:FindFirstChild("HumanoidRootPart") then
				out[#out + 1] = p
			end
		end
	end
	return out
end
task.spawn(function()
	while ALIVE do
		if F.antiSteal and isNight() then
			local intruders = findIntruders()
			local shovel = findShovel()
			local hrp = getHRP()
			if #intruders > 0 and shovel and hrp then
				acquire()
				local saved = hrp.CFrame
				local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
				if hum then pcall(function() hum:EquipTool(shovel) end) end
				for _, p in ipairs(intruders) do
					if not (F.antiSteal and isNight()) then break end
					local ch = p.Character
					local tHRP = ch and ch:FindFirstChild("HumanoidRootPart")
					if tHRP then
						local tp = tHRP.Position
						local h2 = getHRP()
						if h2 then h2.CFrame = CFrame.new(tp + Vector3.new(0, 0, 5), tp) end
						pcall(function() Net.Shovel.SwingShovel:Fire() end)
						pcall(function() Net.Shovel.HitPlayer:Fire(p.UserId) end)
						task.wait(0.66) -- server swing cooldown is 0.65s
					end
				end
				local hb = getHRP()
				if hb then hb.CFrame = saved end
				release()
			end
		end
		task.wait(F.antiSteal and 0.2 or 1)
	end
end)

--========================================================================--
--                                  GUI                                    --
--========================================================================--
local ACCENT   = Color3.fromRGB(126, 217, 87)   -- garden green
local ACCENT2  = Color3.fromRGB(88, 180, 120)
local BG       = Color3.fromRGB(20, 22, 27)
local BG2      = Color3.fromRGB(28, 31, 38)
local CARD     = Color3.fromRGB(34, 38, 46)
local STROKE   = Color3.fromRGB(52, 58, 68)
local TXT      = Color3.fromRGB(235, 238, 242)
local SUB      = Color3.fromRGB(150, 158, 168)

local function corner(p, r)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 8); c.Parent = p; return c
end
local function stroke(p, col, th)
	local s = Instance.new("UIStroke"); s.Color = col or STROKE; s.Thickness = th or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; s.Parent = p; return s
end
local function pad(p, n)
	local u = Instance.new("UIPadding")
	u.PaddingLeft = UDim.new(0, n); u.PaddingRight = UDim.new(0, n)
	u.PaddingTop = UDim.new(0, n); u.PaddingBottom = UDim.new(0, n)
	u.Parent = p; return u
end

local function getParentGui()
	local g
	local ok = pcall(function() g = gethui and gethui() end)
	if ok and g then return g end
	ok = pcall(function() g = game:GetService("CoreGui") end)
	if ok and g then return g end
	return LP:WaitForChild("PlayerGui")
end

local old = getParentGui():FindFirstChild("GAG2Hub")
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "GAG2Hub"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true
gui.Parent = getParentGui()

-- update SELF.Destroy to also remove the gui
SELF.Destroy = function()
	ALIVE = false
	if gui then gui:Destroy() end
end

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(500, 380)
main.Position = UDim2.new(0.5, -250, 0.5, -190)
main.BackgroundColor3 = BG
main.BorderSizePixel = 0
main.Parent = gui
corner(main, 12)
stroke(main, STROKE, 1)

-- title bar
local bar = Instance.new("Frame")
bar.Size = UDim2.new(1, 0, 0, 46)
bar.BackgroundColor3 = BG2
bar.BorderSizePixel = 0
bar.Parent = main
corner(bar, 12)
local barFix = Instance.new("Frame")
barFix.Size = UDim2.new(1, 0, 0, 14); barFix.Position = UDim2.new(0, 0, 1, -14)
barFix.BackgroundColor3 = BG2; barFix.BorderSizePixel = 0; barFix.Parent = bar

local dot = Instance.new("Frame")
dot.Size = UDim2.fromOffset(12, 12); dot.Position = UDim2.fromOffset(16, 17)
dot.BackgroundColor3 = ACCENT; dot.BorderSizePixel = 0; dot.Parent = bar
corner(dot, 6)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(38, 7)
title.Size = UDim2.new(1, -120, 0, 20)
title.Font = Enum.Font.GothamBold
title.Text = "Grow a Garden 2  •  Auto Hub"
title.TextSize = 15
title.TextColor3 = TXT
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = bar

local subtitle = Instance.new("TextLabel")
subtitle.BackgroundTransparency = 1
subtitle.Position = UDim2.fromOffset(38, 25)
subtitle.Size = UDim2.new(1, -120, 0, 14)
subtitle.Font = Enum.Font.Gotham
subtitle.Text = "INSERT to hide / show"
subtitle.TextSize = 11
subtitle.TextColor3 = SUB
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.Parent = bar

-- drag
do
	local dragging, ds, sp
	bar.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true; ds = i.Position; sp = main.Position
			i.Changed:Connect(function()
				if i.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - ds
			main.Position = UDim2.new(sp.X.Scale, sp.X.Offset + d.X, sp.Y.Scale, sp.Y.Offset + d.Y)
		end
	end)
end

--------------------------------------------------------------- tabs
local tabBar = Instance.new("Frame")
tabBar.Position = UDim2.fromOffset(12, 54)
tabBar.Size = UDim2.new(0, 130, 1, -66)
tabBar.BackgroundColor3 = BG2
tabBar.BorderSizePixel = 0
tabBar.Parent = main
corner(tabBar, 10)
local tabList = Instance.new("UIListLayout")
tabList.Padding = UDim.new(0, 6); tabList.Parent = tabBar
pad(tabBar, 8)

local content = Instance.new("Frame")
content.Position = UDim2.fromOffset(152, 54)
content.Size = UDim2.new(1, -164, 1, -66)
content.BackgroundTransparency = 1
content.Parent = main

local pages, tabs = {}, {}
local function selectTab(name)
	for n, pg in pairs(pages) do pg.Visible = (n == name) end
	for n, b in pairs(tabs) do
		local on = (n == name)
		TweenService:Create(b, TweenInfo.new(0.15), {BackgroundColor3 = on and ACCENT or CARD}):Play()
		b.TextColor3 = on and Color3.fromRGB(18, 22, 18) or TXT
		b.Font = on and Enum.Font.GothamBold or Enum.Font.GothamMedium
	end
end
local function addTab(name)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 34)
	b.BackgroundColor3 = CARD
	b.AutoButtonColor = false
	b.Text = name
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 13
	b.TextColor3 = TXT
	b.BorderSizePixel = 0
	b.Parent = tabBar
	corner(b, 8)
	tabs[name] = b
	local page = Instance.new("ScrollingFrame")
	page.Size = UDim2.fromScale(1, 1)
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.ScrollBarThickness = 4
	page.ScrollBarImageColor3 = STROKE
	page.CanvasSize = UDim2.new()
	page.Visible = false
	page.Parent = content
	local l = Instance.new("UIListLayout")
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, 8); l.Parent = page
	l:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		page.CanvasSize = UDim2.new(0, 0, 0, l.AbsoluteContentSize.Y + 12)
	end)
	pages[name] = page
	b.MouseButton1Click:Connect(function() selectTab(name) end)
	return page
end

--------------------------------------------------------------- widgets
-- Global incrementing layout order so headers/rows keep insertion order
-- (UIListLayout otherwise breaks LayoutOrder ties by class name).
local LO = 0
local function ord() LO = LO + 1; return LO end

local function sectionLabel(parent, txt)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, 0, 0, 18)
	l.LayoutOrder = ord()
	l.BackgroundTransparency = 1
	l.Text = string.upper(txt)
	l.Font = Enum.Font.GothamBold
	l.TextSize = 11
	l.TextColor3 = SUB
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

local function toggleRow(parent, label, key, onChange)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 40)
	row.LayoutOrder = ord()
	row.BackgroundColor3 = CARD
	row.BorderSizePixel = 0
	row.Parent = parent
	corner(row, 8)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Position = UDim2.fromOffset(12, 0)
	t.Size = UDim2.new(1, -70, 1, 0)
	t.Text = label
	t.Font = Enum.Font.GothamMedium
	t.TextSize = 13
	t.TextColor3 = TXT
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.Parent = row

	local pill = Instance.new("TextButton")
	pill.AnchorPoint = Vector2.new(1, 0.5)
	pill.Position = UDim2.new(1, -12, 0.5, 0)
	pill.Size = UDim2.fromOffset(44, 22)
	pill.BackgroundColor3 = STROKE
	pill.Text = ""
	pill.AutoButtonColor = false
	pill.Parent = row
	corner(pill, 11)
	local knob = Instance.new("Frame")
	knob.Size = UDim2.fromOffset(18, 18)
	knob.Position = UDim2.fromOffset(2, 2)
	knob.BackgroundColor3 = Color3.fromRGB(235, 238, 242)
	knob.BorderSizePixel = 0
	knob.Parent = pill
	corner(knob, 9)

	local function render()
		local on = F[key]
		TweenService:Create(pill, TweenInfo.new(0.15), {BackgroundColor3 = on and ACCENT or STROKE}):Play()
		TweenService:Create(knob, TweenInfo.new(0.15), {Position = on and UDim2.fromOffset(24, 2) or UDim2.fromOffset(2, 2)}):Play()
	end
	pill.MouseButton1Click:Connect(function()
		F[key] = not F[key]
		render()
		if onChange then onChange(F[key]) end
	end)
	render()
	return row
end

local function numberRow(parent, label, key, suffix)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 40)
	row.BackgroundColor3 = CARD
	row.BorderSizePixel = 0
	row.Parent = parent
	corner(row, 8)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Position = UDim2.fromOffset(12, 0)
	t.Size = UDim2.new(1, -110, 1, 0)
	t.Text = label
	t.Font = Enum.Font.GothamMedium
	t.TextSize = 13
	t.TextColor3 = TXT
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.Parent = row
	local box = Instance.new("TextBox")
	box.AnchorPoint = Vector2.new(1, 0.5)
	box.Position = UDim2.new(1, -12, 0.5, 0)
	box.Size = UDim2.fromOffset(80, 26)
	box.BackgroundColor3 = BG
	box.Text = tostring(F[key]) .. (suffix or "")
	box.Font = Enum.Font.GothamMedium
	box.TextSize = 12
	box.TextColor3 = ACCENT
	box.ClearTextOnFocus = false
	box.Parent = row
	corner(box, 6)
	stroke(box, STROKE, 1)
	box.FocusLost:Connect(function()
		local n = tonumber(box.Text:gsub("[^%d%.]", ""))
		if n then F[key] = n end
		box.Text = tostring(F[key]) .. (suffix or "")
	end)
	return row
end

local function buttonRow(parent, label, btnText, cb)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 40)
	row.LayoutOrder = ord()
	row.BackgroundColor3 = CARD
	row.BorderSizePixel = 0
	row.Parent = parent
	corner(row, 8)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Position = UDim2.fromOffset(12, 0)
	t.Size = UDim2.new(1, -110, 1, 0)
	t.Text = label
	t.Font = Enum.Font.GothamMedium
	t.TextSize = 13
	t.TextColor3 = TXT
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.Parent = row
	local b = Instance.new("TextButton")
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.new(1, -12, 0.5, 0)
	b.Size = UDim2.fromOffset(86, 26)
	b.BackgroundColor3 = ACCENT
	b.Text = btnText
	b.Font = Enum.Font.GothamBold
	b.TextSize = 12
	b.TextColor3 = Color3.fromRGB(18, 22, 18)
	b.AutoButtonColor = true
	b.Parent = row
	corner(b, 6)
	b.MouseButton1Click:Connect(function() cb(b) end)
	return row, b
end

-- multi-select checklist for shop items
local function checklist(parent, names, store)
	local box = Instance.new("Frame")
	box.Size = UDim2.new(1, 0, 0, 156)
	box.LayoutOrder = ord()
	box.BackgroundColor3 = CARD
	box.BorderSizePixel = 0
	box.Parent = parent
	corner(box, 8)
	-- header w/ all / none
	local hdr = Instance.new("Frame")
	hdr.Size = UDim2.new(1, 0, 0, 28); hdr.BackgroundTransparency = 1; hdr.Parent = box
	local function miniBtn(txt, xoff)
		local b = Instance.new("TextButton")
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, xoff, 0.5, 0)
		b.Size = UDim2.fromOffset(46, 20)
		b.BackgroundColor3 = BG
		b.Text = txt; b.Font = Enum.Font.GothamMedium; b.TextSize = 11; b.TextColor3 = TXT
		b.Parent = hdr; corner(b, 6); stroke(b, STROKE, 1)
		return b
	end
	local sc = Instance.new("ScrollingFrame")
	sc.Position = UDim2.fromOffset(0, 28)
	sc.Size = UDim2.new(1, 0, 1, -28)
	sc.BackgroundTransparency = 1
	sc.BorderSizePixel = 0
	sc.ScrollBarThickness = 4
	sc.ScrollBarImageColor3 = STROKE
	sc.CanvasSize = UDim2.new()
	sc.Parent = box
	local ll = Instance.new("UIListLayout"); ll.Padding = UDim.new(0, 3); ll.Parent = sc
	ll:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		sc.CanvasSize = UDim2.new(0, 0, 0, ll.AbsoluteContentSize.Y + 12)
	end)
	pad(sc, 6)

	local rows = {}
	for _, name in ipairs(names) do
		local r = Instance.new("TextButton")
		r.Size = UDim2.new(1, -6, 0, 24)
		r.BackgroundColor3 = BG
		r.AutoButtonColor = false
		r.Text = ""
		r.Parent = sc
		corner(r, 6)
		local cb = Instance.new("Frame")
		cb.Position = UDim2.fromOffset(6, 5)
		cb.Size = UDim2.fromOffset(14, 14)
		cb.BackgroundColor3 = store[name] and ACCENT or STROKE
		cb.BorderSizePixel = 0
		cb.Parent = r
		corner(cb, 4)
		local nm = Instance.new("TextLabel")
		nm.BackgroundTransparency = 1
		nm.Position = UDim2.fromOffset(28, 0)
		nm.Size = UDim2.new(1, -32, 1, 0)
		nm.Text = name
		nm.Font = Enum.Font.Gotham
		nm.TextSize = 12
		nm.TextColor3 = TXT
		nm.TextXAlignment = Enum.TextXAlignment.Left
		nm.Parent = r
		local function paint() cb.BackgroundColor3 = store[name] and ACCENT or STROKE end
		r.MouseButton1Click:Connect(function() store[name] = not store[name]; paint() end)
		rows[name] = paint
	end
	miniBtn("None", -6).MouseButton1Click:Connect(function()
		for _, n in ipairs(names) do store[n] = false; rows[n]() end
	end)
	miniBtn("All", -56).MouseButton1Click:Connect(function()
		for _, n in ipairs(names) do store[n] = true; rows[n]() end
	end)
	return box
end

--------------------------------------------------------------- FARM PAGE
local farm = addTab("Farm")
sectionLabel(farm, "Automation")
toggleRow(farm, "Auto Harvest  (instant)", "harvest")
toggleRow(farm, "Harvest highest value first", "prioHarvest")
toggleRow(farm, "Auto Plant Seeds", "plant")
toggleRow(farm, "Plant: stack on one spot", "plantStack")
buttonRow(farm, "Stack spot (stand here)", "Set spot", function(b)
	local hrp = getHRP()
	if hrp then
		F.plantPoint = groundPointUnder(hrp.Position) or (hrp.Position - Vector3.new(0, 2.5, 0))
		b.Text = "Set \xE2\x9C\x93"
		task.delay(1.5, function() if b and b.Parent then b.Text = "Set spot" end end)
	end
end)
toggleRow(farm, "Auto Sell Inventory", "sell")
sectionLabel(farm, "Night & Events")
toggleRow(farm, "Auto Steal  (night only)", "steal")
toggleRow(farm, "Steal highest value first", "prioSteal")
toggleRow(farm, "Anti-Steal  (hit intruders)", "antiSteal")
toggleRow(farm, "Auto Collect Event Seeds", "eventSeeds")

--------------------------------------------------------------- SHOP PAGE
local shop = addTab("Shop")
sectionLabel(shop, "Seeds")
toggleRow(shop, "Auto Buy Seeds", "buySeeds")
checklist(shop, seedNames, seedSelected)
sectionLabel(shop, "Gears")
toggleRow(shop, "Auto Buy Gears", "buyGears")
checklist(shop, gearNames, gearSelected)
sectionLabel(shop, "Pets")
toggleRow(shop, "Auto Buy Best Wild Pet", "buyPets")

--------------------------------------------------------------- INFO PAGE
local info = addTab("Info")
sectionLabel(info, "Status")
local statusCard = Instance.new("Frame")
statusCard.Size = UDim2.new(1, 0, 0, 110)
statusCard.BackgroundColor3 = CARD
statusCard.BorderSizePixel = 0
statusCard.Parent = info
corner(statusCard, 8)
local stext = Instance.new("TextLabel")
stext.BackgroundTransparency = 1
stext.Size = UDim2.fromScale(1, 1)
stext.Font = Enum.Font.Gotham
stext.TextSize = 12
stext.TextColor3 = SUB
stext.TextXAlignment = Enum.TextXAlignment.Left
stext.TextYAlignment = Enum.TextYAlignment.Top
stext.Text = ""
stext.Parent = statusCard
pad(statusCard, 12)

task.spawn(function()
	while ALIVE do
		local night = isNight()
		stext.Text = string.format(
			"Player:  %s\nGarden:  detected\nNight:  %s\nActive:  %s%s%s%s%s%s",
			LP.Name,
			night and "YES (steal ready)" or "no",
			F.harvest and "Harvest " or "",
			F.sell and "Sell " or "",
			F.steal and "Steal " or "",
			F.eventSeeds and "Events " or "",
			F.buySeeds and "BuySeeds " or "",
			F.buyGears and "BuyGears" or ""
		)
		task.wait(0.5)
	end
end)

selectTab("Farm")

--------------------------------------------------------------- INSERT toggle
UserInputService.InputBegan:Connect(function(i, gpe)
	if gpe then return end
	if i.KeyCode == Enum.KeyCode.Insert then
		main.Visible = not main.Visible
	end
end)

-- intro pop
main.Size = UDim2.fromOffset(0, 0)
TweenService:Create(main, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	{Size = UDim2.fromOffset(500, 380)}):Play()

print("[GAG2 Hub] Loaded. Press INSERT to toggle the menu.")
