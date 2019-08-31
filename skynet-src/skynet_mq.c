#include "skynet.h"
#include "skynet_mq.h"
#include "skynet_handle.h"
#include "spinlock.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdbool.h>

#define DEFAULT_QUEUE_SIZE 64
#define MAX_GLOBAL_MQ 0x10000

// 0 means mq is not in global mq.
// 1 means mq is in global mq , or the message is dispatching.

#define MQ_IN_GLOBAL 1
#define MQ_OVERLOAD 1024

/*skynet包含两级消息队列，一个global_mq，他包含一个head和tail指针，分别指向次级消息队列的头部和尾部，
另外还有一个次级消息队列，这个一个单向链表。
消息的派发机制是，工作线程，会从global_mq里pop一个次级消息队列来，然后从次级消息队列中，pop出一个消息，
并传给context的callback函数，在完成驱动以后，再将次级消息队列push回global_mq中
*/
/* 
次级消息队列，实际上是一个数组，并且用两个int型数据，分别指向他的头部和尾部（head和tail），不论是head还是tail，
当他们的值>=数组尺寸时，都会进行回绕（即从下标为0开始，比如值为数组的size时，会被重新赋值为0），在push操作后，
head等于tail意味着队列已满（此时，队列会扩充两倍，并从头到尾重新赋值，此时head指向0，而tail为扩充前，数组的大小），
在pop操作后，head等于tail意味着队列已经空了（后面他会从skynet全局消息队列中，被剔除掉）。
head < tail 时
    |pop->						|push->
| head |      |      |      | tail |      |      | 
(       skynet_message      )(      not use      )
head > tail 时-------------------------------------
                         |pop->	       |push->
|      |      |      | head |      | tail |      | 
(   skynet_message   )(   not use  )(skynet_message)
head == tail 时------------------------------------
push 时 跨容 cap = cap * 2
pop 时 length == 0 ，队列空了，初始化过载保护值
*/

struct message_queue {
	struct spinlock lock; //// 自旋锁，可能存在多个线程，向同一个队列写入的情况，加上自旋锁避免并发带来的风险
	uint32_t handle; // 拥有此消息队列的服务的id
	int cap; // 消息大小
	int head;
	int tail;
	int release; // 是否能释放消息
	int in_global; // 是否在全局消息队列中，0表示不是，1表示是
	int overload; //过载消息数
	int overload_threshold; //超这个值过载保护
	struct skynet_message *queue; //消息数组
	struct message_queue *next; // 下一个次级消息队列的指针
};

struct global_queue {
	struct message_queue *head;
	struct message_queue *tail;
	struct spinlock lock;
};

static struct global_queue *Q = NULL;

void 
skynet_globalmq_push(struct message_queue * queue) {
	struct global_queue *q= Q;

	SPIN_LOCK(q)
	assert(queue->next == NULL);
	if(q->tail) {
		q->tail->next = queue;
		q->tail = queue;
	} else {
		q->head = q->tail = queue;
	}
	SPIN_UNLOCK(q)
}

struct message_queue * 
skynet_globalmq_pop() {
	struct global_queue *q = Q;

	SPIN_LOCK(q)
	struct message_queue *mq = q->head;
	if(mq) {
		q->head = mq->next; //头指向下一个
		if(q->head == NULL) { //没了
			assert(mq == q->tail);
			q->tail = NULL;
		}
		mq->next = NULL;
	}
	SPIN_UNLOCK(q)

	return mq;
}

struct message_queue * 
skynet_mq_create(uint32_t handle) {
	struct message_queue *q = skynet_malloc(sizeof(*q));
	q->handle = handle;
	q->cap = DEFAULT_QUEUE_SIZE;
	q->head = 0;
	q->tail = 0;
	SPIN_INIT(q)
	// When the queue is create (always between service create and service init) ,
	// set in_global flag to avoid push it to global queue .
	// If the service init success, skynet_context_new will call skynet_mq_push to push it to global queue.
	q->in_global = MQ_IN_GLOBAL;
	q->release = 0;
	q->overload = 0; //当前过载消息数
	q->overload_threshold = MQ_OVERLOAD; //消息数超过这么多将保护
	q->queue = skynet_malloc(sizeof(struct skynet_message) * q->cap); //默认64条消息
	q->next = NULL;

	return q;
}

