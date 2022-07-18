-- druid_polymorph lua module
--
-- Druid Polymorph is a LUA module for NGINX OpenResty used to emulate Druid Lookups behavior for use-cases with a very large number of values to be cached.

local _M = {}

-- dictionnary cache lifetime in NGINX LUA
local lookupUpdateInterval = 600

-- activated lookups (added as KEY = "KEY")  this values correspond to key formats in redis in the form of KEY.(id / 100000) to shared hashes
local activeLookups = {
}

-- default redis host/port - can be given in config
local redis = { host = "127.0.0.1", port = 6379 }

-- debug mode
local debugMode = false

function _M.setRedis(host, port)
    redis.host = host
    redis.port = port
end

-- utils for messages
function _M.warn(msg)
	ngx.log(ngx.WARN, "DruidPolymorph: " .. msg)
end

function _M.debug(msg)
	if debugMode == true  then
		ngx.log(ngx.INFO, "DruidPolymorph: DEBUG: " .. msg)
	end
end

function _M.info(msg)
	ngx.log(ngx.INFO, "DruidPolymorph: " .. msg)
end

function _M.err(msg)
	ngx.log(ngx.ERR, "DruidPolymorph: " .. msg)
end

-- debug dump function jic
function dump(o)
   if type(o) == 'table' then
      for k,v in pairs(o) do
	if type(v) == 'table' then
		dump(v)
	else
		_M.info("k=" .. k .. " &v=" .. v)
	end
      end
   end
end


-- handler fct used for updating lookup
local lookupUpdate
lookupUpdate = function(premature, ctx)

    if premature then
        return
    end

    local success, err, forcible = ngx.shared["druid_polymorph"]:add("SET_TIMER", "1", 30)
    if not success then
        _M.debug("Update already started on another thread")
        return
    end

    _M.info("Updating lookups")
    _M.cacheLookups()
    ngx.shared["druid_polymorph"]:set("ready", true)
    _M.info("Lookups marked as updated")

    local ok, err = ngx.timer.at(lookupUpdateInterval, lookupUpdate)
    if not ok then
        _M.err("Failed to set config reset timer: " .. err)
        return
    end
end

-- check if module is ready and cache is generated at least once - useful at startup
function _M.isReady()
	if ngx.shared["druid_polymorph"]:get("ready") ~= nil then
		return true
	end
	return false
end

-- redis lookup caching function to nginx SHM dict
function _M.cacheLookups()
    local red = require "resty.redis":new()
    red:set_timeout(10000)
    local ok, err = red:connect(redis.host, redis.port)

    if not ok then
        _M.err("Failed connecting to Redis " .. r .. ": " .. err)
        return
    end

    for _, lookupEntity in pairs(activeLookups) do
	if ngx.shared[lookupEntity] == nil then
  	     	_M.err("Non-existing shared dictionary (" .. lookupEntity .. ") from config. Cannot load lookups.")
	else
		keyList = red:keys(lookupEntity .. "*")
		for _, key in ipairs(keyList) do
			keys = red:hgetall(key)
			for idx=1, #keys, 2 do
				-- Uncomment this line to dump every value added in the dict - beware of log size
				-- _M.debug("Loading " .. lookupEntity .. ": " .. keys[idx] .. " = " .. keys[idx+1])
				success, err, forcible = ngx.shared[lookupEntity]:set(keys[idx], keys[idx+1])
				if success ~= true then
					-- This err will most likely point out issue with dict size memory
					_M.err("Cannot insert " .. lookupEntity .. ":" .. err)
				end
			end
		end
	end
    end    
end

function _M.returnLookupEntry(lookupEntity, key)
	if ngx.shared[lookupEntity] ~= nil then
		ngx.say(ngx.shared[lookupEntity]:get(key))
	end
end

-- traversing values to replace them by cached lookups in SHM dictionnaries
function _M.lookupReplace(values, lookupEntity)
	new_values = {}
	if ngx.shared[lookupEntity] == nil then
  	     	_M.err("Non-existing shared dictionary (" .. lookupEntity .. ") from config. Cannot use lookups.")
		return values
        end
	for _, entityId in ipairs(values) do
		if entityId == "" or entityId == nil then
			_M.debug("Replacing lookup " .. lookupEntity .. " ID: " .. entityId .. " with " .. "Unknown")
			table.insert(new_values, "Unknown")
		elseif ngx.shared[lookupEntity]:get(entityId) == nil then
			_M.debug(ngx.INFO, "Replacing lookup " .. lookupEntity .. " ID: " .. entityId .. " with " .. entityId)
			table.insert(new_values, tostring(entityId))
		else
			val = ngx.shared[lookupEntity]:get(entityId)
			_M.debug(ngx.INFO, "Replacing lookup " .. lookupEntity .. " ID: " .. entityId .. " with " .. val)
			table.insert(new_values, val)
		end
	end
	return new_values
end

-- traversing values in specific dictionnaries to replace them by cached lookups in SHM dictionnaries
function _M.lookupReplaceDict(values, lookupEntity)
	if ngx.shared[lookupEntity] == nil then
  	     	_M.err("Non-existing shared dictionary (" .. lookupEntity .. ") from config. Cannot use lookups.")
		return values
        end
	for idx, entity in ipairs(values) do
		if entity == "" or entity == nil then
			values[idx][lookupEntity] = "Unknown"
		elseif ngx.shared[lookupEntity]:get(values[idx][lookupEntity]) == nil then
			values[idx][lookupEntity] = values[idx][lookupEntity]
		else
			values[idx][lookupEntity] = ngx.shared[lookupEntity]:get(values[idx][lookupEntity])
		end
	end
	return values
end

