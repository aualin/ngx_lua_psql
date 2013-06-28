-- Implements postgresql support, tested against 9.2.4
-- Doesn't use a library of any kind,
-- this speaks the raw protocol
local strchar = string.char
local strbyte = string.byte
local lshift = bit.lshift
local bor = bit.bor
local band = bit.band
local rshift = bit.rshift
local tblcon = table.concat

-- Byte level functions
local function tobyte4(n)
	return strchar(band(rshift(n,24),0xff), band(rshift(n,16),0xff), band(rshift(n,8),0xff), band(n,0xff))
end

local function tobyte2(n)
	return strchar(band(rshift(n,8),0xff), band(n,0xff))
end

local function parsebyte4(data,i)
	local a,b,c,d = strbyte(data,i,i+3)
	return bor(d,lshift(c,8),lshift(b,16),lshift(a,24))
end

local function parsebyte2(data, i)
	local a, b = strbyte(data, i, i + 1)
	return bor(b, lshift(a, 8))
end


local parse = {
	--Error
	E = function(sock)
		local result = {}
		local len = parsebyte4(sock:receive(4),1)
		local data = sock:receive(len-4)
		local pos = 1
		while true do
			local code = string.sub(data,pos,pos)
			pos = pos+1
			local zero = string.find(data,"\0",pos)
			if zero == nil then break end
			local str = string.sub(data,pos,zero-1)
			pos = zero+1
			result[code] = str
		end
		error(result.M)
		return false, result.M
	end,
	-- One of the Authentication msgs, we only support AuthenticationOK
	R = function(sock)
		local len = parsebyte4(sock:receive(4),1)
		local data = sock:receive(len-4)
		-- 0 is AuthenticationOK, we don't do any other auth
		if parsebyte4(data,1) ~= 0 then error("THIS AUTHENTICATION METHOD IS NOT SUPPORTED") end
		return true
	end,
	-- ParameterStatus, we don't try to understand this
	S = function(sock)
		sock:receive(parsebyte4(sock:receive(4),1)-4)
		return true
	end,
	-- BackendKeyData, don't care
	K = function(sock)
		sock:receive(4+4+4)
		return true
	end,
	-- RowDescription
	T = function(sock)
		local len = parsebyte4(sock:receive(4),1)
		local data = assert(sock:receive(len-4))
		local rows = parsebyte2(data,1)
		local res = {}
		local pos = 3
		for i=1,rows do
			local zero = string.find(data,"\0",pos)
			res[i] = string.sub(data,pos,zero-1)
			pos = zero+19
		end
		return res
	end,
	-- DataRow
	D = function(sock)
		local len = parsebyte4(sock:receive(4),1)
		local data = sock:receive(len-4)
		local pos = 3
		local rows = parsebyte2(data,1)
		local res = {}
		for i=1,rows do
			local len = parsebyte4(data,pos)
			res[i] = string.sub(data,pos+4,pos+3+len)
			pos = pos+4+len
		end
		return res
	end,
	-- CommandComplete
	C = function(sock)
		local len = parsebyte4(sock:receive(4),1)
		local data = sock:receive(len-4)
		local zero = string.find(data, "\0")
		return true
	end,
	-- ReadyForQuery
	Z = function(sock)
		assert(sock:receive(5))
		return true
	end
}
-- ParseComplete
parse["1"] = function(sock)
	sock:receive(4)
	return true
end

parse["2"] = function(sock)
	sock:receive(4)
	return true
end

local build = {
	Parse = function(name,queryStr)
		local res = {
			name,
			"\0",
			queryStr,
			"\0",
			tobyte2(0)
		}
		local res = tblcon(res)
		return  "P"..tobyte4(#res+4)..res
	end,
	Bind = function(name,...)
		local arg = {...}
		local res = {
			"\0",
			name,
			"\0\0\0",
		}
		res[#res+1] = tobyte2(#arg)
		for k,v in ipairs(arg) do
			if v == nil then
				res[#res+1] = tobyte4(-1)
			else
				res[#res+1] = tobyte4(#v)
				res[#res+1] = v
			end
		end
		res[#res+1] = "\0\0"
		res = tblcon(res)
		return "B"..tobyte4(#res+4)..res
	end,
	Execute = function()
		local res = {
			"\0",
			tobyte4(0)
		}
		res = tblcon(res)
		return "E"..tobyte4(#res+4)..res
	end,
	Describe = function()
		return "D"..tobyte4(2+4).."P\0"
	end,
	Sync = function()
		return "S"..tobyte4(4)
	end,
	Query = function(str)
		return "Q"..tobyte4(5+#str)..str.."\0"
	end
}

local function connect(host, user, db, port)
	local sock = ngx.socket.tcp()
	sock:settimeout(500) -- 500 ms should be plenty of time
	if string.sub(host,1,4) == "unix" then
		assert(sock:connect("unix:/run/postgresql/.s.PGSQL.5432", { pool = "unix:/run/postgresql/.s.PGSQL.5432:"..db } ) )
	else
		assert(sock:connect(host,port, { pool = host..tostring(port)..db }))
	end
	if sock:getreusedtimes() == 0 then
		-- Sock has never been used before,
		-- we need to do handshake ritual
		-- with psql
		local packet = {"user\0"}
		packet[#packet+1] = tostring(user)
		packet[#packet+1] = "\0database\0"
		packet[#packet+1] = tostring(db)
		packet[#packet+1] = "\0\0"
		packet = tblcon(packet)
		packet = tblcon({
			tobyte4(4+4+#packet),
			tobyte4(bit.bor(bit.lshift(3,16),0)),
			packet})
		sock:send(packet)
		local data,err,partial = sock:receive(1)
		parse[data](sock)
		repeat
			local data,err,partial = sock:receive(1)
			assert(parse[data](sock))
		until data == "Z"
	end
	return setmetatable({_sock=sock},{ __index = {
		prepare = function(self,name,query)
			assert(self._sock:send(build.Parse(name,query)..build.Sync()))
			repeat
				local data,err,partial = assert(sock:receive(1))
				assert(parse[data](self._sock))
			until data == "Z"
			expectedPrepares[name] = query
		end,
		-- Run prepared statement
		execute = function(self, name, ...)
			local packet = build.Bind(name,...)..build.Describe()..build.Execute()..build.Sync()
			assert(self._sock:send(packet))
			local fieldNames,result = {},{}
			-- Expecting BindComplete, RowDescription, DataRow, CommandComplete, and then ReadyForQuery
			repeat
				local data,err,partial = assert(sock:receive(1))
				if data == "T" then
					fieldNames = assert(parse[data](self._sock))
				elseif	data == "D" then
					local res = {}
					for k,v in ipairs(assert(parse[data](self._sock))) do
						res[fieldNames[k]] = v
					end
					result[#res+1] = res
				else
					assert(parse[data](self._sock))
				end
			until data == "Z"
			return result
		end,
		query = function(self,query)
			assert(self._sock:send(build.Query(query)))
			local fieldNames,result = {},{}
			-- Expecting RowDescription, DataRow, then ReadyForQuery
			repeat
				local data,err,partial = sock:receive(1)
				if data == "T" then
					fieldNames = assert(parse[data](self._sock))
				elseif data == "D" then
					local res = {}
					for k,v in ipairs(assert(parse[data](self._sock))) do
						res[fieldNames[k]] = v
					end
					table.insert(result,res)
				else
					assert(parse[data](self._sock))
				end
			until data == "Z"
			return result
		end,
		disconnect = function(self)
			self._sock:setkeepalive()
		end
	}})
end

return {connect = connect}
