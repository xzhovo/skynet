#include "skynet.h"

#include "skynet_handle.h"
#include "skynet_server.h"
#include "rwlock.h"

#include <stdlib.h>
#include <assert.h>
#include <string.h>

#define DEFAULT_SLOT_SIZE 4
#define MAX_SLOT_SIZE 0x40000000

struct handle_name {
	char * name;
	uint32_t handle;
};

// skynet_context管理器结构
struct handle_storage {
    struct rwlock lock;            // 读写锁
    
    uint32_t harbor;               // harbor id
    uint32_t handle_index;         // 创建下一个服务时，该服务的slot idx，一般会先判断该slot是否被占用，初始1
    int slot_size;                 // slot的大小，一定是2^n，初始值是4
    struct skynet_context ** slot; // skynet_context list
        
    int name_cap;                  // 别名列表大小，大小为2^n，初始2
    int name_count;                // 别名数量，初始0
    struct handle_name *name;      // 别名列表
};

static struct handle_storage *H = NULL; // skynet_context管理器

uint32_t
skynet_handle_register(struct skynet_context *ctx) {
	struct handle_storage *s = H;

	rwlock_wlock(&s->lock); // 锁住写
	
	for (;;) {
		int i;
		uint32_t handle = s->handle_index;
		for (i=0;i<s->slot_size;i++,handle++) {
			if (handle > HANDLE_MASK) { // #define HANDLE_MASK 0xffffff 轮回
				// 0 is reserved
				handle = 1;
			}
			int hash = handle & (s->slot_size-1); // 控制slot list成倍递增，初始4，即可使用0-3
			if (s->slot[hash] == NULL) {
				s->slot[hash] = ctx;
				s->handle_index = handle + 1;

				rwlock_wunlock(&s->lock);

				handle |= s->harbor; // 加上<16进制config.harbor>00000000，这里还是二进制
				return handle;
			}
		}
		// 位置不足，slot list成倍递增，转存替换
		assert((s->slot_size*2 - 1) <= HANDLE_MASK);
		struct skynet_context ** new_slot = skynet_malloc(s->slot_size * 2 * sizeof(struct skynet_context *));
		memset(new_slot, 0, s->slot_size * 2 * sizeof(struct skynet_context *));
		for (i=0;i<s->slot_size;i++) {
			int hash = skynet_context_handle(s->slot[i]) & (s->slot_size * 2 - 1);
			assert(new_slot[hash] == NULL);
			new_slot[hash] = s->slot[i];
		}
		skynet_free(s->slot);
		s->slot = new_slot;
		s->slot_size *= 2;
	}
}

//注销
int
skynet_handle_retire(uint32_t handle) {
	int ret = 0;
	struct handle_storage *s = H;

	rwlock_wlock(&s->lock);

	uint32_t hash = handle & (s->slot_size-1);
	struct skynet_context * ctx = s->slot[hash];

	if (ctx != NULL && skynet_context_handle(ctx) == handle) {
		s->slot[hash] = NULL; //置空
		ret = 1;
		int i;
		int j=0, n=s->name_count; //删别名
		for (i=0; i<n; ++i) {
			if (s->name[i].handle == handle) {
				skynet_free(s->name[i].name);
				continue;
			} else if (i!=j) {
				s->name[j] = s->name[i];
			}
			++j;
		}
		s->name_count = j;
	} else {
		ctx = NULL;
	}
	//不用管index，它会自己遍历判断NULL

	rwlock_wunlock(&s->lock);

	if (ctx) {
		// release ctx may call skynet_handle_* , so wunlock first.
		skynet_context_release(ctx);
	}

	return ret;
}

void 
skynet_handle_retireall() {
	struct handle_storage *s = H;
	for (;;) {
		int n=0;
		int i;
		for (i=0;i<s->slot_size;i++) {
			rwlock_rlock(&s->lock);
			struct skynet_context * ctx = s->slot[i];
			uint32_t handle = 0;
			if (ctx)
				handle = skynet_context_handle(ctx);
			rwlock_runlock(&s->lock);
			if (handle != 0) {
				if (skynet_handle_retire(handle)) {
					++n;
				}
			}
		}
		if (n==0)
			return;
	}
}

