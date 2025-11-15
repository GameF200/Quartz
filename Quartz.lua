--[[

                                                                                                                                                                                                            
  -------                                     ---               
 ---   ---                                    ---               
---     --- ---    ---  -------   -------- --------- ---------- 
---     --- ---    ---       ---  ----        ---         ----  
---     --- ---    ---  --------  ---         ---       ----    
 ---   ---  ---   ---- ---   ---  ---         ---     ----      
  -------    ---------  --------- ---          ----- ---------- 
       ---                                                      
        ---                                                     
                                                                
                                                                                                          
                                                                                                          
    Quartz is a open source DX-oriented network library                                                                              
    @author @super_sonic                                                                                                      
                                                                                                                                                                                               
    @license MIT
    
    @Version 0.15
]]

local RunService = game:GetService("RunService")
local Replicator = require(script.Replicator)
local Types = require(script.Types)

local Quartz = {}

Quartz.string = Types.string
Quartz.number = Types.number
Quartz.boolean = Types.boolean
Quartz.table = Types.table
Quartz.Function = Types.Function
Quartz.player = Types.player
Quartz.vector3 = Types.vector3
Quartz.vector2 = Types.vector2
Quartz.cframe = Types.cframe
Quartz.color3 = Types.color3
Quartz.udim = Types.udim
Quartz.udim2 = Types.udim2
Quartz.ray = Types.ray
Quartz.region3 = Types.region3
Quartz.enum = Types.enum
Quartz.brickcolor = Types.brickcolor
Quartz.auto = Types.auto
Quartz.instance = Types.instance

Quartz.range = Types.range
Quartz.min = Types.min
Quartz.max = Types.max
Quartz.custom = Types.custom

Quartz.UNRELIABLE = true
Quartz.RELIABLE = true
Quartz.UNSAFE = true
Quartz.SAFE = false
--[[
	Server mode function
--]]
function Quartz.Server()
	local server = {}

	--[[
		Creates event with name and optional validation rules
	]]
	function server.Event(name, unreliable, mode, ...)
		local remote = Replicator.new_event(name, unreliable, mode)
		local event = {_validators = {}}

		local typeArgs = {...}
		if #typeArgs > 0 then
			event._validate = Types.createValidator(typeArgs)
		end

		function event.OnFire(callback)
			if RunService:IsServer() then
				if event._validate then
					local originalCallback = callback
					callback = function(player, ...)
						local args = {...}
						if event._validate(unpack(args)) then
							return originalCallback(player, unpack(args))
						else
							warn(`[Quartz Server] Validation failed for event "{name}" from player {player.Name}. Args:`, args)
							return nil
						end
					end
				end

				remote.OnServerEvent(callback)
			end
			return event
		end

		--[[
			Fires event to player
		]]
		function event.Fire(player, ...)
			if RunService:IsServer() then
				if mode == true then
					remote.SendPacketToClient(player, ...)
				else
					if event._validate and not event._validate(...) then
						error(`[Quartz Server] Validation failed for firing event "{name}"`)
					end

					remote.SendPacket(player, ...)
				end
			end
			return event
		end

		--[[
			Fires event to a table of players
		]]
		function event.FireToMultiple(players, ...)
			if RunService:IsServer() then
				if mode == true then
					remote.SendPacketToClients(players, ...)
				else
					if event._validate and not event._validate(...) then
						error(`[Quartz Server] Validation failed for firing event "{name}" to multiple players. Invalid arguments.`)
					end

					remote.SendToMultiple(players, ...)
				end

			end
			return event
		end

		function event.Expects(...)
			if mode == true then
				error("[Quartz] validation not avaliable in unsafe mode")
				return event
			end
			
			event._validate = Types.createValidator({...})
			return event
		end

        --[[
        	Setting the rate limit for this event
       		max_limit: number,
       		window_time: number,
       		callback: function () -> ()
        ]]
		function event.WithRateLimit(max_limit, window_time, callback)
			remote.WithRateLimit(max_limit, window_time, callback)
			return event
		end

		--[[
			Returns the number of messages that can be sent from a player per second.
		]]
		function event.GetRemainingTokens(player): number
			return remote.GetRemainingTokens(player)
		end

		--[[
			Resets amount of tokens for a player
		]]
		function event.ResetRateLimit(player)
			remote.ResetRateLimit(player)
			return event
		end


		--[[
			Creates buffer
		]]
		function event.CreateBuffer(maxSize, flushInterval)
			local buffer = remote.CreateBuffer(maxSize, flushInterval)

			return {
				Add = function(data)
					buffer.Add(data)
				end,

				Flush = function(target)
					buffer.Flush(target)
				end,

				OnFlush = function(callback)
					buffer.OnFlush(callback)
				end,

				Clear = function()
					buffer.Clear()
				end,

				GetSize = function()
					return buffer.GetSize()
				end
			}
		end

		--[[
			sends buffered data to a player
		]]
		function event.FireBuffered(player, data, maxSize, flushInterval)
			remote.SendBuffered(player, data, maxSize, flushInterval)
			return event
		end

		return event
	end

	function server.Function(name)
		local remote = Replicator.new_function(name)
		local func = {}

		--[[
			calls callback when function is invoked
		]]
		function func.OnInvoke(callback)
			if RunService:IsServer() then
				remote.OnServerInvoke(callback)
			end
			return func
		end


		--[[
			Invokes remote function
		]]
		function func.Invoke(player, ...)
			if RunService:IsServer() then
				return remote.SendPacket(player, ...)
			end
		end

		--[[
			Invokes remote function on table of players
		]]
		function func.InvokeMultiple(players, ...)
			if RunService:IsServer() then
				return remote.InvokeMultiple(players, ...)
			end
			return {}
		end


		--[[
			Bulk function calls on clients with load control
		]]
		function func.BatchInvoke(players, requests, batchSize)
			if RunService:IsServer() then
				return remote.BatchInvoke(players, requests, batchSize) -- base batch size is 5
			end
			return {}
		end

		return func
	end

	return server
