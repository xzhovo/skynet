--用于 UniqueService 管理(专用于服务管理的模块，对于同一个名字，只允许启动一次，且不准更换
--唯一服务，如果你需要整个网络有唯一的服务，那么可以在调用 uniqueservice 的参数前加一个 true ，表示这是一个全局服务。
--如果这个服务不存在，这个 api 会一直阻塞到它启动好为止。
local skynet = require "skynet"
require "skynet.manager"	-- import skynet.register
local snax = require "skynet.snax"

local cmd = {}
local service = {}

--发送请求
local function request(name, func, ...)
	local ok, handle = pcall(func, ...)
	local s = service[name]
	assert(type(s) == "table")
	if ok then
		service[name] = handle
	else
		service[name] = tostring(handle)
	end

	for _,v in ipairs(s) do --唤醒func为阻塞函数时之后阻塞的相同操作协程
		skynet.wakeup(v.co)
	end

	if ok then
		return handle
	else
		error(tostring(handle))
	end
end

--合并不同协程的相同请求，只保留第一个
local function waitfor(name , func, ...)
	local s = service[name]
	if type(s) == "number" then
		return s
	end
	local co = coroutine.running()

	if s == nil then
		s = {}
		service[name] = s
	elseif type(s) == "string" then
		error(s)
	end

	assert(type(s) == "table")

	local session, source = skynet.context()

	if s.launch == nil and func then
		s.launch = {
			session = session,
			source = source,
			co = co,
		}
		return request(name, func, ...) --第一个，直接请求
	end

	table.insert(s, {
		co = co,
		session = session,
		source = source,
	})
	skynet.wait() --s.launch ~= nil 即已有协程操作了，将当前信息插入s
	s = service[name]
	if type(s) == "string" then
		error(s)
	end
	assert(type(s) == "number")
	return s
end

local function read_name(service_name)
	if string.byte(service_name) == 64 then -- '@'
		return string.sub(service_name , 2)
	else
		return service_name
	end
end

--主节点方法，注册
function cmd.LAUNCH(service_name, subname, ...)
	local realname = read_name(service_name) --去@

	if realname == "snaxd" then
		return waitfor(service_name.."."..subname, snax.rawnewservice, subname, ...)
	else
		return waitfor(service_name, skynet.newservice, realname, subname, ...) --skynet.newservice
	end
end

--主节点方法，获取地址
function cmd.QUERY(service_name, subname)
	local realname = read_name(service_name)

	if realname == "snaxd" then
		return waitfor(service_name.."."..subname)
	else
		return waitfor(service_name)
	end
end

--全网消息信息
local function list_service()
	local result = {}
	for k,v in pairs(service) do
		if type(v) == "string" then
			v = "Error: " .. v
		elseif type(v) == "table" then
			local querying = {}
			if v.launch then
				local session = skynet.task(v.launch.co) --第一个能生效的协程的会话信息
				local launching_address = skynet.call(".launcher", "lua", "QUERY", session)
				if launching_address then
					table.insert(querying, "Init as " .. skynet.address(launching_address))
					table.insert(querying,  skynet.call(launching_address, "debug", "TASK", "init"))
					table.insert(querying, "Launching from " .. skynet.address(v.launch.source))
					table.insert(querying, skynet.call(v.launch.source, "debug", "TASK", v.launch.session))
				end
			end
			if #v > 0 then
				table.insert(querying , "Querying:" )
				for _, detail in ipairs(v) do
					table.insert(querying, skynet.address(detail.source) .. " " .. tostring(skynet.call(detail.source, "debug", "TASK", detail.session)))
				end
			end
			v = table.concat(querying, "\n")
		else
			v = skynet.address(v)
		end

		result[k] = v
	end

	return result
end

--本节点就是主节点
local function register_global()
	function cmd.GLAUNCH(name, ...)
		local global_name = "@" .. name
		return cmd.LAUNCH(global_name, ...)
	end

	function cmd.GQUERY(name, ...)
		local global_name = "@" .. name
		return cmd.QUERY(global_name, ...)
	end

	local mgr = {}

	function cmd.REPORT(m)
		mgr[m] = true
	end

	local function add_list(all, m) --统计所有子节点
		local harbor = "@" .. skynet.harbor(m)
		local result = skynet.call(m, "lua", "LIST")
		for k,v in pairs(result) do
			all[k .. harbor] = v
		end
	end

	function cmd.LIST()
		local result = {}
		for k in pairs(mgr) do
			pcall(add_list, result, k)
		end
		local l = list_service()
		for k, v in pairs(l) do
			result[k] = v
		end
		return result
	end
end

--非主节点方法
local function register_local()
	local function waitfor_remote(cmd, name, ...)
		local global_name = "@" .. name
		local local_name
		if name == "snaxd" then
			local_name = global_name .. "." .. (...)
		else
			local_name = global_name
		end
		return waitfor(local_name, skynet.call, "SERVICE", "lua", cmd, global_name, ...) --询问主节点
	end

	--全网注册服务
	function cmd.GLAUNCH(...)
		return waitfor_remote("LAUNCH", ...)
	end

	--全网获取服务地址
	function cmd.GQUERY(...)
		return waitfor_remote("QUERY", ...)
	end

	function cmd.LIST() --统计自己
		return list_service()
	end

	skynet.call("SERVICE", "lua", "REPORT", skynet.self())
end

skynet.start(function()
	skynet.dispatch("lua", function(session, address, command, ...)
		local f = cmd[command]
		if f == nil then
			skynet.ret(skynet.pack(nil, "Invalid command " .. command))
			return
		end

		local ok, r = pcall(f, ...)

		if ok then
			skynet.ret(skynet.pack(r))
		else
			skynet.ret(skynet.pack(nil, r))
		end
	end)
	local handle = skynet.localname ".service"
	if  handle then
		skynet.error(".service is already register by ", skynet.address(handle))
		skynet.exit()
	else
		skynet.register(".service")
	end
	if skynet.getenv "standalone" then --是主节点
		skynet.register("SERVICE") --全网注册SERVICE
		register_global() --全网函数直接访问
	else
		register_local() --全网函数访问主节点
	end
end)
