local skynet = require "skynet"
local ssm = require "skynet.ssm" --lua-ssm.c

local function ssm_info()
	return ssm.info() --lua-ssm.c linfo
end

local function collect()
	local info = {}
	while true do
--		while ssm.collect(false, info) do
--			skynet.error(string.format("Collect %d strings from %s, sweep %d", info.n, info.key, info.sweep))
--		end
		ssm.collect(true) --lcollect 收集
		skynet.sleep(50)
	end
end

skynet.start(function()
	if ssm.disable then --lua-ssm.c 现在默认为true
		skynet.error "Short String Map (SSM) Disabled"
		skynet.exit()
	end
	skynet.info_func(ssm_info) --注册到debug.lua skynet.call(address,"debug","INFO", ...) 服务内部信息
	skynet.fork(collect)
end)
