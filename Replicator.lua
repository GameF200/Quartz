local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Replicator = {}

local cache = {
	workspace = nil,
	rateLimitConfigs = {},
	buffers = {}
}

local RateLimiter = {
	defaults = {
		maxRequests = 10,
		timeWindow = 1,
		penaltyTime = 5
	},
	buckets = {}
}

function RateLimiter:check(eventName, player, maxRequests, timeWindow)
	if not RunService:IsServer() then return true end
	if not player or not player:IsA("Player") then return true end

	maxRequests = maxRequests or self.defaults.maxRequests
	timeWindow = timeWindow or self.defaults.timeWindow

	local userId = player.UserId
	local now = os.clock()

	if not self.buckets[eventName] then
		self.buckets[eventName] = {}
	end

	local bucket = self.buckets[eventName][userId]
	if not bucket then
		bucket = {
			tokens = maxRequests,
			lastRefill = now,
			maxTokens = maxRequests,
			refillRate = maxRequests / timeWindow,
			isPenalized = false,
			penaltyUntil = 0
		}
		self.buckets[eventName][userId] = bucket
	end

	if bucket.isPenalized then
		if now < bucket.penaltyUntil then
			warn(`[Quartz RateLimit] {player.Name} is rate limited for {eventName} until {bucket.penaltyUntil - now} seconds`)
			return false
		else
			bucket.isPenalized = false
			bucket.tokens = maxRequests
			bucket.lastRefill = now
		end
	end

	local timePassed = now - bucket.lastRefill
	bucket.tokens = math.min(bucket.maxTokens, bucket.tokens + (timePassed * bucket.refillRate))
	bucket.lastRefill = now

	if bucket.tokens >= 1 then
		bucket.tokens = bucket.tokens - 1
		return true
	else
		bucket.isPenalized = true
		bucket.penaltyUntil = now + self.defaults.penaltyTime
		warn(`[Quartz RateLimit] {player.Name} exceeded rate limit for {eventName}. Penalized for {self.defaults.penaltyTime} seconds`)
		return false
	end
end

function RateLimiter:getRemainingTokens(eventName, player)
	if not self.buckets[eventName] or not self.buckets[eventName][player.UserId] then
		return self.defaults.maxRequests
	end
	return math.floor(self.buckets[eventName][player.UserId].tokens)
end

function RateLimiter:reset(eventName, player)
	if player then
		if self.buckets[eventName] then
			self.buckets[eventName][player.UserId] = nil
		end
	else
		self.buckets[eventName] = {}
	end
end

if RunService:IsServer() then
	Players.PlayerRemoving:Connect(function(player)
		for eventName in pairs(RateLimiter.buckets) do
			if RateLimiter.buckets[eventName] then
				RateLimiter.buckets[eventName][player.UserId] = nil
			end
		end
	end)
end

local function initialize_workspace()
	if cache.workspace then
		return cache.workspace
	end

	local workspace = ReplicatedStorage:FindFirstChild("Quartz_RunTime")
	if not workspace then
		workspace = Instance.new("Folder")
		workspace.Name = "Quartz_RunTime"
		workspace.Parent = ReplicatedStorage
	end

	cache.workspace = workspace
	return workspace
end

local function get_remote(name, className)
	local workspace = initialize_workspace()

	if not RunService:IsServer() then
		local remote = workspace:WaitForChild(name)
		if remote.ClassName ~= className then
			warn(`[Quartz] Expected {className} but found {remote.ClassName} for {name}. This may cause issues.`)
		end
		return remote
	end

	local remote = workspace:FindFirstChild(name)

	if not remote or remote.ClassName ~= className then
		if remote then
			remote:Destroy()
		end

		remote = Instance.new(className)
		remote.Name = name
		remote.Parent = workspace
	end

	return remote
end

local function create_buffer(name, maxSize, flushInterval)
	if not cache.buffers[name] then
		cache.buffers[name] = {
			data = {},
			maxSize = maxSize or 10,
			flushInterval = flushInterval or 0.1,
			lastFlush = os.clock(),
			callbacks = {}
		}
	end
	return cache.buffers[name]
end

local function flush_buffer(buffer, target, sendMethod)
	if #buffer.data == 0 then return end

	local dataCopy = buffer.data
	buffer.data = {}
	buffer.lastFlush = os.clock()

	for _, callback in ipairs(buffer.callbacks) do
		callback(dataCopy)
	end

	if target then
		if type(target) == "table" then
			for _, player in ipairs(target) do
				sendMethod(player, dataCopy)
			end
		else
			sendMethod(target, dataCopy)
		end
	else
		sendMethod(dataCopy)
	end
end

