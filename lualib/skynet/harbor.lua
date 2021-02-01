--节点库(如果你非要用 master/slave 模式来实现有一定弹性的集群
local skynet = require "skynet"

local harbor = {}

--为服务注册一个全局名字
function harbor.globalname(name, handle)
	handle = handle or skynet.self()
	skynet.send(".cslave", "lua", "REGISTER", name, handle)
end

--可以用来查询全局名字或本地名字对应的服务地址。它是一个阻塞调用。
function harbor.queryname(name)
	return skynet.call(".cslave", "lua", "QUERYNAME", name)
end

--用来监控一个 slave 是否断开。如果 harbor id 对应的 slave 正常，call阻塞。当 slave 断开时，会立刻返回
function harbor.link(id)
	skynet.call(".cslave", "lua", "LINK", id)
end

--如果 harbor id 对应的 slave 没有连接，call阻塞，一直到它连上来才返回。
function harbor.connect(id)
	skynet.call(".cslave", "lua", "CONNECT", id)
end

--监控和 master 的连接是否正常
function harbor.linkmaster()
	skynet.call(".cslave", "lua", "LINKMASTER")
end

return harbor
