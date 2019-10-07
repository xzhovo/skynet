-- "skynet.core" lua-skynet.c
local c = require "skynet.core"
local tostring = tostring
local coroutine = coroutine
local assert = assert
local pairs = pairs
local pcall = pcall
local table = table
local tremove = table.remove
local tinsert = table.insert
local traceback = debug.traceback

local profile = require "skynet.profile" --lua-profile

local cresume = profile.resume
local running_thread = nil
local init_thread = nil

local function coroutine_resume(co, ...)
	running_thread = co
	return cresume(co, ...)
end
local coroutine_yield = profile.yield
local coroutine_create = coroutine.create

local proto = {}
local skynet = {
	-- read skynet.h
	PTYPE_TEXT = 0,
	PTYPE_RESPONSE = 1,
	PTYPE_MULTICAST = 2,
	PTYPE_CLIENT = 3,
	PTYPE_SYSTEM = 4,
	PTYPE_HARBOR = 5,
	PTYPE_SOCKET = 6,
	PTYPE_ERROR = 7,
	PTYPE_QUEUE = 8,	-- used in deprecated mqueue, use skynet.queue instead
	PTYPE_DEBUG = 9,
	PTYPE_LUA = 10,
	PTYPE_SNAX = 11,
	PTYPE_TRACE = 12,	-- use for debug trace
}

-- code cache
skynet.cache = require "skynet.codecache" --service_snlua.c:codecache

--注册自定义消息类型
function skynet.register_protocol(class)
	local name = class.name
	local id = class.id
	assert(proto[name] == nil and proto[id] == nil)
	assert(type(name) == "string" and type(id) == "number" and id >=0 and id <=255)
	proto[name] = class
	proto[id] = class
end

local session_id_coroutine = {} --key:session;value:协程
local session_coroutine_id = {} --key:会话;value:协程
local session_coroutine_address = {} --key:协程;value:源服务地址
local session_coroutine_tracetag = {} --key:协程;value:是否trace
local unresponse = {} --延迟回复表 key:resfun;value:请求方服务源

local wakeup_queue = {} --可唤醒的协程对垒
local sleep_session = {} --睡眠的会话 key协程value会话

local watching_session = {} --call阻塞后监视的session对目的服务地址，0时遍历找服务
local error_queue = {} --错误队列
local fork_queue = {} --skynet.fork用来交出CPU的协程队列 == timeout(0, fun)

-- suspend is function
local suspend


----- monitor exit

--每次协程挂起就处理1次错误队列
local function dispatch_error_queue()
	local session = tremove(error_queue,1)
	if session then
		local co = session_id_coroutine[session]
		session_id_coroutine[session] = nil
		return suspend(co, coroutine_resume(co, false)) --唤醒对应协程传false
	end
end

--skynet.PTYPE_ERROR 消息
local function _error_dispatch(error_session, error_source)
	skynet.ignoreret()	-- don't return for error
	if error_session == 0 then
		-- error_source is down, clear unreponse set
		for resp, address in pairs(unresponse) do
			if error_source == address then
				unresponse[resp] = nil
			end
		end
		for session, srv in pairs(watching_session) do
			if srv == error_source then
				tinsert(error_queue, session)
			end
		end
	else
		-- capture an error for error_session
		if watching_session[error_session] then
			tinsert(error_queue, error_session)
		end
	end
end

-- coroutine reuse

local coroutine_pool = setmetatable({}, { __mode = "kv" })