function Replicator.get_event(name)
	if RunService:IsServer() then
		error("[Quartz] Use new_event() on server to create events")
	end

	local workspace = initialize_workspace()
	local event: RemoteEvent = workspace:WaitForChild(name)
	
	return {
		Instance = event,
		
		SendPacket = function(...)
			event:FireServer(...)
		end,
		OnClientEvent = function(callback)
			return event.OnClientEvent:Connect(callback)
		end,
		CreateBuffer = function(maxSize, flushInterval)
			local buffer = create_buffer(name, maxSize, flushInterval)

			return {
				Add = function(data)
					table.insert(buffer.data, data)

					if #buffer.data >= buffer.maxSize then
						flush_buffer(buffer, nil, function(batchData)
							event:FireServer(batchData)
						end)
					elseif os.clock() - buffer.lastFlush >= buffer.flushInterval then
						flush_buffer(buffer, nil, function(batchData)
							event:FireServer(batchData)
						end)
					end
				end,

				Flush = function()
					flush_buffer(buffer, nil, function(batchData)
						event:FireServer(batchData)
					end)
				end,

				OnFlush = function(callback)
					table.insert(buffer.callbacks, callback)
				end,

				Clear = function()
					buffer.data = {}
				end,

				GetSize = function()
					return #buffer.data
				end
			}
		end,
		SendBuffered = function(data, maxSize, flushInterval)
			local bufferKey = name .. "_all"
			local buffer = create_buffer(bufferKey, maxSize, flushInterval)

			table.insert(buffer.data, data)

			if #buffer.data >= buffer.maxSize or os.clock() - buffer.lastFlush >= buffer.flushInterval then
				flush_buffer(buffer, nil, function(batchData)
					event:FireServer(batchData)
				end)
			end
		end
	}
end

function Replicator.get_function(name)
	if RunService:IsServer() then
		error("[Quartz] Use new_function() on server to create functions")
	end

	local workspace = initialize_workspace()
	local func = workspace:WaitForChild(name)

	return {
		Instance = func,
		SendPacket = function(...)
			return func:InvokeServer(...)
		end
	}
end

function Replicator.new_event(name, unreliable, unsafe)
	if not RunService:IsServer() then
		error("[Quartz] Events can only be created on the server")
	end

	local event = if unreliable then get_remote(name, "UnreliableRemoteEvent") else get_remote(name, "RemoteEvent")
	local isServer = RunService:IsServer()

	local rateLimitConfig = {
		maxRequests = nil,
		timeWindow = nil,
		onLimitExceeded = nil
	}

	cache.rateLimitConfigs[name] = rateLimitConfig

	local eventObj = {
		Instance = event,

		SendPacket = function(player, ...)
			if isServer then
				if player then
					event:FireClient(player, ...)
				else
					event:FireAllClients(...)
				end
			else
				event:FireServer(...)
			end
		end,

		SendToMultiple = function(players, ...)
			if not isServer then return end
			for i = 1, #players do
				event:FireClient(players[i], ...)
			end
		end,

		OnServerEvent = function(callback)
			if isServer then
				return event.OnServerEvent:Connect(function(player, ...)
					local config = cache.rateLimitConfigs[name]
					if config and config.maxRequests then
						local allowed = RateLimiter:check(
							name, 
							player, 
							config.maxRequests, 
							config.timeWindow
						)
						if not allowed then
							if config.onLimitExceeded then
								config.onLimitExceeded(player, ...)
							end
							return
						end
					end
					callback(player, ...)
				end)
			end
		end,

		OnClientEvent = function(callback)
			if not isServer then
				return event.OnClientEvent:Connect(callback)
			else
				warn("[Quartz] OnClientEvent is not available on server")
			end
		end,

		WithRateLimit = function(maxRequests, timeWindow, onLimitExceeded)
			if not RunService:IsServer() then
				warn("[Quartz] Rate limiting can only be configured on the server")
				return
			end
			cache.rateLimitConfigs[name] = {
				maxRequests = maxRequests,
				timeWindow = timeWindow,
				onLimitExceeded = onLimitExceeded
			}
			return
		end,

		GetRemainingTokens = function(player)
			if not RunService:IsServer() then return 0 end
			return RateLimiter:getRemainingTokens(name, player)
		end,

		ResetRateLimit = function(player)
			if not RunService:IsServer() then return end
			RateLimiter:reset(name, player)
		end,

		CreateBuffer = function(maxSize, flushInterval)
			local buffer = create_buffer(name, maxSize, flushInterval)

			return {
				Add = function(data)
					table.insert(buffer.data, data)

					if #buffer.data >= buffer.maxSize then
						flush_buffer(buffer, nil, function(batchData)
							if isServer then
								event:FireAllClients(batchData)
							else
								event:FireServer(batchData)
							end
						end)
					elseif os.clock() - buffer.lastFlush >= buffer.flushInterval then
						flush_buffer(buffer, nil, function(batchData)
							if isServer then
								event:FireAllClients(batchData)
							else
								event:FireServer(batchData)
							end
						end)
					end
				end,

				Flush = function(target)
					flush_buffer(buffer, target, function(batchData, targetPlayer)
						if isServer then
							if targetPlayer then
								event:FireClient(targetPlayer, batchData)
							else
								event:FireAllClients(batchData)
							end
						else
							event:FireServer(batchData)
						end
					end)
				end,

				OnFlush = function(callback)
					table.insert(buffer.callbacks, callback)
				end,

				Clear = function()
					buffer.data = {}
				end,

				GetSize = function()
					return #buffer.data
				end
			}
		end,

		SendBuffered = function(player, data, maxSize, flushInterval)
			local bufferKey = name .. (player and tostring(player.UserId) or "all")
			local buffer = create_buffer(bufferKey, maxSize, flushInterval)

			table.insert(buffer.data, data)

			if #buffer.data >= buffer.maxSize or os.clock() - buffer.lastFlush >= buffer.flushInterval then
				flush_buffer(buffer, player, function(batchData, targetPlayer)
					if isServer then
						if targetPlayer then
							event:FireClient(targetPlayer, batchData)
						else
							event:FireAllClients(batchData)
						end
					else
						event:FireServer(batchData)
					end
				end)
			end
		end
	}
	
	if unsafe == true then
		-- rewriting functions
		return {
			SendBuffered = function()
				error("[Quartz] 'SendBuffered' not avaliable in unsafe mode")
			end,
			CreateBuffer = function()
				error("[Quartz] 'CreateBuffer' not avaliable in unsafe mode")
			end,
			SendPacketToClient = function(player, ...)
				event:FireClient(player, ...)
			end,
			SendPacketToClients = function(players: {Player}, ...)
				for _, player in ipairs(players) do
					event:FireClient(player, ...)
				end
			end,
			SendPacketToServer = function(...)
				event:FireServer(...)
			end,
			SendPacket = function()
				error("[Quartz] 'SendPacket' not avaliable in unsafe mode")
			end,
			WithRateLimit = function()
				error("[Quartz] 'WithRateLimit' not avaliable in unsafe mode")
			end,
			GetRemainingTokens = function()
				error("[Quartz] 'GetRemainingTokens' not avaliable in unsafe mode")
			end,
			ResetRateLimit = function()
				error("[Quartz] 'ResetRateLimit' not avaliable in unsafe mode")
			end,
			OnServerEvent = function(callback)
				event.OnServerEvent:Connect(callback)
			end,
			OnClientEvent = function(callback)
				event.OnClientEvent:Connect(callback)
			end,
		}
	end

	return eventObj
