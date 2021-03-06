#define LUA_LIB

#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>

#include <time.h>

#if defined(__APPLE__)
#include <mach/task.h>
#include <mach/mach.h>
#endif

#define NANOSEC 1000000000
#define MICROSEC 1000000

// #define DEBUG_LOG

static double
get_time() {
#if  !defined(__APPLE__)
	struct timespec ti;
	clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ti); //本线程到当前代码系统CPU花费的时间

	int sec = ti.tv_sec & 0xffff;
	int nsec = ti.tv_nsec;

	return (double)sec + (double)nsec / NANOSEC;	
#else
	struct task_thread_times_info aTaskInfo;
	mach_msg_type_number_t aTaskInfoCount = TASK_THREAD_TIMES_INFO_COUNT;
	if (KERN_SUCCESS != task_info(mach_task_self(), TASK_THREAD_TIMES_INFO, (task_info_t )&aTaskInfo, &aTaskInfoCount)) {
		return 0;
	}

	int sec = aTaskInfo.user_time.seconds & 0xffff;
	int msec = aTaskInfo.user_time.microseconds;

	return (double)sec + (double)msec / MICROSEC;
#endif
}

static inline double 
diff_time(double start) {
	double now = get_time();
	if (now < start) {
		return now + 0x10000 - start;
	} else {
		return now - start;
	}
}

// 开始记录实际消息处理消耗时间，不包括挂起(调用 lstart 时协程已经被唤醒)
static int
lstart(lua_State *L) {
	if (lua_gettop(L) != 0) {
		lua_settop(L,1);
		luaL_checktype(L, 1, LUA_TTHREAD);
	} else {
		lua_pushthread(L);
	}
	lua_pushvalue(L, 1);	// push coroutine
	lua_rawget(L, lua_upvalueindex(2));
	if (!lua_isnil(L, -1)) {
		return luaL_error(L, "Thread %p start profile more than once", lua_topointer(L, 1));
	}
	lua_pushvalue(L, 1);	// push coroutine
	lua_pushnumber(L, 0);
	lua_rawset(L, lua_upvalueindex(2));

	lua_pushvalue(L, 1);	// push coroutine
	double ti = get_time(); // 记录开始时刻
#ifdef DEBUG_LOG
	fprintf(stderr, "PROFILE [%p] start\n", L);
#endif
	lua_pushnumber(L, ti);
	lua_rawset(L, lua_upvalueindex(1));

	return 0;
}

// 结束，并返回不包括挂起的总消耗时间
static int
lstop(lua_State *L) {
	if (lua_gettop(L) != 0) {
		lua_settop(L,1);
		luaL_checktype(L, 1, LUA_TTHREAD);
	} else {
		lua_pushthread(L);
	}
	lua_pushvalue(L, 1);	// push coroutine
	lua_rawget(L, lua_upvalueindex(1));
	if (lua_type(L, -1) != LUA_TNUMBER) {
		return luaL_error(L, "Call profile.start() before profile.stop()");
	} 
	double ti = diff_time(lua_tonumber(L, -1));
	lua_pushvalue(L, 1);	// push coroutine
	lua_rawget(L, lua_upvalueindex(2));
	double total_time = lua_tonumber(L, -1);

	lua_pushvalue(L, 1);	// push coroutine
	lua_pushnil(L);
	lua_rawset(L, lua_upvalueindex(1));

	lua_pushvalue(L, 1);	// push coroutine
	lua_pushnil(L);
	lua_rawset(L, lua_upvalueindex(2));

	total_time += ti;
	lua_pushnumber(L, total_time);
#ifdef DEBUG_LOG
	fprintf(stderr, "PROFILE [%p] stop (%lf/%lf)\n", lua_tothread(L,1), ti, total_time);
#endif

	return 1;
}

//唤醒，记录开始的时刻
static int
timing_resume(lua_State *L) {
	lua_pushvalue(L, -1); //co副本2压栈
	lua_rawget(L, lua_upvalueindex(2)); // check total time  (把t[k]的值压栈，t闭包第二个upvalue，k线程副本 push upvalue totaltime[coroutine]
	if (lua_isnil(L, -1)) {		// check total time, 即checkprofile开关
		lua_pop(L,2);	// pop from coroutine
	} else {
		lua_pop(L,1); // total time出栈
		double ti = get_time();
#ifdef DEBUG_LOG
		fprintf(stderr, "PROFILE [%p] resume %lf\n", lua_tothread(L, -1), ti);
#endif
		lua_pushnumber(L, ti);
		lua_rawset(L, lua_upvalueindex(1));	// set start time 压栈，供timing_yield difftime
	}

	lua_CFunction co_resume = lua_tocfunction(L, lua_upvalueindex(3)); // upvalue 3 c fun co_resume

	return co_resume(L);
}

static int
lresume(lua_State *L) {
	lua_pushvalue(L,1); //co副本压栈
	
	return timing_resume(L);
}