--创建协程(创建完成后的初始状态是挂起)
local function co_create(f)
	local co = tremove(coroutine_pool) --先从协程池取
	if co == nil then
		co = coroutine_create(function(...) --新创
			f(...) --执行一遍就退休
			while true do
				local session = session_coroutine_id[co]
				if session and session ~= 0 then
					local source = debug.getinfo(f,"S")
					skynet.error(string.format("Maybe forgot response session %s from %s : %s:%d",
						session,
						skynet.address(session_coroutine_address[co]),
						source.source, source.linedefined))
				end
				-- coroutine exit
				local tag = session_coroutine_tracetag[co]
				if tag ~= nil then
					if tag then c.trace(tag, "end")	end
					session_coroutine_tracetag[co] = nil
				end
				local address = session_coroutine_address[co]
				if address then
					session_coroutine_id[co] = nil --清空协程session
					session_coroutine_address[co] = nil --清空协程记录的源服务
				end

				-- recycle co into pool
				f = nil
				coroutine_pool[#coroutine_pool+1] = co --挂起并加到协程池
				-- recv new main function f
				f = coroutine_yield "SUSPEND" --挂起
				f(coroutine_yield()) --先执行 coroutine_yield() , 挂起，完成从协程池取协程的创建, 待再次 coroutine_resume 传参唤醒，此时相当于执行f(...)
			end
		end)
	else
		-- pass the main function f to coroutine, and restore running thread
		local running = running_thread
		coroutine_resume(co, f) --唤醒执行f就行，重复if中while流程中的 f(coroutine_yield())
		running_thread = running
	end
	return co
end

local function dispatch_wakeup() --前辈挂起,唤醒后辈
	local token = tremove(wakeup_queue,1) --返回第一个wakeup的协程token
	if token then
		local session = sleep_session[token] --获取协程session
		if session then
			local co = session_id_coroutine[session] --获取协程??token~=co??
			local tag = session_coroutine_tracetag[co] --加入打印栈
			if tag then c.trace(tag, "resume") end --打印命名resume
			session_id_coroutine[session] = "BREAK" --将状态置为正在唤醒
			return suspend(co, coroutine_resume(co, false, "BREAK")) --c唤醒o协程,挂起或者退出调用suspend切换到其他wakeup协程或退出服务
		end
	end
end

-- suspend is local function
function suspend(co, result, command)
	if not result then
		local session = session_coroutine_id[co]
		if session then -- coroutine may fork by others (session is nil)
			local addr = session_coroutine_address[co]
			if session ~= 0 then
				-- only call response error
				local tag = session_coroutine_tracetag[co]
				if tag then c.trace(tag, "error") end
				c.send(addr, skynet.PTYPE_ERROR, session, "")
			end
			session_coroutine_id[co] = nil
			session_coroutine_address[co] = nil
			session_coroutine_tracetag[co] = nil
		end
		skynet.fork(function() end)	-- trigger command "SUSPEND"
		error(debug.traceback(co,tostring(command)))
	end
	if command == "SUSPEND" then
		dispatch_wakeup() --挂当前，唤醒下一个
		dispatch_error_queue() --有错误就处理对应协程
	elseif command == "QUIT" then
		-- service exit
		return
	elseif command == "USER" then
		-- See skynet.coutine for detail
		error("Call skynet.coroutine.yield out of skynet.coroutine.resume\n" .. debug.traceback(co))
	elseif command == nil then
		-- debug trace
		return
	else
		error("Unknown command : " .. command .. "\n" .. debug.traceback(co))
	end
end

--让框架在 ti 个单位时间后，调用 func 这个函数
function skynet.timeout(ti, func)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	local co = co_create(func)
	assert(session_id_coroutine[session] == nil)
	session_id_coroutine[session] = co
	return co	-- for debug
end

--休眠挂起
local function suspend_sleep(session, token)
	local tag = session_coroutine_tracetag[running_thread] --该协程是否需要打印栈
	if tag then c.trace(tag, "sleep", 2) end --打印事件命名sleep, 至多2层函数
	session_id_coroutine[session] = running_thread --session to 协程
	assert(sleep_session[token] == nil, "token duplicative")
	sleep_session[token] = session --该协程标记上session并加入sleep_session

	return coroutine_yield "SUSPEND" --挂起,返回"SUSPEND"给resume,最终在suspend唤醒其他wait协程
end

-- 将当前 coroutine 挂起 ti 个单位时间。
function skynet.sleep(ti, token)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	token = token or coroutine.running()
	local succ, ret = suspend_sleep(session, token) --dispatch_wakeup唤醒返回false, "BREAK"
	sleep_session[token] = nil
	if succ then
		return
	end
	if ret == "BREAK" then
		return "BREAK"
	else
		error(ret)
	end
end

--交出当前服务对 CPU 的控制权。通常在你想做大量的操作，又没有机会调用阻塞 API 时，可以选择调用 yield 让系统跑的更平滑。
function skynet.yield()
	return skynet.sleep(0)
end

--把当前 coroutine 挂起，之后由 skynet.wakeup 唤醒
function skynet.wait(token) --让协程挂起等待 token默认为coroutine.running()
	local session = c.genid()
	token = token or coroutine.running()
	local ret, msg = suspend_sleep(session, token) --函数暂时终止(未返回),再次resume时继续并返回
	sleep_session[token] = nil
	session_id_coroutine[session] = nil
end

function skynet.self()
	return c.addresscommand "REG"
end

--获取本节点服务名
function skynet.localname(name)
	return c.addresscommand("QUERY", name)
end

skynet.now = c.now
skynet.hpc = c.hpc	-- high performance counter

local traceid = 0
function skynet.trace(info)
	skynet.error("TRACE", session_coroutine_tracetag[running_thread])
	if session_coroutine_tracetag[running_thread] == false then
		-- force off trace log
		return
	end
	traceid = traceid + 1

	local tag = string.format(":%08x-%d",skynet.self(), traceid)
	session_coroutine_tracetag[running_thread] = tag
	if info then
		c.trace(tag, "trace " .. info)
	else
		c.trace(tag, "trace")
	end
end

function skynet.tracetag()
	return session_coroutine_tracetag[running_thread]
end

local starttime

--skynet启动时间
function skynet.starttime()
	if not starttime then
		starttime = c.intcommand("STARTTIME")
	end
	return starttime
end

--skynet当前时间(不是系统时间)
function skynet.time()
	return skynet.now()/100 + (starttime or skynet.starttime())
end

--skynet启动时间(秒)
function skynet.nowSeconed()
	return math.floor(skynet.now()/100)
end

--skynet当前时间(秒)
function skynet.timeSeconed()
	return math.floor(skynet.now()/100 + (starttime or skynet.starttime()))
end

--退出服务
function skynet.exit()
	fork_queue = {}	-- no fork coroutine can be execute after skynet.exit
	skynet.send(".launcher","lua","REMOVE",skynet.self(), false)
	-- report the sources that call me
	for co, session in pairs(session_coroutine_id) do
		local address = session_coroutine_address[co]
		if session~=0 and address then
			c.send(address, skynet.PTYPE_ERROR, session, "")
		end
	end
	for resp in pairs(unresponse) do --延迟回应的直接回应false
		resp(false)
	end
	-- report the sources I call but haven't return
	local tmp = {}
	for session, address in pairs(watching_session) do
		tmp[address] = true
	end
	for address in pairs(tmp) do
		c.send(address, skynet.PTYPE_ERROR, 0, "")
	end
	c.command("EXIT")
	-- quit service
	coroutine_yield "QUIT"
end

--获取环境变量
function skynet.getenv(key)
	return (c.command("GETENV",key))
end

--设置环境变量
function skynet.setenv(key, value)
	assert(c.command("GETENV",key) == nil, "Can't setenv exist key : " .. key)
	c.command("SETENV",key .. " " ..value)
end

function skynet.send(addr, typename, ...)
	local p = proto[typename]
	return c.send(addr, p.id, 0 , p.pack(...))
end

--和 skynet.send 类似。但发送时不经过 pack 打包流程
function skynet.rawsend(addr, typename, msg, sz)
	local p = proto[typename]
	return c.send(addr, p.id, 0 , msg, sz)
end

skynet.genid = assert(c.genid)

skynet.redirect = function(dest,source,typename,...)
	return c.redirect(dest, source, proto[typename].id, ...)
end

skynet.pack = assert(c.pack)
skynet.packstring = assert(c.packstring)
skynet.unpack = assert(c.unpack) --lua-seri.c:luaseri_unpack
skynet.tostring = assert(c.tostring)
skynet.trash = assert(c.trash)

--挂起 call 协程，等回应
local function yield_call(service, session)
	watching_session[session] = service --watching_session for error
	session_id_coroutine[session] = running_thread
	local succ, msg, sz = coroutine_yield "SUSPEND"
	watching_session[session] = nil
	if not succ then
		error ("call failed "..service..","..session)
	end
	return msg,sz
end

--skynet.send
--local p = proto[typename]
--return c.send(addr, p.id, 0 , p.pack(...))
function skynet.call(addr, typename, ...)
	if not addr then
		local protoName = ...
		error("call addr is nil, " .. protoName)
	end
	local tag = session_coroutine_tracetag[running_thread] --string.format(":%08x-%d",skynet.self(), traceid)
	if tag then --消息跟踪日志
		c.trace(tag, "call", 2) --2层
		c.send(addr, skynet.PTYPE_TRACE, 0, tag)
	end

	local p = proto[typename]
	local session = c.send(addr, p.id , nil , p.pack(...))
	if session == nil then
		error("call to invalid address " .. skynet.address(addr))
	end
	return p.unpack(yield_call(addr, session))
end

--和 skynet.call 类似。但发送时不经过 pack 打包流程，收到回应后，也不走 unpack 流程。
function skynet.rawcall(addr, typename, msg, sz)
	local tag = session_coroutine_tracetag[running_thread]
	if tag then
		c.trace(tag, "call", 2)
		c.send(addr, skynet.PTYPE_TRACE, 0, tag)
	end
	local p = proto[typename]
	local session = assert(c.send(addr, p.id , nil , msg, sz), "call to invalid address")
	return yield_call(addr, session)
end

--需要trace的call
function skynet.tracecall(tag, addr, typename, msg, sz)
	c.trace(tag, "tracecall begin")
	c.send(addr, skynet.PTYPE_TRACE, 0, tag)
	local p = proto[typename]
	local session = assert(c.send(addr, p.id , nil , msg, sz), "call to invalid address")
	local msg, sz = yield_call(addr, session)
	c.trace(tag, "tracecall end")
	return msg, sz
end

--回应
function skynet.ret(msg, sz)
	msg = msg or ""
	local tag = session_coroutine_tracetag[running_thread]
	if tag then c.trace(tag, "response") end
	local co_session = session_coroutine_id[running_thread]
	session_coroutine_id[running_thread] = nil
	if co_session == 0 then
		if sz ~= nil then
			c.trash(msg, sz)
		end
		return false	-- send don't need ret
	end
	local co_address = session_coroutine_address[running_thread]
	if not co_session then
		error "No session"
	end
	local ret = c.send(co_address, skynet.PTYPE_RESPONSE, co_session, msg, sz)
	if ret then
		return true
	elseif ret == false then
		-- If the package is too large, returns false. so we should report error back
		c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
	end
	return false
end

--获取当前协程会话信息和源服务地址
function skynet.context()
	local co_session = session_coroutine_id[running_thread]
	local co_address = session_coroutine_address[running_thread]
	return co_session, co_address
end

--不回复(比如服务端通知客户端)
function skynet.ignoreret()
	-- We use session for other uses
	session_coroutine_id[running_thread] = nil
end

--返回的闭包可用于延迟回应
function skynet.response(pack)
	pack = pack or skynet.pack

	local co_session = assert(session_coroutine_id[running_thread], "no session")
	session_coroutine_id[running_thread] = nil
	local co_address = session_coroutine_address[running_thread]
	if co_session == 0 then
		--  do not response when session == 0 (send)
		return function() end
	end
	local function response(ok, ...)
		if ok == "TEST" then
			return unresponse[response] ~= nil
		end
		if not pack then
			error "Can't response more than once"
		end

		local ret
		if unresponse[response] then
			if ok then
				ret = c.send(co_address, skynet.PTYPE_RESPONSE, co_session, pack(...))
				if ret == false then
					-- If the package is too large, returns false. so we should report error back
					c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
				end
			else
				ret = c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
			end
			unresponse[response] = nil
			ret = ret ~= nil
		else
			ret = false
		end
		pack = nil
		return ret
	end
	unresponse[response] = co_address

	return response
end

--打包消息回复
function skynet.retpack(...)
	return skynet.ret(skynet.pack(...))
end

--唤醒sleep的协程
function skynet.wakeup(token)
	if sleep_session[token] then
		tinsert(wakeup_queue, token)
		return true
	end
end

--注册对应类型的回调函数
function skynet.dispatch(typename, func)
	local p = proto[typename]
	if func then
		local ret = p.dispatch
		p.dispatch = func
		return ret
	else
		return p and p.dispatch
	end
end

local function unknown_request(session, address, msg, sz, prototype)
	skynet.error(string.format("Unknown request (%s): %s", prototype, c.tostring(msg,sz)))
	error(string.format("Unknown session : %d from %x", session, address))
end

function skynet.dispatch_unknown_request(unknown)
	local prev = unknown_request
	unknown_request = unknown
	return prev
end

local function unknown_response(session, address, msg, sz)
	skynet.error(string.format("Response message : %s" , c.tostring(msg,sz)))
	error(string.format("Unknown session : %d from %x", session, address))
end

function skynet.dispatch_unknown_response(unknown)
	local prev = unknown_response
	unknown_response = unknown
	return prev
end

--它等价于 skynet.timeout(0, function() func(...) end) 但是比 timeout 高效一点。因为它并不需要向框架注册一个定时器。
--func 里面一定要有挂起，也就是阻塞调用，不然毫无意义，因为 fork_queue 是在消息处理函数挂起后 while true 遍历唤醒处理，挂起时继续循环
function skynet.fork(func,...)
	local n = select("#", ...) --...中的参数个数
	local co
	if n == 0 then
		co = co_create(func)
	else
		local args = { ... }
		co = co_create(function() func(table.unpack(args,1,n)) end) --带参
	end
	tinsert(fork_queue, co)
	return co
end

local trace_source = {}

--真正消息处理(这才是服务运转时的main函数)
local function raw_dispatch_message(prototype, msg, sz, session, source)
	-- skynet.PTYPE_RESPONSE = 1, read skynet.h
	if prototype == 1 then
		local co = session_id_coroutine[session]
		if co == "BREAK" then --已经唤醒了但session_id_coroutine[session]还存在
			session_id_coroutine[session] = nil
		elseif co == nil then
			unknown_response(session, source, msg, sz)
		else
			local tag = session_coroutine_tracetag[co]
			if tag then c.trace(tag, "resume") end
			session_id_coroutine[session] = nil
			suspend(co, coroutine_resume(co, true, msg, sz)) --切换co为当前工作的协程，唤醒yield_call挂起的地方，将true, msg, sz传入，处理call的ret
		end
	else
		local p = proto[prototype]
		if p == nil then
			if prototype == skynet.PTYPE_TRACE then --trace消息，请求方指定需要trace，在call前会发这个(send无需
				-- trace next request
				trace_source[source] = c.tostring(msg,sz) --设置要trace的请求方的trace开关
			elseif session ~= 0 then --是会话但是非法协议
				c.send(source, skynet.PTYPE_ERROR, session, "")
			else
				unknown_request(session, source, msg, sz, prototype)
			end
			return
		end

		local f = p.dispatch --服务skynet.dispatch设置的对应类型的function
		if f then
			local co = co_create(f)
			session_coroutine_id[co] = session --记录会话号
			session_coroutine_address[co] = source --记录请求方服务源
			local traceflag = p.trace --默认nil skynet.traceproto设置trace协议
			if traceflag == false then --关闭trace，这里优先级高于trace_source，所以就算请求方要trace也不行
				-- force off
				trace_source[source] = nil
				session_coroutine_tracetag[co] = false
			else
				local tag = trace_source[source]
				if tag then --请求方事先通知了tag==true
					trace_source[source] = nil
					c.trace(tag, "request")
					session_coroutine_tracetag[co] = tag
				elseif traceflag then --自己要tag
					-- set running_thread for trace
					running_thread = co
					skynet.trace()
				end
			end
			suspend(co, coroutine_resume(co, session,source, p.unpack(msg,sz)))
		else
			trace_source[source] = nil
			if session ~= 0 then
				c.send(source, skynet.PTYPE_ERROR, session, "") --通知请求方不能处理
			else
				unknown_request(session, source, msg, sz, proto[prototype].name)
			end
		end
	end
end

--处理消息(这是一个回调函数，用于在被其他服务调用，消息驱动 skynet_server.c:dispatch_message -> lua-skynet.c:_cb -> here)
function skynet.dispatch_message(...)
	local succ, err = pcall(raw_dispatch_message,...)
	while true do --有消息就处理skynet.fork的fork_queue所有
		local co = tremove(fork_queue,1)
		if co == nil then
			break
		end
		local fork_succ, fork_err = pcall(suspend,co,coroutine_resume(co)) --唤醒继续处理，谢谢你交出CPU，挂起第一个阻塞，也就是说 fork 的 func 不一定走完
		if not fork_succ then
			if succ then
				succ = false
				err = tostring(fork_err)
			else
				err = tostring(err) .. "\n" .. tostring(fork_err)
			end
		end
	end
	assert(succ, tostring(err))
	collectgarbage("step") --内存紧张的环境增加gc的主动性
end

--启动可重复服务
function skynet.newservice(name, ...)
	return skynet.call(".launcher", "lua" , "LAUNCH", "snlua", name, ...)
end

--启动不重复的服务, global==true->全网;否则名字
function skynet.uniqueservice(global, ...)
	if global == true then
		return assert(skynet.call(".service", "lua", "GLAUNCH", ...)) -- .service == service_mgr
	else
		return assert(skynet.call(".service", "lua", "LAUNCH", global, ...))
	end
end

--获取服务名(可全网)
function skynet.queryservice(global, ...)
	if global == true then
		return assert(skynet.call(".service", "lua", "GQUERY", ...))
	else
		return assert(skynet.call(".service", "lua", "QUERY", global, ...))
	end
end

--格式化服务地址
function skynet.address(addr)
	if type(addr) == "number" then
		return string.format(":%08x",addr)
	else
		return tostring(addr)
	end
end

--获得服务所属的节点
function skynet.harbor(addr)
	return c.harbor(addr)
end

skynet.error = c.error
-- function skynet.error(str, ...)
-- 	-- local t = {...}
-- 	-- for i=1, #t do
--  --        str = str .. ", " .. t[i]
--  --    end
-- 	local date=os.date("%H:%M:%S: ") --这里改到service_logger.c中加可能更好,for对比下时效
-- 	c.error(date..str, ...)
-- end

-- log解释器的运行时栈的信息
skynet.tracelog = c.trace

--trace log消息
-- true: force on
-- false: force off
-- nil: optional (use skynet.trace() to trace one message)
function skynet.traceproto(prototype, flag)
	local p = assert(proto[prototype])
	p.trace = flag
end

----- register protocol
do
	local REG = skynet.register_protocol

	REG {
		name = "lua",
		id = skynet.PTYPE_LUA,
		pack = skynet.pack,
		unpack = skynet.unpack,
	}

	REG {
		name = "response",
		id = skynet.PTYPE_RESPONSE,
	}

	REG {
		name = "error",
		id = skynet.PTYPE_ERROR,
		unpack = function(...) return ... end,
		dispatch = _error_dispatch,
	}
end

local init_func = {}

--服务初始化 
--这通常用于 lua 库的编写。你需要编写的服务引用你的库的时候，事先调用一些 skynet 阻塞 API ，就可以用 skynet.init 把这些工作注册在 start 之前。
function skynet.init(f, name)
	assert(type(f) == "function")
	if init_func == nil then
		f()
	else
		tinsert(init_func, f)
		if name then
			assert(type(name) == "string")
			assert(init_func[name] == nil)
			init_func[name] = f
		end
	end
end

local function init_all()
	local funcs = init_func
	init_func = nil
	if funcs then
		for _,f in ipairs(funcs) do
			f()
		end
	end
end

local function ret(f, ...)
	f()
	return ...
end

local function init_template(start, ...)
	init_all()
	init_func = {}
	return ret(init_all, start(...))
end

--预先init，在调用
function skynet.pcall(start, ...)
	return xpcall(init_template, debug.traceback, start, ...)
end

function skynet.init_service(start)
	local ok, err = skynet.pcall(start)
	if not ok then
		skynet.error("init service failed: " .. tostring(err))
		skynet.send(".launcher","lua", "ERROR")
		skynet.exit()
	else
		skynet.send(".launcher","lua", "LAUNCHOK") --launcher.lua:LAUNCHOK
	end
end

--服务启动
function skynet.start(start_func)
	c.callback(skynet.dispatch_message)
	init_thread = skynet.timeout(0, function()
		skynet.init_service(start_func)
		init_thread = nil
	end)
end

--获取服务是否是死循环
function skynet.endless()
	return (c.intcommand("STAT", "endless") == 1) --lua-skynet.c:lintcommand -> skynet_server.c:cmd_stat
end

--获取服务次级消息队列长度(未发送
function skynet.mqlen()
	return c.intcommand("STAT", "mqlen")
end

--"mqlen","endless","cpu"占用时间,"time"运行时长,"message"处理派发的消息总数
function skynet.stat(what)
	return c.intcommand("STAT", what)
end

--
function skynet.task(ret)
	if ret == nil then --默认返回会话数(一会话一协程
		local t = 0
		for session,co in pairs(session_id_coroutine) do
			t = t + 1
		end
		return t
	end
	if ret == "init" then --初始化
		if init_thread then
			return debug.traceback(init_thread)
		else
			return
		end
	end
	local tt = type(ret)
	if tt == "table" then --获取会话协程信息
		for session,co in pairs(session_id_coroutine) do
			ret[session] = traceback(co)
		end
		return
	elseif tt == "number" then --获取指定会话的协程信息
		local co = session_id_coroutine[ret]
		if co then
			return debug.traceback(co)
		else
			return "No session"
		end
	elseif tt == "thread" then --获取指定协程的会话信息
		for session, co in pairs(session_id_coroutine) do
			if co == ret then
				return session
			end
		end
		return
	end
end

function skynet.uniqtask()
	local stacks = {}
	for session, co in pairs(session_id_coroutine) do
		local stack = traceback(co)
		local info = stacks[stack] or {count = 0, sessions = {}}
		info.count = info.count + 1
		if info.count < 10 then
			info.sessions[#info.sessions+1] = session
		end
		stacks[stack] = info
	end
	local ret = {}
	for stack, info in pairs(stacks) do
		local count = info.count
		local sessions = table.concat(info.sessions, ",")
		if count > 10 then
			sessions = sessions .. "..."
		end
		local head_line = string.format("%d\tsessions:[%s]\n", count, sessions)
		ret[head_line] = stack
	end
	return ret
end

-- 传skynet.PTYPE_ERROR 给服务service(测试用 现有debug term
function skynet.term(service)
	return _error_dispatch(0, service)
end

--设置服务最大内存
function skynet.memlimit(bytes)
	debug.getregistry().memlimit = bytes
	skynet.memlimit = nil	-- set only once
end

-- Inject internal debug framework
local debug = require "skynet.debug"
debug.init(skynet, {
	dispatch = skynet.dispatch_message,
	suspend = suspend,
})

return skynet