-- Revert values to only ID before sending to Pivot
function _M.reverseLookupReplace(filter_body)
	for key_clause, val_clause in pairs(filter_body) do
		if activeLookups[val_clause["dimension"]] then
			for key_el, val_el in pairs(val_clause["values"]["elements"]) do
				if val_el == "Unknown" then
					filter_body[key_clause]["values"]["elements"][key_el] = ""
					_M.debug("Replacing value for lookup entity " .. val_clause["dimension"] .. " : Unknown to empty string")
				else
					nvalue = string.gmatch(val_el, "%d+")()
					filter_body[key_clause]["values"]["elements"][key_el] = nvalue
					_M.debug("Replacing value for lookup entity " .. val_clause["dimension"] .. " :" .. val_el .. " with " .. nvalue)
				end
			end
		end
	end
end

-- filters function to check answer and validate if they should be parsed and replaced
function _M.lookupFilterAxis(pivot_answer, lookup_entity)
	if activeLookups[lookup_entity] then
		pivot_answer["result"]["setType"] = "STRING"
		pivot_answer["result"]["elements"] = _M.lookupReplace(pivot_answer["result"]["elements"], lookup_entity)
	end
end

function _M.lookupFilterQuery(pivot_answer)
	for _, lookup_entity in pairs(pivot_answer["result"]["keys"]) do
		if activeLookups[lookup_entity] then
			pivot_answer["result"]["data"] = _M.lookupReplaceDict(pivot_answer["result"]["data"], lookup_entity)
		end
	end
end

function _M.reverseLookupFilter(json_key, json_body)
	if type(json_body) == "table" then
		if json_key == "clauses" then
			_M.reverseLookupReplace(v)
		else
			for k, v in pairs(json_body) do
				_M.debug("Checking ".. k .. "(" .. type(v) .. ")")
				if k == "clauses" then
					_M.reverseLookupReplace(v)
				elseif type(v) == "table" then
					_M.reverseLookupFilter(k, v)
				end
			end
		end
	else
		return
	end
end

-- utils to check if request should be checked as part of proxy
function _M.isApplicationJson()
	ct = ngx.req.get_headers()["Content-Type"]
	if ct then
		if string.gmatch(ct, "[^;]+")() == "application/json" then
			return true
		end
	end
	return false
end

-- function called on all responses of Pivot
function _M.lookupResponseReplace()
	if _M.isApplicationJson() then
		if _M.isReady() then
			local ctx = ngx.ctx
			local lookup_entity = ngx.var.arg_axis
	
			if ctx.buffers == nil then
				ctx.buffers = {}
				ctx.idx = 0
			end
	
			local red = nil
			local data = ngx.arg[1]
			local eof = ngx.arg[2]
	
			if not eof then
				if data then
					ctx.buffers[ctx.idx + 1] = data
					ctx.idx = ctx.idx + 1
					ngx.arg[1] = nil
				end
				return
			elseif data then
				ctx.buffers[ctx.idx + 1] = data
				ctx.idx = ctx.idx + 1
			end
	
			-- Yes, we have read the full body.
			-- Make sure it is stored in our buffer.
			assert(ctx.buffers)
	 		assert(ctx.idx ~= 0)

		 	local full_body = table.concat(ctx.buffers)
 			_M.debug("Parsing body")
			-- parse json
			local pivot_answer = dkjson.decode(full_body)
	
			if pivot_answer == nil then
				return
			end

			_M.debug("full_body:" .. full_body)
			if pivot_answer ~= nil and pivot_answer["result"] and pivot_answer["result"]["elements"] then
				_M.lookupFilterAxis(pivot_answer, ngx.var.arg_axis)
				ngx.arg[1] = dkjson.encode(pivot_answer, { indent = true })
			elseif pivot_answer ~= nil and pivot_answer["result"] and pivot_answer["result"]["keys"] then
				_M.lookupFilterQuery(pivot_answer)
				ngx.arg[1] = dkjson.encode(pivot_answer, { indent = true })
			else
				ngx.arg[1] = full_body
			end
		else
			_M.warn("Not ready, returning raw body")
		end
	end
end

-- function called on all requests to Pivot
function _M.lookupRequestReplace()
	if _M.isApplicationJson() then
		if _M.isReady() then
			ngx.req.read_body()
			local post, err = ngx.req.get_body_data()
	
			if err == "truncated" then
				_M.err("Cannot post process filter, ignoring")
				return
			end
			if not post then
				_M.err("No post body")
				return
			end
	
			decoded = dkjson.decode(post)
			if decoded then
				_M.reverseLookupFilter("body", decoded)
			end
		        _M.debug(dkjson.encode(decoded))
			ngx.req.set_body_data(dkjson.encode(decoded))
		else
			_M.warn("Not ready.")
		end
	end
end

function _M.setDebugModeOn()
	debugMode = true
end

-- init function for module to be called at init_worker level
function _M.init(config)

    activeLookups = config.lookups or activeLookups
    redis = config.redis or redis
    resetInterval = config.resetInterval or resetInterval
    debugMode = config.debugMode or debugMode

    _M.info("Initializing Druid Polymorph")

    -- Check shared dict name existence
    for _, entity in ipairs(activeLookups) do
	if ngx.shared[entity] == nil then 
  	     	_M.err("Missing shared dictionary (" .. entity .. ") from config. Cannot load lookups.")
		return
	end
    end    

    -- adding lookup update handler
    if redis ~= nil then
        lookupUpdateInterval = config.lookupUpdateInterval or lookupUpdateInterval
        _M.setRedis(redis.host, redis.port)

        -- Start config update immediately outside the init() context, because the redis API is disabled in the context of init_worker_by_lua*
        local ok, err = ngx.timer.at(0, lookupUpdate)
        if not ok then
            _M.err("Can't start lookup update timer: " .. err)
        end
    end
end

return _M