static int
lresume_co(lua_State *L) {
	luaL_checktype(L, 2, LUA_TTHREAD);
	lua_rotate(L, 2, -1);	// 'from' coroutine rotate to the top(index -1)

	return timing_resume(L);
}

//被挂起，累加清醒时用时(当前时刻减开始时刻)
static int
timing_yield(lua_State *L) {
#ifdef DEBUG_LOG
	lua_State *from = lua_tothread(L, -1);
#endif
	lua_pushvalue(L, -1); // 复制线程压栈
	lua_rawget(L, lua_upvalueindex(2));	// check total time  (把t[k]的值压栈，t闭包第二个upvalue，k线程副本 push upvalue totaltime[coroutine]
	if (lua_isnil(L, -1)) { // total time == nil, 即checkprofile开关
		lua_pop(L,2); // 弹出线程2个副本
	} else {
		double ti = lua_tonumber(L, -1); //total time
		lua_pop(L,1); // 弹出线程

		lua_pushvalue(L, -1);	// push coroutine  (线程副本2
		lua_rawget(L, lua_upvalueindex(1)); // starttime  (push upvalue starttime[coroutine]
		double starttime = lua_tonumber(L, -1);
		lua_pop(L,1); // 弹出线程副本1

		double diff = diff_time(starttime);
		ti += diff;
#ifdef DEBUG_LOG
		fprintf(stderr, "PROFILE [%p] yield (%lf/%lf)\n", from, diff, ti);
#endif

		lua_pushvalue(L, -1);	// push coroutine
		lua_pushnumber(L, ti);
		lua_rawset(L, lua_upvalueindex(2)); // upvalue totaltime[coroutine]=ti
		lua_pop(L, 1);	// pop coroutine
	}

	lua_CFunction co_yield = lua_tocfunction(L, lua_upvalueindex(3)); // upvalue c fun co_yield

	return co_yield(L);
}

static int
lyield(lua_State *L) {
	lua_pushthread(L); // 把L表示的线程压栈

	return timing_yield(L);
}

static int
lyield_co(lua_State *L) {
	luaL_checktype(L, 1, LUA_TTHREAD);
	lua_rotate(L, 1, -1);
	
	return timing_yield(L);
}

LUAMOD_API int
luaopen_skynet_profile(lua_State *L) {
	luaL_checkversion(L);
	luaL_Reg l[] = {
		{ "start", lstart },
		{ "stop", lstop },
		{ "resume", lresume },
		{ "yield", lyield },
		{ "resume_co", lresume_co },
		{ "yield_co", lyield_co },
		{ NULL, NULL },
	};
	luaL_newlibtable(L,l);
	lua_newtable(L);	// table thread->start time
	lua_newtable(L);	// table thread->total time

	lua_newtable(L);	// weak table
	lua_pushliteral(L, "kv"); // push string "kv"
	lua_setfield(L, -2, "__mode"); // weaktable[__mode] = "kv""

	lua_pushvalue(L, -1); // push "kv"
	lua_setmetatable(L, -3); // pop weaktable setmetatable(totaltime, weaktable)
	lua_setmetatable(L, -3); // pop totaltime setmetatable(starttime, totaltime)

	lua_pushnil(L);	// cfunction (coroutine.resume or coroutine.yield)
	luaL_setfuncs(L,l,3); // reg functions in l

	int libtable = lua_gettop(L);

	lua_getglobal(L, "coroutine");
	lua_getfield(L, -1, "resume"); // push coroutine.resume

	lua_CFunction co_resume = lua_tocfunction(L, -1);
	if (co_resume == NULL)
		return luaL_error(L, "Can't get coroutine.resume");
	lua_pop(L,1); // pop coroutine.resume

	lua_getfield(L, libtable, "resume"); // l.resume压栈
	lua_pushcfunction(L, co_resume); // co_resume压栈
	lua_setupvalue(L, -2, 3); // l.resume上引值3设为co_resume，并出栈
	lua_pop(L,1); // l.resume出栈

	//同上
	lua_getfield(L, libtable, "resume_co");
	lua_pushcfunction(L, co_resume);
	lua_setupvalue(L, -2, 3);
	lua_pop(L,1);

	lua_getfield(L, -1, "yield");

	lua_CFunction co_yield = lua_tocfunction(L, -1);
	if (co_yield == NULL)
		return luaL_error(L, "Can't get coroutine.yield");
	lua_pop(L,1);

	lua_getfield(L, libtable, "yield");
	lua_pushcfunction(L, co_yield);
	lua_setupvalue(L, -2, 3);
	lua_pop(L,1);

	lua_getfield(L, libtable, "yield_co");
	lua_pushcfunction(L, co_yield);
	lua_setupvalue(L, -2, 3);
	lua_pop(L,1);

	lua_settop(L, libtable);

	return 1;
}
