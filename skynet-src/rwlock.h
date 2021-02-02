#ifndef SKYNET_RWLOCK_H
#define SKYNET_RWLOCK_H

#ifndef USE_PTHREAD_LOCK

#include "atomic.h"

//写者是排他性的，一个读写锁同时只能有一个写者或多个读者（与CPU数相关），但不能同时既有读者又有写者。
//读状态时加锁，此时为共享锁，当一个线程加了读锁时，其他线程如果也尝试以读模式进入临界区，那么不会发生阻塞，直接访问临界区
//写状态时加锁，此时为独占锁，当某个线程加了写锁，那么其他线程尝试访问该临界区（不论是读还是写），都会阻塞等待不加锁
//某线程加读取锁时，允许其他线程以读模式进入，此时如果有一个线程尝试以写模式访问临界区时，该线程会被阻塞，而其后尝试以读方式访问该临界区的线程也会被阻塞
//读写锁适合在读远大于写的情形中使用

struct rwlock {
	ATOM_INT write;
	ATOM_INT read;
};

static inline void
rwlock_init(struct rwlock *lock) {
	ATOM_INIT(&lock->write, 0);
	ATOM_INIT(&lock->read, 0);
}

static inline void
rwlock_rlock(struct rwlock *lock) {
	for (;;) {
		while(ATOM_LOAD(&lock->write)) {}
		ATOM_FINC(&lock->read);
		if (ATOM_LOAD(&lock->write)) {
			ATOM_FDEC(&lock->read);
		} else {
			break;
		}
	}
}

static inline void
rwlock_wlock(struct rwlock *lock) {
	int clear = 0;
	while (!ATOM_CAS(&lock->write,clear,1)) {}
	while(ATOM_LOAD(&lock->read)) {}
}

static inline void
rwlock_wunlock(struct rwlock *lock) {
	ATOM_STORE(&lock->write, 0);
}

static inline void
rwlock_runlock(struct rwlock *lock) {
	ATOM_FDEC(&lock->read);
}

#else

#include <pthread.h>

// only for some platform doesn't have __sync_*
// todo: check the result of pthread api

struct rwlock {
	pthread_rwlock_t lock;
};

static inline void
rwlock_init(struct rwlock *lock) {
	pthread_rwlock_init(&lock->lock, NULL);
}

static inline void
rwlock_rlock(struct rwlock *lock) {
	 pthread_rwlock_rdlock(&lock->lock);
}

static inline void
rwlock_wlock(struct rwlock *lock) {
	 pthread_rwlock_wrlock(&lock->lock);
}

static inline void
rwlock_wunlock(struct rwlock *lock) {
	pthread_rwlock_unlock(&lock->lock);
}

static inline void
rwlock_runlock(struct rwlock *lock) {
	pthread_rwlock_unlock(&lock->lock);
}

#endif

#endif