end

function Replicator.new_function(name)
	if not RunService:IsServer() then
		error("[Quartz] Functions can only be created on the server")
	end

	local func = get_remote(name, "RemoteFunction")
	local isServer = RunService:IsServer()

	return {
		Instance = func,

		SendPacket = function(player, ...)
			if isServer then
				if player then
					return func:InvokeClient(player, ...)
				else
					error("Cannot invoke all clients for function")
				end
			else
				return func:InvokeServer(...)
			end
		end,

		InvokeMultiple = function(players, ...)
			if not isServer then return {} end

			local results = {}
			for i = 1, #players do
				results[players[i]] = func:InvokeClient(players[i], ...)
			end
			return results
		end,

		OnServerInvoke = function(callback)
			if isServer then
				func.OnServerInvoke = callback
			end
		end,

		BatchInvoke = function(players, requests, batchSize)
			if not isServer then return {} end

			batchSize = batchSize or 5
			local allResults = {}

			for i = 1, #requests, batchSize do
				local batchEnd = math.min(i + batchSize - 1, #requests)
				local batchRequests = {table.unpack(requests, i, batchEnd)}

				for j = 1, #players do
					local player = players[j]
					local playerResults = {}

					for k = 1, #batchRequests do
						local success, result = pcall(function()
							return func:InvokeClient(player, batchRequests[k])
						end)
						playerResults[k] = {Success = success, Result = result}
					end

					allResults[player] = allResults[player] or {}
					table.move(playerResults, 1, #playerResults, #allResults[player] + 1, allResults[player])
				end

				task.wait()
			end

			return allResults
		end
	}
end

function Replicator.clear_cache()
	cache.workspace = nil
	cache.rateLimitConfigs = {}
	cache.buffers = {}
	RateLimiter.buckets = {}
end



function Replicator.set_default_rate_limit(maxRequests, timeWindow)
	RateLimiter.defaults.maxRequests = maxRequests
	RateLimiter.defaults.timeWindow = timeWindow
end

function Replicator.get_rate_limit_stats(eventName)
	if not RateLimiter.buckets[eventName] then
		return {activePlayers = 0}
	end

	local activePlayers = 0
	for _ in pairs(RateLimiter.buckets[eventName]) do
		activePlayers += 1
	end

	return {
		activePlayers = activePlayers,
		defaultMaxRequests = RateLimiter.defaults.maxRequests,
		defaultTimeWindow = RateLimiter.defaults.timeWindow
	}
end

function Replicator.flush_all_buffers()
	for name, buffer in pairs(cache.buffers) do
		if #buffer.data > 0 then
			local workspace = initialize_workspace()
			local remote = workspace:FindFirstChild(name)
			if remote then
				flush_buffer(buffer, nil, function(batchData)
					if RunService:IsServer() then
						remote:FireAllClients(batchData)
					else
						remote:FireServer(batchData)
					end
				end)
			end
		end
	end
end

initialize_workspace()

return Replicator