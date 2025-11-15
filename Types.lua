local Types = {}

export type Validator = (value: any) -> (boolean, string?)
export type ValidationRule = string | Validator | {Type: string, Min: number?, Max: number?}

export type Event = {
	OnFire: (self: any, callback: any) -> any,
	Fire: (self: any, ...any) -> any,
	Expects: (self: any, ...Types.ValidationRule) -> any,
	Validate: (self: any, ...any) -> (boolean, string?),
	WithTimeout: (self: any, timeout: number) -> any,
	WithRateLimit: (self: any, callsPerMinute: number) -> any
}

export type Function = {
	OnInvoke: (self: any, callback: any) -> any,
	Invoke: (self: any, ...any) -> any,
	Expects: (self: any, ...Types.ValidationRule) -> any,
	Validate: (self: any, ...any) -> (boolean, string?),
	WithTimeout: (self: any, timeout: number) -> any,
	WithRetry: (self: any, maxAttempts: number) -> any
}

Types.string = "string"
Types.number = "number"
Types.boolean = "boolean"
Types.shape = "shape"
Types.Function = "function"
Types.player = "player"

Types.vector3 = "Vector3"
Types.vector2 = "Vector2"
Types.cframe = "CFrame"
Types.color3 = "Color3"
Types.udim = "UDim"
Types.udim2 = "UDim2"
Types.ray = "Ray"
Types.region3 = "Region3"
Types.enum = "EnumItem"
Types.brickcolor = "BrickColor"
Types.instance = "Instance"

Types.validators = {
	string = function(value) return typeof(value) == "string" end,
	number = function(value) return typeof(value) == "number" end,
	boolean = function(value) return typeof(value) == "boolean" end,
	shape = function(value) return typeof(value) == "table" end,
	Function = function(value) return typeof(value) == "function" end,
		player = function(value) return typeof(value) == "Instance" and value:IsA("Player") end,
		vector3 = function(value) return typeof(value) == "Vector3" end,
		vector2 = function(value) return typeof(value) == "Vector2" end,
		cframe = function(value) return typeof(value) == "CFrame" end,
		color3 = function(value) return typeof(value) == "Color3" end,
		udim = function(value) return typeof(value) == "UDim" end,
		udim2 = function(value) return typeof(value) == "UDim2" end,
		ray = function(value) return typeof(value) == "Ray" end,
		region3 = function(value) return typeof(value) == "Region3" end,
		enum = function(value) return typeof(value) == "EnumItem" end,
		brickcolor = function(value) return typeof(value) == "BrickColor" end,
		instance = function(value) return typeof(value) == "Instance" end
	
}

function Types.custom(validatorFn)
	return {_custom = true, validate = validatorFn}
end

function Types.shape(shapeDefinition)
	return {
		_shape = true,
		shape = shapeDefinition,
		validate = function(value)
			if typeof(value) ~= "table" then
				return false, "Expected table, got " .. typeof(value)
			end

			for key, expectedType in pairs(shapeDefinition) do
				local validator = Types.getValidator(expectedType)
				if not validator then
					return false, "Invalid validator for key: " .. tostring(key)
				end
				
				local success, errorMsg = validator(value[key])
				if not success then
					return false, string.format("Key '%s': %s", key, errorMsg or "validation failed")
				end
			end

			return true
		end
	}
end

function Types.range(min, max)
	return {
		_range = true,
		min = min,
		max = max,
		validate = function(value)
			return typeof(value) == "number" and value >= min and value <= max
		end
	}
end


function Types.max(maxValue)
	return {
		_max = true,
		max = maxValue,
		validate = function(value)
			return typeof(value) == "number" and value <= maxValue
		end
	}
end

function Types.min(minValue)
	return {
		_min = true,
		min = minValue,
		validate = function(value)
			return typeof(value) == "number" and value <= minValue
		end
	}
end

Types.auto = {
	_auto = true,
	validate = function(value)
		return true
	end
}

function Types.isTypeDescriptor(value)
	if type(value) == "string" then
		return Types.validators[value] ~= nil
	elseif type(value) == "table" then
		return value._custom or value._range or value._min or value._max or value._auto
	end
	return false
end

function Types.getValidator(typeDesc)
	if type(typeDesc) == "string" then
		return Types.validators[typeDesc]
	elseif type(typeDesc) == "table" then
		return typeDesc.validate
	elseif type(typeDesc) == "function" then
		return typeDesc
	end
	return nil
end

function Types.createValidator(rules)
	local validators = {}

	for i, rule in ipairs(rules) do
		local validator = Types.getValidator(rule)
		if validator then
			validators[i] = validator
		else
			if typeof(rule) == "string" then
				validators[i] = function(value)
					return typeof(value) == rule
				end
			elseif typeof(rule) == "function" then
				validators[i] = rule
			elseif typeof(rule) == "table" and rule.Type then
				if rule.Type == "number" then
					validators[i] = function(value)
						if typeof(value) ~= "number" then return false end
						if rule.Min and value < rule.Min then return false end
						if rule.Max and value > rule.Max then return false end
						return true
					end
				else
					validators[i] = function(value)
						return typeof(value) == rule.Type
					end
				end
			end
		end
	end

	return function(...)
		local args = {...}
		for i = 1, math.min(#validators, #args) do
			local validator = validators[i]
			local success = validator(args[i])
			if not success then
				return false
			end
		end
		return true
	end
end



return Types