static void 
_release(struct message_queue *q) {
	assert(q->next == NULL);
	SPIN_DESTROY(q)
	skynet_free(q->queue);
	skynet_free(q);
}

uint32_t 
skynet_mq_handle(struct message_queue *q) {
	return q->handle;
}

int
skynet_mq_length(struct message_queue *q) {
	int head, tail,cap;

	SPIN_LOCK(q)
	head = q->head;
	tail = q->tail;
	cap = q->cap;
	SPIN_UNLOCK(q)
	
	if (head <= tail) {
		return tail - head;
	}
	return tail + cap - head;
}

//过载，消息太多了
int
skynet_mq_overload(struct message_queue *q) {
	if (q->overload) {
		int overload = q->overload;
		q->overload = 0;
		return overload;
	} 
	return 0;
}

int
skynet_mq_pop(struct message_queue *q, struct skynet_message *message) {
	int ret = 1;
	SPIN_LOCK(q)

	if (q->head != q->tail) {
		*message = q->queue[q->head++];
		ret = 0;
		int head = q->head;
		int tail = q->tail;
		int cap = q->cap;

		if (head >= cap) {
			q->head = head = 0;
		}
		int length = tail - head;
		if (length < 0) { // head 在后，tail 在前
			length += cap; // (-length) 表示 tail 和 head 间的那段，未使用的消息的数量
		}
		while (length > q->overload_threshold) { //过载保护了，超1024*n了
			q->overload = length;
			q->overload_threshold *= 2;
		}
	} else {
		// reset overload_threshold when queue is empty
		q->overload_threshold = MQ_OVERLOAD;
	}

	if (ret) {
		q->in_global = 0;
	}
	
	SPIN_UNLOCK(q)

	return ret;
}

static void
expand_queue(struct message_queue *q) {
	struct skynet_message *new_queue = skynet_malloc(sizeof(struct skynet_message) * q->cap * 2);
	int i;
	for (i=0;i<q->cap;i++) {
		new_queue[i] = q->queue[(q->head + i) % q->cap];
	}
	q->head = 0;
	q->tail = q->cap;
	q->cap *= 2;
	
	skynet_free(q->queue);
	q->queue = new_queue;
}

void 
skynet_mq_push(struct message_queue *q, struct skynet_message *message) {
	assert(message);
	SPIN_LOCK(q) //自旋，循环尝试插入

	q->queue[q->tail] = *message;
	if (++ q->tail >= q->cap) {
		q->tail = 0; //回绕
	}

	if (q->head == q->tail) {
		expand_queue(q); //扩容
	}

	if (q->in_global == 0) {
		q->in_global = MQ_IN_GLOBAL;
		skynet_globalmq_push(q);
	}
	
	SPIN_UNLOCK(q)
}

void 
skynet_mq_init() {
	struct global_queue *q = skynet_malloc(sizeof(*q));
	memset(q,0,sizeof(*q));
	SPIN_INIT(q);
	Q=q;
}

void 
skynet_mq_mark_release(struct message_queue *q) {
	SPIN_LOCK(q)
	assert(q->release == 0);
	q->release = 1;
	if (q->in_global != MQ_IN_GLOBAL) {
		skynet_globalmq_push(q);
	}
	SPIN_UNLOCK(q)
}

static void
_drop_queue(struct message_queue *q, message_drop drop_func, void *ud) {
	struct skynet_message msg;
	while(!skynet_mq_pop(q, &msg)) {
		drop_func(&msg, ud);
	}
	_release(q);
}

//释放q这条队列
void 
skynet_mq_release(struct message_queue *q, message_drop drop_func, void *ud) {
	SPIN_LOCK(q)
	
	if (q->release) { //已经skynet_mq_mark_release过，表示对应上下文已经删除
		SPIN_UNLOCK(q)
		_drop_queue(q, drop_func, ud); //删除消息队列
	} else {
		skynet_globalmq_push(q); //传入全局消息队列去执行，以置空消息队列，上下文引用为0即可skynet_mq_mark_release
		SPIN_UNLOCK(q)
	}
}
