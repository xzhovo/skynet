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

--ע���Զ�����Ϣ����
function skynet.register_protocol(class)
	local name = class.name
	local id = class.id
	assert(proto[name] == nil and proto[id] == nil)
	assert(type(name) == "string" and type(id) == "number" and id >=0 and id <=255)
	proto[name] = class
	proto[id] = class
end

local session_id_coroutine = {} --key:session;value:Э��
local session_coroutine_id = {} --key:�Ự;value:Э��
local session_coroutine_address = {} --key:Э��;value:Դ�����ַ
local session_coroutine_tracetag = {} --key:Э��;value:�Ƿ�trace
local unresponse = {} --�ӳٻظ��� key:resfun;value:���󷽷���Դ

local wakeup_queue = {} --�ɻ��ѵ�Э�̶���
local sleep_session = {} --˯�ߵĻỰ keyЭ��value�Ự

local watching_session = {} --call��������ӵ�session��Ŀ�ķ����ַ��0ʱ�����ҷ���
local error_queue = {} --�������
local fork_queue = {} --skynet.fork��������CPU��Э�̶��� == timeout(0, fun)

-- suspend is function
local suspend


----- monitor exit

--ÿ��Э�̹���ʹ���1�δ������
local function dispatch_error_queue()
	local session = tremove(error_queue,1)
	if session then
		local co = session_id_coroutine[session]
		session_id_coroutine[session] = nil
		return suspend(co, coroutine_resume(co, false)) --���Ѷ�ӦЭ�̴�false
	end
end

--skynet.PTYPE_ERROR ��Ϣ
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

