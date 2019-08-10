--用来在整个网络做跨节点的数据共享
--你还可以通过它来交换 Multicast 的频道号等各种信息。
--datacenter 其实是通过在 master 节点上部署了一个专门的数据中心服务来共享这些数据的。瓶颈
--cluster模式下不能直接使用
local skynet = require "skynet"

local command = {}
local database = {}
local wait_queue = {}
local mode = {}

local function query(db, key, ...)
	if db == nil then
		return nil
	end
	if key == nil then
		return db
	else
		return query(db[key], ...)
	end
end

function command.QUERY(key, ...)
	local d = database[key]
	if d then
		return query(d, ...)
	end
end

local function update(db, key, value, ...)
	if select("#",...) == 0 then
		local ret = db[key]
		db[key] = value
		return ret, value
	else
		if db[key] == nil then
			db[key] = {}
		end
		return update(db[key], value, ...)
	end
end

local function wakeup(db, key1, ...)
	if key1 == nil then
		return
	end
	local q = db[key1]
	if q == nil then
		return
	end
	if q[mode] == "queue" then
		db[key1] = nil
		if select("#", ...) ~= 1 then
			-- throw error because can't wake up a branch
			for _,response in ipairs(q) do
				response(false)
			end
		else
			return q
		end
	else
		-- it's branch
		return wakeup(q , ...)
	end
end

function command.UPDATE(...)
	local ret, value = update(database, ...) --写
	if ret or value == nil then
		return ret
	end
	local q = wakeup(wait_queue, ...) --唤醒等数据的
	if q then
		for _, response in ipairs(q) do
			response(true,value)
		end
	end
end

local function waitfor(db, key1, key2, ...)
	if key2 == nil then
		-- push queue
		local q = db[key1]
		if q == nil then --叶
			q = { [mode] = "queue" }
			db[key1] = q
		else
			assert(q[mode] == "queue")
		end
		table.insert(q, skynet.response()) --用于延迟回应
	else
		local q = db[key1]
		if q == nil then --支
			q = { [mode] = "branch" }
			db[key1] = q
		else
			assert(q[mode] == "branch")
		end
		return waitfor(q, key2, ...)
	end
end

skynet.start(function()
	skynet.dispatch("lua", function (_, _, cmd, ...)
		if cmd == "WAIT" then --读or等
			local ret = command.QUERY(...)
			if ret then
				skynet.ret(skynet.pack(ret))
			else --直到有人更新这个分支才返回
				waitfor(wait_queue, ...)
			end
		else
			local f = assert(command[cmd])
			skynet.ret(skynet.pack(f(...)))
		end
	end)
end)
