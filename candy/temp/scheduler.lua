local type = type
local error = error
local pairs = pairs
local rawget = rawget
local tonumber = tonumber
local getmetatable = getmetatable
local setmetatable = setmetatable

local debug = debug
local debug_getinfo = debug.getinfo

local table_pack = table.pack
local table_unpack = table.unpack
local table_insert = table.insert

local coroutine_create = coroutine.create
local coroutine_yield = coroutine.yield
local coroutine_resume = coroutine.resume
local coroutine_status = coroutine.status
local coroutine_running = coroutine.running
local coroutine_close = coroutine.close or (function(c) end) -- 5.3 compatibility

--[[ Custom extensions --]]
local msgpack = msgpack
local msgpack_pack = msgpack.pack
local msgpack_unpack = msgpack.unpack
local msgpack_pack_args = msgpack.pack_args

local Citizen = Citizen
local Citizen_SubmitBoundaryStart = Citizen.SubmitBoundaryStart
local Citizen_InvokeFunctionReference = Citizen.InvokeFunctionReference
local GetGameTimer = GetGameTimer
local ProfilerEnterScope = ProfilerEnterScope
local ProfilerExitScope = ProfilerExitScope

local hadThread = false
local curTime = 0
local hadProfiler = false
local isDuplicityVersion = false

local function _ProfilerEnterScope(name)
	if hadProfiler then
		ProfilerEnterScope(name)
	end
end

local function _ProfilerExitScope()
	if hadProfiler then
		ProfilerExitScope()
	end
end

-- setup msgpack compat
msgpack.set_string('string_compat')
msgpack.set_integer('unsigned')
msgpack.set_array('without_hole')

-- setup json compat
--json.version = json._VERSION -- Version compatibility
--json.setoption("empty_table_as_array", true)
--json.setoption('with_hole', true)

-- temp
local _in = Citizen.InvokeNative

local function FormatStackTrace()
	return _in(`FORMAT_STACK_TRACE` & 0xFFFFFFFF, nil, 0, Citizen.ResultAsString())
end

local newThreads = {}
local threads = setmetatable({}, {
	-- This circumvents undefined behaviour in "next" (and therefore "pairs")
	__newindex = newThreads,
	-- This is needed for CreateThreadNow to work correctly
	__index = newThreads
})

local boundaryIdx = 1

local function dummyUseBoundary(idx)
	return nil
end

local function getBoundaryFunc(bfn, bid)
	return function(fn, ...)
		local boundary = bid
		if not boundary then
			boundary = boundaryIdx + 1
			boundaryIdx = boundary
		end
		
		bfn(boundary, coroutine_running())

		local wrap = function(...)
			dummyUseBoundary(boundary)
			
			local v = table_pack(fn(...))
			return table_unpack(v)
		end
		
		local v = table_pack(wrap(...))
		
		bfn(boundary, nil)
		
		return table_unpack(v)
	end
end

local runWithBoundaryStart = getBoundaryFunc(Citizen.SubmitBoundaryStart)
local runWithBoundaryEnd = getBoundaryFunc(Citizen.SubmitBoundaryEnd)

local AwaitSentinel = Citizen.AwaitSentinel()
Citizen.AwaitSentinel = nil

function Citizen.Await(promise)
	local coro = coroutine_running()
	if not coro then
		error("Current execution context is not in the scheduler, you should use CreateThread / SetTimeout or Event system (AddEventHandler) to be able to Await")
	end

	-- Indicates if the promise has already been resolved or rejected
	-- This is a hack since the API does not expose its state
	local isDone = false
	local result, err
	promise = promise:next(function(...)
		isDone = true
		result = {...}
	end,function(error)
		isDone = true
		err = error
	end)

	if not isDone then
		local reattach = coroutine_yield(AwaitSentinel)
		promise:next(reattach, reattach)
		coroutine_yield()
	end

	if err then
		error(err)
	end

	return table_unpack(result)
end

Citizen.SetBoundaryRoutine(function(f)
	boundaryIdx = boundaryIdx + 1

	local bid = boundaryIdx
	return bid, function()
		return runWithBoundaryStart(f, bid)
	end
end)

