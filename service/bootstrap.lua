--Ĭ�ϵ�config.bootstrap��skynet���еĵڶ�������(��һ��logger)��ͨ��ͨ��������������ϵͳ��������

local skynet = require "skynet"
local harbor = require "skynet.harbor" --�ڵ�
require "skynet.manager"	-- import skynet.launch, ...

skynet.start(function()
	local standalone = skynet.getenv "standalone" --�Ƿ������ڵ�

	local launcher = assert(skynet.launch("snlua","launcher")) --service_snlua-launcher.lua
	skynet.name(".launcher", launcher) --��������

	local harbor_id = tonumber(skynet.getenv "harbor" or 0)
	if harbor_id == 0 then --���ڵ�
		assert(standalone ==  nil)
		standalone = true
		skynet.setenv("standalone", "true")

		local ok, slave = pcall(skynet.newservice, "cdummy")
		if not ok then
			skynet.abort() --��ֹ
		end
		skynet.name(".cslave", slave)  --cdummy����slave����������Ϣ

	else
		if standalone then --���ڵ�
			if not pcall(skynet.newservice,"cmaster") then --����
				skynet.abort()
			end
		end

		local ok, slave = pcall(skynet.newservice, "cslave") --������Ϣת��
		if not ok then
			skynet.abort()
		end
		skynet.name(".cslave", slave)
	end

	if standalone then
		local datacenter = skynet.newservice "datacenterd" --��ڵ����ݹ���
		skynet.name("DATACENTER", datacenter)
	end
	skynet.newservice "service_mgr" --�������
	pcall(skynet.newservice,skynet.getenv "start" or "main")
	skynet.exit()
end)