end

--[[
	Client mode function
--]]
function Quartz.Client()
	local client = {}

	client._events = {}
	client._functions = {}

	--[[
		Creates or retrieves client event
	]]
	function client.Event(name, unreliable, ...)
		assert(typeof(name) == "string", "Name must be a string")
		assert(#name > 0, "Name cannot be empty")

		if client._events[name] then
			warn(`Event "{name}" already exists. Returning existing event.`)
			return client._events[name]
		end

		-- Используем get_event вместо new_event на клиенте
		local remote = Replicator.get_event(name)
		local event = {
			_name = name,
			_listeners = {},
			_validate = nil
		}

		local typeArgs = {...}
		if #typeArgs > 0 then
			event._validate = Types.createValidator(typeArgs)
		end

		--[[
			Sets callback for when server fires this event
		]]
		function event.OnFire(callback)
			if not RunService:IsServer() then
				if event._validate then
					local originalCallback = callback
					callback = function(...)
						local args = {...}
						if event._validate(unpack(args)) then
							return originalCallback(unpack(args))
						else
							warn(`[Quartz Client] Validation failed for event "{name}". Args:`, args)
							return nil
						end
					end
				end
				
				local connection = remote.OnClientEvent(callback)
				table.insert(event._listeners, callback)
				return connection
			end
			return event
		end

		--[[
			Fires event to server
		]]
		function event.Fire(...)
			if not RunService:IsServer() then
				if event._validate and not event._validate(...) then
					error(`[Quartz Client] Validation failed for firing event "{name}". Invalid arguments.`)
				end

				remote.SendPacket(...)
			end
			return event
		end

		--[[
			Sets validation rules for event parameters
		]]
		function event.Expects(...)
			event._validate = Types.createValidator({...})
			return event
		end

		--[[
			Creates buffer for batching events
		]]
		function event.CreateBuffer(maxSize, flushInterval)
			local buffer = remote.CreateBuffer(maxSize, flushInterval)

			return {
				Add = function(data)
					buffer.Add(data)
				end,

				Flush = function()
					buffer.Flush()
				end,

				OnFlush = function(callback)
					buffer.OnFlush(callback)
				end,

				Clear = function()
					buffer.Clear()
				end,

				GetSize = function()
					return buffer.GetSize()
				end
			}
		end

		--[[
			Sends data through buffer
		]]
		function event.FireBuffered(data, maxSize, flushInterval)
			remote.SendBuffered(data, maxSize, flushInterval)
			return event
		end

		--[[
			Returns number of active listeners
		]]
		function event.GetListenerCount()
			return #event._listeners
		end

		--[[
			Returns event name
		]]
		function event.GetName()
			return name
		end

		client._events[name] = event

		return event
	end

	--[[
		Creates or retrieves client function
	]]
	function client.Function(name)
		assert(typeof(name) == "string", "Name must be a string")
		assert(#name > 0, "Name cannot be empty")

		if client._functions[name] then
			warn(`Function "{name}" already exists. Returning existing function.`)
			return client._functions[name]
		end

		local remote = Replicator.get_function(name)
		local func = {
			_name = name,
			_validate = nil,
			_timeout = 30, 
		}

		--[[
			Invokes function on server and returns result
		]]
		function func.Invoke(...)
			if not RunService:IsServer() then
				if func._validate and not func._validate(...) then
					error(`[Quartz Client] Validation failed for invoking function "{name}". Invalid arguments.`)
				end

				return remote.SendPacket(...)
			end
			return nil
		end

		--[[
			Sets validation rules for function parameters
		]]
		function func.Expects(...)
			func._validate = Types.createValidator({...})
			return func
		end

		--[[
			Creates retry wrapper with exponential backoff
		]]
		function func.WithRetry(maxAttempts, delay)
			delay = delay or 0.1
			assert(maxAttempts > 0, "Max attempts must be greater than 0")
			assert(delay >= 0, "Delay must be non-negative")

			return function(...)
				local attempts = 0
				local lastError

				while attempts < maxAttempts do
					local success, result = pcall(remote.SendPacket, ...)
					if success then
						return result
					end

					lastError = result
					attempts += 1

					if attempts < maxAttempts then
						task.wait(delay)
					end
				end

				error(`Max retry attempts ({maxAttempts}) exceeded for function "{name}". Last error: {lastError}`)
			end
		end

		--[[
			Sets default timeout for function invocations
		]]
		function func.WithTimeout(timeout)
			assert(timeout > 0, "Timeout must be greater than 0")
			func._timeout = timeout
			return func
		end

		--[[
			Invokes function with specific timeout
		]]
		function func.InvokeWithTimeout(timeout, ...)
			if not RunService:IsServer() then
				if func._validate and not func._validate(...) then
					error(`[Quartz Client] Validation failed for invoking function "{name}". Invalid arguments.`)
				end

				local startTime = os.clock()
				local result = remote.SendPacket(...)

				if os.clock() - startTime > timeout then
					warn(`[Quartz Client] Function "{name}" invocation exceeded timeout of {timeout} seconds`)
				end

				return result
			end
			return nil
		end

		--[[
			Returns function name
		]]
		function func.GetName()
			return name
		end

		client._functions[name] = func

		return func
	end

	--[[
		Retrieves existing event by name
	]]
	function client.GetEvent(name)
		return client._events[name]
	end

	--[[
		Retrieves existing function by name
	]]
	function client.GetFunction(name)
		return client._functions[name]
	end

	--[[
		Returns table of all registered events
	]]
	function client.GetAllEvents()
		return client._events
	end

	--[[
		Returns table of all registered functions
	]]
	function client.GetAllFunctions()
		return client._functions
	end

	--[[
		Immediately flushes all buffered events
	]]
	function client.FlushAllBuffers()
		Replicator.flush_all_buffers()
	end

	return client
end

function Quartz.SetDefaultRateLimit(maxRequests, timeWindow)
	Replicator.set_default_rate_limit(maxRequests, timeWindow)
end

function Quartz.ClearCache()
	Replicator.clear_cache()
end

function Quartz.GetRateLimitStats(eventName)
	return Replicator.get_rate_limit_stats(eventName)
end

return Quartz