--默认的config.bootstrap，skynet运行的第二个服务(第一是logger)。通常通过这个服务把整个系统启动起来

local skynet = require "skynet"
local harbor = require "skynet.harbor" --节点
local service = require "skynet.service"
require "skynet.manager"	-- import skynet.launch, ...

skynet.start(function()
	local standalone = skynet.getenv "standalone" --是否是主节点

	local launcher = assert(skynet.launch("snlua","launcher")) --service_snlua-launcher.lua
	skynet.name(".launcher", launcher) --绑定启动器

	local harbor_id = tonumber(skynet.getenv "harbor" or 0)
	if harbor_id == 0 then --单节点
		assert(standalone ==  nil)
		standalone = true
		skynet.setenv("standalone", "true")

		local ok, slave = pcall(skynet.newservice, "cdummy")
		if not ok then
			skynet.abort() --中止
		end
		skynet.name(".cslave", slave)  --cdummy代理slave拦截组网消息

	else
		if standalone then --主节点
			if not pcall(skynet.newservice,"cmaster") then --调度
				skynet.abort()
			end
		end

		local ok, slave = pcall(skynet.newservice, "cslave") --组网消息转发
		if not ok then
			skynet.abort()
		end
		skynet.name(".cslave", slave)
	end

	if standalone then
		local datacenter = skynet.newservice "datacenterd" --跨节点数据共享
		skynet.name("DATACENTER", datacenter)
	end
	skynet.newservice "service_mgr" --服务管理

	local enablessl = skynet.getenv "enablessl"
	if enablessl then
		service.new("ltls_holder", function ()
			local c = require "ltls.init.c"
			c.constructor()
		end)
	end

	pcall(skynet.newservice,skynet.getenv "start" or "main")
	skynet.exit()
end)
