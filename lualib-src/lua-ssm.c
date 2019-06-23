#define LUA_LIB

#include <lua.h>
#include <lauxlib.h>
#include <string.h>

#include "lstring.h"

static int
linfo(lua_State *L) {
	struct ssm_info info;
	memset(&info, 0, sizeof(info));
	luaS_infossm(&info);
	lua_createtable(L, 0, 5);
	lua_pushinteger(L, info.total);
	lua_setfield(L, -2, "n");
	lua_pushinteger(L, info.longest);
	lua_setfield(L, -2, "longest");
	lua_pushinteger(L, info.slots);
	lua_setfield(L, -2, "slots");
	lua_pushinteger(L, info.size);
	lua_setfield(L, -2, "size");
	lua_pushinteger(L, info.garbage);
	lua_setfield(L, -2, "garbage");
	lua_pushinteger(L, info.garbage_size);
	lua_setfield(L, -2, "garbage_size");
	lua_pushnumber(L, info.variance);
	lua_setfield(L, -2, "variance");

	/*
	garbage	36
	garbage_size	1745
	longest	5
	n	168950
	size	5670510
	slots	144597
	variance	0.17688798691222
	 */

	return 1;
}

static int
lcollect(lua_State *L) {
	int loop = lua_toboolean(L, 1);
	if (loop) {
		int n = 0;
		struct ssm_collect info;
		while (luaS_collectssm(&info)) {
			n+=info.n;
		}
		lua_pushinteger(L, n);
		return 1;
	} else {
		struct ssm_collect info;
		int again = luaS_collectssm(&info);
		if (again && lua_istable(L, 2)) {
			lua_pushinteger(L, info.n);
			lua_setfield(L, 2, "n");
			lua_pushinteger(L, info.sweep);
			lua_setfield(L, 2, "sweep");
			lua_pushlightuserdata(L, info.key);
			lua_setfield(L, 2, "key");
		}
		lua_pushboolean(L, again);
		return 1;
	}
}

LUAMOD_API int
luaopen_skynet_ssm(lua_State *L) {
	luaL_checkversion(L); //check虚拟机是L

	luaL_Reg l[] = {
		{ "info", linfo },
		{ "collect", lcollect },
		{ NULL, NULL },
	};

	luaL_newlib(L,l); //压栈并注册l内的函数

#ifndef ENABLE_SHORT_STRING_TABLE
	lua_pushboolean(L, 1);
	lua_setfield(L, -2, "disable"); //l["disable"] = true,弹出true
#endif
	return 1;
}