-- root-level alias (to prevent people from calling the game's function accidentally)
Wait = Citizen.Wait
CreateThread = Citizen.CreateThread
SetTimeout = Citizen.SetTimeout

--[[

	Event handling

]]

local ignoreNetEvent = {
	'__cfx_internal:commandFallback'
}

local funcRefs = {}
local funcRefIdx = 0

local function MakeFunctionReference(func)
	local thisIdx = funcRefIdx

	funcRefs[thisIdx] = {
		func = func,
		refs = 0
	}

	funcRefIdx = funcRefIdx + 1

	local refStr = Citizen.CanonicalizeRef(thisIdx)
	return refStr
end

function Citizen.GetFunctionReference(func)
	if type(func) == 'function' then
		return MakeFunctionReference(func)
	elseif type(func) == 'table' and rawget(func, '__cfx_functionReference') then
		return MakeFunctionReference(function(...)
			return func(...)
		end)
	end

	return nil
end

local function doStackFormat(err)
	local fst = FormatStackTrace()
	
	-- already recovering from an error
	if not fst then
		return nil
	end

	return '^1SCRIPT ERROR: ' .. err .. "^7\n" .. fst
end

local rpcId = 0
local rpcPromises = {}
local playerPromises = {}

-- RPC REPLY HANDLER
local repName = ('__cfx_rpcRep:%s'):format('eternity')

local EXT_FUNCREF = 10
local EXT_LOCALFUNCREF = 11

local funcref_mt = nil

-- exports compatibility
local function getExportEventName(resource, name)
	return string.format('__cfx_export_%s_%s', resource, name)
end

-- Remove cache when resource stop to avoid calling unexisting exports
local function lazyEventHandler() -- lazy initializer so we don't add an event we don't need
	AddEventHandler(('on%sResourceStop'):format(isDuplicityVersion and 'Server' or 'Client'), function(resource)
		exportsCallbackCache[resource] = {}
	end)

	lazyEventHandler = function() end
end

-- Handle an export with multiple return values.
local function exportProcessResult(resource, k, status, ...)
	if not status then
		local result = tostring(select(1, ...))
		error('An error occurred while calling export ' .. k .. ' of resource ' .. resource .. ' (' .. result .. '), see above for details')
	end
	return ...
end

-- entity helpers
local EXT_ENTITY = 41
local EXT_PLAYER = 42

local function NewStateBag(es)
	return setmetatable({}, {
		__index = function(_, s)
			if s == 'set' then
				return function(_, s, v, r)
					local payload = msgpack_pack(v)
					SetStateBagValue(es, s, payload, payload:len(), r)
				end
			end
		
			return GetStateBagValue(es, s)
		end,
		
		__newindex = function(_, s, v)
			local payload = msgpack_pack(v)
			SetStateBagValue(es, s, payload, payload:len(), isDuplicityVersion)
		end
	})
end

GlobalState = NewStateBag('global')

local function GetEntityStateBagId(entityGuid)
	if isDuplicityVersion or NetworkGetEntityIsNetworked(entityGuid) then
		return ('entity:%d'):format(NetworkGetNetworkIdFromEntity(entityGuid))
	else
		EnsureEntityStateBag(entityGuid)
		return ('localEntity:%d'):format(entityGuid)
	end
end

local entityTM = {
	__index = function(t, s)
		if s == 'state' then
			local es = GetEntityStateBagId(t.__data)
			
			if isDuplicityVersion then
				EnsureEntityStateBag(t.__data)
			end
		
			return NewStateBag(es)
		end
		
		return nil
	end,
	
	__newindex = function()
		error('Not allowed at this time.')
	end,
	
	__ext = EXT_ENTITY,
	
	__pack = function(self, t)
		return tostring(NetworkGetNetworkIdFromEntity(self.__data))
	end,
	
	__unpack = function(data, t)
		local ref = NetworkGetEntityFromNetworkId(tonumber(data))
		
		return setmetatable({
			__data = ref
		}, entityTM)
	end
}

local playerTM = {
	__index = function(t, s)
		if s == 'state' then
			local pid = t.__data
			
			if pid == -1 then
				pid = GetPlayerServerId(PlayerId())
			end
			
			local es = ('player:%d'):format(pid)
		
			return NewStateBag(es)
		end
		
		return nil
	end,
	
	__newindex = function()
		error('Not allowed at this time.')
	end,
	
	__ext = EXT_PLAYER,
	
	__pack = function(self, t)
		return tostring(self.__data)
	end,
	
	__unpack = function(data, t)
		local ref = tonumber(data)
		
		return setmetatable({
			__data = ref
		}, playerTM)
	end
}

function Entity(ent)
	if type(ent) == 'number' then
		return setmetatable({
			__data = ent
		}, entityTM)
	end
	
	return ent
end

function Player(ent)
	if type(ent) == 'number' or type(ent) == 'string' then
		return setmetatable({
			__data = tonumber(ent)
		}, playerTM)
	end
	
	return ent
end

if not isDuplicityVersion then
	LocalPlayer = Player(-1)
end

function TriggerEvent(event, ...)
	local payload = msgpack.pack({...})

	TriggerEventInternal(event, payload, payload:len())
end

function TriggerServerEvent(event, ...)
	local payload = msgpack.pack({...})

	TriggerServerEventInternal(event, payload, payload:len())
end