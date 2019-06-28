--多节点使用，节点消息转发(主从节点都要启动)

local skynet = require "skynet"
local socket = require "skynet.socket"
local socketdriver = require "skynet.socketdriver"
local crypt = require "skynet.crypt"
require "skynet.manager"	-- import skynet.launch, ...
local table = table

local slaves = {}
local connect_queue = {}
local globalname = {} --全局服务名 名-服务
local queryname = {}
local harbor = {}
local harbor_service
local monitor = {}
local monitor_master_set = {}

local function read_package(fd)
	local sz = socket.read(fd, 1)
	assert(sz, "closed")
	sz = string.byte(sz)
	local content = assert(socket.read(fd, sz), "closed")
	return skynet.unpack(content)
end

local function pack_package(...)
	local message = skynet.packstring(...)
	local size = #message
	assert(size <= 255 , "too long")
	return string.char(size) .. message
end

local function monitor_clear(id)
	local v = monitor[id]
	if v then
		monitor[id] = nil
		for _, v in ipairs(v) do
			v(true)
		end
	end
end

local function connect_slave(slave_id, address) --主动连接(双向连接的一环
	local ok, err = pcall(function()
		if slaves[slave_id] == nil then
			local fd = assert(socket.open(address), "Can't connect to "..address)
			socketdriver.nodelay(fd) --TCP_NODELAY
			skynet.error(string.format("Connect to harbor %d (fd=%d), %s", slave_id, fd, address))
			slaves[slave_id] = fd
			monitor_clear(slave_id)
			socket.abandon(fd)
			skynet.send(harbor_service, "harbor", string.format("S %d %d",fd,slave_id)) --移交harbor_service STATUS_HANDSHAKE
		end
	end)
	if not ok then
		skynet.error(err)
	end
end

local function ready()
	local queue = connect_queue
	connect_queue = nil
	for k,v in pairs(queue) do
		connect_slave(k,v)
	end
	for name,address in pairs(globalname) do
		skynet.redirect(harbor_service, address, "harbor", 0, "N " .. name) --harbor_service全局命名对应节点服务地址
	end
end

local function response_name(name)
	local address = globalname[name]
	if queryname[name] then
		local tmp = queryname[name]
		queryname[name] = nil
		for _,resp in ipairs(tmp) do
			resp(true, address)
		end
	end
end

local function monitor_master(master_fd)
	while true do
		local ok, t, id_name, address = pcall(read_package,master_fd)
		if ok then
			if t == 'C' then --CONNECT slave_id slave_address
				if connect_queue then
					connect_queue[id_name] = address
				else
					connect_slave(id_name, address)
				end
			elseif t == 'N' then --NAME globalname address
				globalname[id_name] = address
				response_name(id_name)
				if connect_queue == nil then
					skynet.redirect(harbor_service, address, "harbor", 0, "N " .. id_name)
				end
			elseif t == 'D' then --DISCONNECT slave_id
				local fd = slaves[id_name]
				slaves[id_name] = false
				if fd then
					monitor_clear(id_name)
					socket.close(fd)
				end
			end
		else
			skynet.error("Master disconnect")
			for _, v in ipairs(monitor_master_set) do
				v(true)
			end
			socket.close(master_fd)
			break
		end
	end
end

local function accept_slave(fd) --被连接(双向连接的一环
	socket.start(fd)
	local id = socket.read(fd, 1)
	if not id then
		skynet.error(string.format("Connection (fd =%d) closed", fd))
		socket.close(fd)
		return
	end
	id = string.byte(id)
	if slaves[id] ~= nil then
		skynet.error(string.format("Slave %d exist (fd =%d)", id, fd))
		socket.close(fd)
		return
	end
	slaves[id] = fd
	monitor_clear(id)
	socket.abandon(fd) --清除服务内的数据结构，但不关闭socket，移交前的准备
	skynet.error(string.format("Harbor %d connected (fd = %d)", id, fd))
	skynet.send(harbor_service, "harbor", string.format("A %d %d", fd, id)) --移交service_harbor STATUS_HEADER fd id
end

skynet.register_protocol {
	name = "harbor",
	id = skynet.PTYPE_HARBOR,
	pack = function(...) return ... end,
	unpack = skynet.tostring,
}

skynet.register_protocol {
	name = "text",
	id = skynet.PTYPE_TEXT,
	pack = function(...) return ... end,
	unpack = skynet.tostring,
}

local function monitor_harbor(master_fd)
	return function(session, source, command)
		local t = string.sub(command, 1, 1)
		local arg = string.sub(command, 3)
		if t == 'Q' then --发送请求给主节点
			-- query name
			if globalname[arg] then
				skynet.redirect(harbor_service, globalname[arg], "harbor", 0, "N " .. arg)
			else
				socket.write(master_fd, pack_package("Q", arg))
			end
		elseif t == 'D' then --自己gg通知主节点
			-- harbor down
			local id = tonumber(arg)
			if slaves[id] then
				monitor_clear(id)
			end
			slaves[id] = false
		else
			skynet.error("Unknown command ", command)
		end
	end
end

--fd主节点连接副本
function harbor.REGISTER(fd, name, handle)
	assert(globalname[name] == nil)
	globalname[name] = handle
	response_name(name)
	socket.write(fd, pack_package("R", name, handle))
	skynet.redirect(harbor_service, handle, "harbor", 0, "N " .. name)
end

--节点断开时回复
--fd主节点连接副本
function harbor.LINK(fd, id)
	if slaves[id] then
		if monitor[id] == nil then
			monitor[id] = {}
		end
		table.insert(monitor[id], skynet.response())
	else
		skynet.ret()
	end
end

function harbor.LINKMASTER()
	table.insert(monitor_master_set, skynet.response())
end

--连接节点，连上时回复
--fd主节点连接副本
function harbor.CONNECT(fd, id)
	if not slaves[id] then
		if monitor[id] == nil then
			monitor[id] = {}
		end
		table.insert(monitor[id], skynet.response())
	else
		skynet.ret()
	end
end

--查全局服务名
--fd主节点连接副本
function harbor.QUERYNAME(fd, name)
	if name:byte() == 46 then	-- "." , local name
		skynet.ret(skynet.pack(skynet.localname(name)))
		return
	end
	local result = globalname[name]
	if result then
		skynet.ret(skynet.pack(result))
		return
	end
	local queue = queryname[name]
	if queue == nil then
		socket.write(fd, pack_package("Q", name))
		queue = { skynet.response() }
		queryname[name] = queue
	else
		table.insert(queue, skynet.response())
	end
end

skynet.start(function()
	local master_addr = skynet.getenv "master" --主节点地址
	local harbor_id = tonumber(skynet.getenv "harbor") --子节点数
	local slave_address = assert(skynet.getenv "address") --本子节点地址
	local slave_fd = socket.listen(slave_address)
	skynet.error("slave connect to master " .. tostring(master_addr))
	local master_fd = assert(socket.open(master_addr), "Can't connect to master")

	--lua -> harbor:fun
	skynet.dispatch("lua", function (_,_,command,...)
		local f = assert(harbor[command])
		f(master_fd, ...)
	end)
	--text -> monitor_harbor
	skynet.dispatch("text", monitor_harbor(master_fd)) --需要通知主节点的消息

	harbor_service = assert(skynet.launch("harbor", harbor_id, skynet.self())) --启动service_harbor服务，当前节点ID，当前服务地址skynet.self()

	local hs_message = pack_package("H", harbor_id, slave_address)
	socket.write(master_fd, hs_message) --和主节点握手
	local t, n = read_package(master_fd)
	assert(t == "W" and type(n) == "number", "slave shakehand failed")
	skynet.error(string.format("Waiting for %d harbors", n))
	skynet.fork(monitor_master, master_fd) --监听主节点
	if n > 0 then
		local co = coroutine.running()
		socket.start(slave_fd, function(fd, addr)
			skynet.error(string.format("New connection (fd = %d, %s)",fd, addr))
			socketdriver.nodelay(fd)
			if pcall(accept_slave,fd) then
				local s = 0
				for k,v in pairs(slaves) do
					s = s + 1
				end
				if s >= n then --任务完成，所有节点都连接并移交service_harbor
					skynet.wakeup(co) --唤醒以socket.close
				end
			end
		end)
		skynet.wait() --卡主co(co == 默认coroutine.running())
		socket.close(slave_fd)
	else
		-- slave_fd does not start, so use close_fd.
		socket.close_fd(slave_fd)
	end
	skynet.error("Shakehand ready")
	skynet.fork(ready)
end)