--����Э��(������ɺ�ĳ�ʼ״̬�ǹ���)
local function co_create(f)
	local co = tremove(coroutine_pool) --�ȴ�Э�̳�ȡ
	if co == nil then
		co = coroutine_create(function(...) --�´�
			f(...) --ִ��һ�������
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
					session_coroutine_id[co] = nil --���Э��session
					session_coroutine_address[co] = nil --���Э�̼�¼��Դ����
				end

				-- recycle co into pool
				f = nil
				coroutine_pool[#coroutine_pool+1] = co --���𲢼ӵ�Э�̳�
				-- recv new main function f
				f = coroutine_yield "SUSPEND" --����
				f(coroutine_yield()) --��ִ�� coroutine_yield() , ������ɴ�Э�̳�ȡЭ�̵Ĵ���, ���ٴ� coroutine_resume ���λ��ѣ���ʱ�൱��ִ��f(...)
			end
		end)
	else
		-- pass the main function f to coroutine, and restore running thread
		local running = running_thread
		coroutine_resume(co, f) --����ִ��f���У��ظ�if��while�����е� f(coroutine_yield())
		running_thread = running
	end
	return co
end

local function dispatch_wakeup() --ǰ������,���Ѻ�
	local token = tremove(wakeup_queue,1) --���ص�һ��wakeup��Э��token
	if token then
		local session = sleep_session[token] --��ȡЭ��session
		if session then
			local co = session_id_coroutine[session] --��ȡЭ��??token~=co??
			local tag = session_coroutine_tracetag[co] --�����ӡջ
			if tag then c.trace(tag, "resume") end --��ӡ����resume
			session_id_coroutine[session] = "BREAK" --��״̬��Ϊ���ڻ���
			return suspend(co, coroutine_resume(co, false, "BREAK")) --c����oЭ��,��������˳�����suspend�л�������wakeupЭ�̻��˳�����
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
		dispatch_wakeup() --�ҵ�ǰ��������һ��
		dispatch_error_queue() --�д���ʹ����ӦЭ��
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

--�ÿ���� ti ����λʱ��󣬵��� func �������
function skynet.timeout(ti, func)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	local co = co_create(func)
	assert(session_id_coroutine[session] == nil)
	session_id_coroutine[session] = co
	return co	-- for debug
end

--���߹���
local function suspend_sleep(session, token)
	local tag = session_coroutine_tracetag[running_thread] --��Э���Ƿ���Ҫ��ӡջ
	if tag then c.trace(tag, "sleep", 2) end --��ӡ�¼�����sleep, ����2�㺯��
	session_id_coroutine[session] = running_thread --session to Э��
	assert(sleep_session[token] == nil, "token duplicative")
	sleep_session[token] = session --��Э�̱����session������sleep_session

	return coroutine_yield "SUSPEND" --����,����"SUSPEND"��resume,������suspend��������waitЭ��
end

-- ����ǰ coroutine ���� ti ����λʱ�䡣
function skynet.sleep(ti, token)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	token = token or coroutine.running()
	local succ, ret = suspend_sleep(session, token) --dispatch_wakeup���ѷ���false, "BREAK"
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

--������ǰ����� CPU �Ŀ���Ȩ��ͨ���������������Ĳ�������û�л���������� API ʱ������ѡ����� yield ��ϵͳ�ܵĸ�ƽ����
function skynet.yield()
	return skynet.sleep(0)
end

--�ѵ�ǰ coroutine ����֮���� skynet.wakeup ����
function skynet.wait(token) --��Э�̹���ȴ� tokenĬ��Ϊcoroutine.running()
	local session = c.genid()
	token = token or coroutine.running()
	local ret, msg = suspend_sleep(session, token) --������ʱ��ֹ(δ����),�ٴ�resumeʱ����������
	sleep_session[token] = nil
	session_id_coroutine[session] = nil
end

function skynet.self()
	return c.addresscommand "REG"
end

--��ȡ���ڵ������
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

--skynet����ʱ��
function skynet.starttime()
	if not starttime then
		starttime = c.intcommand("STARTTIME")
	end
	return starttime
end

--skynet��ǰʱ��(����ϵͳʱ��)
function skynet.time()
	return skynet.now()/100 + (starttime or skynet.starttime())
end

--skynet����ʱ��(��)
function skynet.nowSeconed()
	return math.floor(skynet.now()/100)
end

--skynet��ǰʱ��(��)
function skynet.timeSeconed()
	return math.floor(skynet.now()/100 + (starttime or skynet.starttime()))
end

--�˳�����
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
	for resp in pairs(unresponse) do --�ӳٻ�Ӧ��ֱ�ӻ�Ӧfalse
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

--��ȡ��������
function skynet.getenv(key)
	return (c.command("GETENV",key))
end

--���û�������
function skynet.setenv(key, value)
	assert(c.command("GETENV",key) == nil, "Can't setenv exist key : " .. key)
	c.command("SETENV",key .. " " ..value)
end

function skynet.send(addr, typename, ...)
	local p = proto[typename]
	return c.send(addr, p.id, 0 , p.pack(...))
end

--�� skynet.send ���ơ�������ʱ������ pack �������
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

--���� call Э�̣��Ȼ�Ӧ
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
	if tag then --��Ϣ������־
		c.trace(tag, "call", 2) --2��
		c.send(addr, skynet.PTYPE_TRACE, 0, tag)
	end

	local p = proto[typename]
	local session = c.send(addr, p.id , nil , p.pack(...))
	if session == nil then
		error("call to invalid address " .. skynet.address(addr))
	end
	return p.unpack(yield_call(addr, session))
end

--�� skynet.call ���ơ�������ʱ������ pack ������̣��յ���Ӧ��Ҳ���� unpack ���̡�
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

--��Ҫtrace��call
function skynet.tracecall(tag, addr, typename, msg, sz)
	c.trace(tag, "tracecall begin")
	c.send(addr, skynet.PTYPE_TRACE, 0, tag)
	local p = proto[typename]
	local session = assert(c.send(addr, p.id , nil , msg, sz), "call to invalid address")
	local msg, sz = yield_call(addr, session)
	c.trace(tag, "tracecall end")
	return msg, sz
end

--��Ӧ
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

--��ȡ��ǰЭ�̻Ự��Ϣ��Դ�����ַ
function skynet.context()
	local co_session = session_coroutine_id[running_thread]
	local co_address = session_coroutine_address[running_thread]
	return co_session, co_address
end

--���ظ�(��������֪ͨ�ͻ���)
function skynet.ignoreret()
	-- We use session for other uses
	session_coroutine_id[running_thread] = nil
end

--���صıհ��������ӳٻ�Ӧ
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

--�����Ϣ�ظ�
function skynet.retpack(...)
	return skynet.ret(skynet.pack(...))
end

--����sleep��Э��
function skynet.wakeup(token)
	if sleep_session[token] then
		tinsert(wakeup_queue, token)
		return true
	end
end

--ע���Ӧ���͵Ļص�����
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

--���ȼ��� skynet.timeout(0, function() func(...) end) ���Ǳ� timeout ��Чһ�㡣��Ϊ��������Ҫ����ע��һ����ʱ����
--func ����һ��Ҫ�й���Ҳ�����������ã���Ȼ�������壬��Ϊ fork_queue ������Ϣ����������� while true �������Ѵ�������ʱ����ѭ��
function skynet.fork(func,...)
	local n = select("#", ...) --...�еĲ�������
	local co
	if n == 0 then
		co = co_create(func)
	else
		local args = { ... }
		co = co_create(function() func(table.unpack(args,1,n)) end) --����
	end
	tinsert(fork_queue, co)
	return co
end

local trace_source = {}

--������Ϣ����(����Ƿ�����תʱ��main����)
local function raw_dispatch_message(prototype, msg, sz, session, source)
	-- skynet.PTYPE_RESPONSE = 1, read skynet.h
	if prototype == 1 then
		local co = session_id_coroutine[session]
		if co == "BREAK" then --�Ѿ������˵�session_id_coroutine[session]������
			session_id_coroutine[session] = nil
		elseif co == nil then
			unknown_response(session, source, msg, sz)
		else
			local tag = session_coroutine_tracetag[co]
			if tag then c.trace(tag, "resume") end
			session_id_coroutine[session] = nil
			suspend(co, coroutine_resume(co, true, msg, sz)) --�л�coΪ��ǰ������Э�̣�����yield_call����ĵط�����true, msg, sz���룬����call��ret
		end
	else
		local p = proto[prototype]
		if p == nil then
			if prototype == skynet.PTYPE_TRACE then --trace��Ϣ������ָ����Ҫtrace����callǰ�ᷢ���(send����
				-- trace next request
				trace_source[source] = c.tostring(msg,sz) --����Ҫtrace�����󷽵�trace����
			elseif session ~= 0 then --�ǻỰ���ǷǷ�Э��
				c.send(source, skynet.PTYPE_ERROR, session, "")
			else
				unknown_request(session, source, msg, sz, prototype)
			end
			return
		end

		local f = p.dispatch --����skynet.dispatch���õĶ�Ӧ���͵�function
		if f then
			local co = co_create(f)
			session_coroutine_id[co] = session --��¼�Ự��
			session_coroutine_address[co] = source --��¼���󷽷���Դ
			local traceflag = p.trace --Ĭ��nil skynet.traceproto����traceЭ��
			if traceflag == false then --�ر�trace���������ȼ�����trace_source�����Ծ�������ҪtraceҲ����
				-- force off
				trace_source[source] = nil
				session_coroutine_tracetag[co] = false
			else
				local tag = trace_source[source]
				if tag then --��������֪ͨ��tag==true
					trace_source[source] = nil
					c.trace(tag, "request")
					session_coroutine_tracetag[co] = tag
				elseif traceflag then --�Լ�Ҫtag
					-- set running_thread for trace
					running_thread = co
					skynet.trace()
				end
			end
			suspend(co, coroutine_resume(co, session,source, p.unpack(msg,sz)))
		else
			trace_source[source] = nil
			if session ~= 0 then
				c.send(source, skynet.PTYPE_ERROR, session, "") --֪ͨ���󷽲��ܴ���
			else
				unknown_request(session, source, msg, sz, proto[prototype].name)
			end
		end
	end
end

--������Ϣ(����һ���ص������������ڱ�����������ã���Ϣ���� skynet_server.c:dispatch_message -> lua-skynet.c:_cb -> here)
function skynet.dispatch_message(...)
	local succ, err = pcall(raw_dispatch_message,...)
	while true do --����Ϣ�ʹ���skynet.fork��fork_queue����
		local co = tremove(fork_queue,1)
		if co == nil then
			break
		end
		local fork_succ, fork_err = pcall(suspend,co,coroutine_resume(co)) --���Ѽ�������лл�㽻��CPU�������һ��������Ҳ����˵ fork �� func ��һ������
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
	collectgarbage("step") --�ڴ���ŵĻ�������gc��������
end

--�������ظ�����
function skynet.newservice(name, ...)
	return skynet.call(".launcher", "lua" , "LAUNCH", "snlua", name, ...)
end

--�������ظ��ķ���, global==true->ȫ��;��������
function skynet.uniqueservice(global, ...)
	if global == true then
		return assert(skynet.call(".service", "lua", "GLAUNCH", ...)) -- .service == service_mgr
	else
		return assert(skynet.call(".service", "lua", "LAUNCH", global, ...))
	end
end

--��ȡ������(��ȫ��)
function skynet.queryservice(global, ...)
	if global == true then
		return assert(skynet.call(".service", "lua", "GQUERY", ...))
	else
		return assert(skynet.call(".service", "lua", "QUERY", global, ...))
	end
end

--��ʽ�������ַ
function skynet.address(addr)
	if type(addr) == "number" then
		return string.format(":%08x",addr)
	else
		return tostring(addr)
	end
end

--��÷��������Ľڵ�
function skynet.harbor(addr)
	return c.harbor(addr)
end

skynet.error = c.error
-- function skynet.error(str, ...)
-- 	-- local t = {...}
-- 	-- for i=1, #t do
--  --        str = str .. ", " .. t[i]
--  --    end
-- 	local date=os.date("%H:%M:%S: ") --����ĵ�service_logger.c�мӿ��ܸ���,for�Ա���ʱЧ
-- 	c.error(date..str, ...)
-- end

-- log������������ʱջ����Ϣ
skynet.tracelog = c.trace

--trace log��Ϣ
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

--�����ʼ�� 
--��ͨ������ lua ��ı�д������Ҫ��д�ķ���������Ŀ��ʱ�����ȵ���һЩ skynet ���� API ���Ϳ����� skynet.init ����Щ����ע���� start ֮ǰ��
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

--Ԥ��init���ڵ���
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

--��������
function skynet.start(start_func)
	c.callback(skynet.dispatch_message)
	init_thread = skynet.timeout(0, function()
		skynet.init_service(start_func)
		init_thread = nil
	end)
end

--��ȡ�����Ƿ�����ѭ��
function skynet.endless()
	return (c.intcommand("STAT", "endless") == 1) --lua-skynet.c:lintcommand -> skynet_server.c:cmd_stat
end

--��ȡ����μ���Ϣ���г���(δ����
function skynet.mqlen()
	return c.intcommand("STAT", "mqlen")
end

--"mqlen","endless","cpu"ռ��ʱ��,"time"����ʱ��,"message"�����ɷ�����Ϣ����
function skynet.stat(what)
	return c.intcommand("STAT", what)
end

--
function skynet.task(ret)
	if ret == nil then --Ĭ�Ϸ��ػỰ��(һ�ỰһЭ��
		local t = 0
		for session,co in pairs(session_id_coroutine) do
			t = t + 1
		end
		return t
	end
	if ret == "init" then --��ʼ��
		if init_thread then
			return debug.traceback(init_thread)
		else
			return
		end
	end
	local tt = type(ret)
	if tt == "table" then --��ȡ�ỰЭ����Ϣ
		for session,co in pairs(session_id_coroutine) do
			ret[session] = traceback(co)
		end
		return
	elseif tt == "number" then --��ȡָ���Ự��Э����Ϣ
		local co = session_id_coroutine[ret]
		if co then
			return debug.traceback(co)
		else
			return "No session"
		end
	elseif tt == "thread" then --��ȡָ��Э�̵ĻỰ��Ϣ
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

-- ��skynet.PTYPE_ERROR ������service(������ ����debug term
function skynet.term(service)
	return _error_dispatch(0, service)
end

--���÷�������ڴ�
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