struct skynet_context * 
skynet_handle_grab(uint32_t handle) {
	struct handle_storage *s = H;
	struct skynet_context * result = NULL;

	rwlock_rlock(&s->lock);

	uint32_t hash = handle & (s->slot_size-1);
	struct skynet_context * ctx = s->slot[hash];
	if (ctx && skynet_context_handle(ctx) == handle) {
		result = ctx;
		skynet_context_grab(result);
	}

	rwlock_runlock(&s->lock);

	return result;
}

uint32_t 
skynet_handle_findname(const char * name) {
	struct handle_storage *s = H;

	rwlock_rlock(&s->lock);

	uint32_t handle = 0;

	int begin = 0;
	int end = s->name_count - 1;
	while (begin<=end) {
		int mid = (begin+end)/2;
		struct handle_name *n = &s->name[mid];
		int c = strcmp(n->name, name);
		if (c==0) {
			handle = n->handle;
			break;
		}
		if (c<0) {
			begin = mid + 1;
		} else {
			end = mid - 1;
		}
	}

	rwlock_runlock(&s->lock);

	return handle;
}

static void
_insert_name_before(struct handle_storage *s, char *name, uint32_t handle, int before) {
	if (s->name_count >= s->name_cap) {
		s->name_cap *= 2;
		assert(s->name_cap <= MAX_SLOT_SIZE);
		struct handle_name * n = skynet_malloc(s->name_cap * sizeof(struct handle_name));
		int i;
		for (i=0;i<before;i++) {
			n[i] = s->name[i];
		}
		for (i=before;i<s->name_count;i++) {
			n[i+1] = s->name[i];
		}
		skynet_free(s->name);
		s->name = n;
	} else {
		int i;
		for (i=s->name_count;i>before;i--) {
			s->name[i] = s->name[i-1];
		}
	}
	s->name[before].name = name;
	s->name[before].handle = handle;
	s->name_count ++;
}

static const char *
_insert_name(struct handle_storage *s, const char * name, uint32_t handle) {
	int begin = 0;
	int end = s->name_count - 1;
	while (begin<=end) {
		int mid = (begin+end)/2;
		struct handle_name *n = &s->name[mid];
		int c = strcmp(n->name, name);
		if (c==0) {
			return NULL;
		}
		if (c<0) {
			begin = mid + 1;
		} else {
			end = mid - 1;
		}
	}
	char * result = skynet_strdup(name);

	_insert_name_before(s, result, handle, begin);

	return result;
}

const char * 
skynet_handle_namehandle(uint32_t handle, const char *name) {
	rwlock_wlock(&H->lock);

	const char * ret = _insert_name(H, name, handle);

	rwlock_wunlock(&H->lock);

	return ret;
}

//harbor config中的harbor代表节点数
void 
skynet_handle_init(int harbor) {
	assert(H==NULL);
	struct handle_storage * s = skynet_malloc(sizeof(*H));
	s->slot_size = DEFAULT_SLOT_SIZE;
	s->slot = skynet_malloc(s->slot_size * sizeof(struct skynet_context *));
	memset(s->slot, 0, s->slot_size * sizeof(struct skynet_context *));

	rwlock_init(&s->lock);
	// reserve 0 for system
	s->harbor = (uint32_t) (harbor & 0xff) << HANDLE_REMOTE_SHIFT; // #define HANDLE_REMOTE_SHIFT 24 
	//<config.harbor>000000000000000000000000 之后会转16进制 <16进制config.harbor>00000000
	s->handle_index = 1;
	s->name_cap = 2;
	s->name_count = 0;
	s->name = skynet_malloc(s->name_cap * sizeof(struct handle_name));

	H = s;

	// Don't need to free H
}

