#ifndef SKYNET_SPINLOCK_H
#define SKYNET_SPINLOCK_H

#define SPIN_INIT(q) spinlock_init(&(q)->lock);
#define SPIN_LOCK(q) spinlock_lock(&(q)->lock);
#define SPIN_UNLOCK(q) spinlock_unlock(&(q)->lock);
#define SPIN_DESTROY(q) spinlock_destroy(&(q)->lock);

#ifndef USE_PTHREAD_LOCK

// 自旋锁（spinlock）
// 概念：自旋锁，一条线程加锁锁住临界区，另一条线程尝试访问该临界区的时候，会发生阻塞，但是不会进入休眠状态，并且不断轮询该锁，直至原来锁住临界区的线程解锁。
// 具体说明：假设一台机器上有两个核心core0和core1，现在有线程A、B、C，此时core0运行线程A，core1运行线程B，此时线程B调用spin lock锁住临界区，当线程A尝试访问该临界区时，因为B已经加锁，此时线程A会阻塞，并且不断轮询该锁，不会交出core0的使用权，当线程B释放锁时，A开始执行临界区逻辑

struct spinlock {
	int lock;
};

static inline void
spinlock_init(struct spinlock *lock) {
	lock->lock = 0;
}

static inline void
spinlock_lock(struct spinlock *lock) { //自旋
	while (__sync_lock_test_and_set(&lock->lock,1)) {}
}

static inline int
spinlock_trylock(struct spinlock *lock) {
	return __sync_lock_test_and_set(&lock->lock,1) == 0;
}

static inline void
spinlock_unlock(struct spinlock *lock) {
	__sync_lock_release(&lock->lock);
}

static inline void
spinlock_destroy(struct spinlock *lock) {
	(void) lock;
}

#else //互斥锁

#include <pthread.h>


// 互斥锁（mutex lock : mutual exclusion lock）
// 概念：互斥锁，一条线程加锁锁住临界区，另一条线程尝试访问改临界区的时候，会发生阻塞，并进入休眠状态。临界区是锁lock和unlock之间的代码片段，一般是多条线程能够共同访问的部分。
// 具体说明：假设一台机器上的cpu有两个核心core0和core1，现在有线程A、B、C，此时core0运行线程A，core1运行线程B，此时线程B使用Mutex锁，锁住一个临界区，当线程A试图访问该临界区时，因为线程B已经将其锁住，因此线程A被挂起，进入休眠状态，此时core0进行上下文切换，将线程A放入休眠队列中，然后core0运行线程C，当线程B完成临界区的流程并执行解锁之后，线程A又会被唤醒，core0重新运行线程A
// 
// we use mutex instead of spinlock for some reason
// you can also replace to pthread_spinlock

struct spinlock {
	pthread_mutex_t lock;
};

static inline void
spinlock_init(struct spinlock *lock) {
	pthread_mutex_init(&lock->lock, NULL);
}

static inline void
spinlock_lock(struct spinlock *lock) {
	pthread_mutex_lock(&lock->lock);
}

static inline int
spinlock_trylock(struct spinlock *lock) {
	return pthread_mutex_trylock(&lock->lock) == 0;
}

static inline void
spinlock_unlock(struct spinlock *lock) {
	pthread_mutex_unlock(&lock->lock);
}

static inline void
spinlock_destroy(struct spinlock *lock) {
	pthread_mutex_destroy(&lock->lock);
}

#endif

#endif
