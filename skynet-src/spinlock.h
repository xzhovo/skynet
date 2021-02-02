#ifndef SKYNET_SPINLOCK_H
#define SKYNET_SPINLOCK_H

#define SPIN_INIT(q) spinlock_init(&(q)->lock);
#define SPIN_LOCK(q) spinlock_lock(&(q)->lock);
#define SPIN_UNLOCK(q) spinlock_unlock(&(q)->lock);
#define SPIN_DESTROY(q) spinlock_destroy(&(q)->lock);

#ifndef USE_PTHREAD_LOCK

// ��������spinlock��
// �����������һ���̼߳�����ס�ٽ�������һ���̳߳��Է��ʸ��ٽ�����ʱ�򣬻ᷢ�����������ǲ����������״̬�����Ҳ�����ѯ������ֱ��ԭ����ס�ٽ������߳̽�����
// ����˵��������һ̨����������������core0��core1���������߳�A��B��C����ʱcore0�����߳�A��core1�����߳�B����ʱ�߳�B����spin lock��ס�ٽ��������߳�A���Է��ʸ��ٽ���ʱ����ΪB�Ѿ���������ʱ�߳�A�����������Ҳ�����ѯ���������ύ��core0��ʹ��Ȩ�����߳�B�ͷ���ʱ��A��ʼִ���ٽ����߼�

#ifdef __STDC_NO_ATOMICS__

#define atomic_flag_ int
#define ATOMIC_FLAG_INIT_ 0
#define atomic_flag_test_and_set_(ptr) __sync_lock_test_and_set(ptr, 1)
#define atomic_flag_clear_(ptr) __sync_lock_release(ptr)

#else

#include <stdatomic.h>
#define atomic_flag_ atomic_flag
#define ATOMIC_FLAG_INIT_ ATOMIC_FLAG_INIT
#define atomic_flag_test_and_set_ atomic_flag_test_and_set
#define atomic_flag_clear_ atomic_flag_clear

#endif

struct spinlock {
	atomic_flag_ lock;
};

static inline void
spinlock_init(struct spinlock *lock) {
	atomic_flag_ v = ATOMIC_FLAG_INIT_;
	lock->lock = v;
}

static inline void
spinlock_lock(struct spinlock *lock) { //����
	while (atomic_flag_test_and_set_(&lock->lock)) {}
}

static inline int
spinlock_trylock(struct spinlock *lock) {
	return atomic_flag_test_and_set_(&lock->lock) == 0;
}

static inline void
spinlock_unlock(struct spinlock *lock) {
	atomic_flag_clear_(&lock->lock);
}

static inline void
spinlock_destroy(struct spinlock *lock) {
	(void) lock;
}

#else //������

#include <pthread.h>


// ��������mutex lock : mutual exclusion lock��
// �����������һ���̼߳�����ס�ٽ�������һ���̳߳��Է��ʸ��ٽ�����ʱ�򣬻ᷢ������������������״̬���ٽ�������lock��unlock֮��Ĵ���Ƭ�Σ�һ���Ƕ����߳��ܹ���ͬ���ʵĲ��֡�
// ����˵��������һ̨�����ϵ�cpu����������core0��core1���������߳�A��B��C����ʱcore0�����߳�A��core1�����߳�B����ʱ�߳�Bʹ��Mutex������סһ���ٽ��������߳�A��ͼ���ʸ��ٽ���ʱ����Ϊ�߳�B�Ѿ�������ס������߳�A�����𣬽�������״̬����ʱcore0�����������л������߳�A�������߶����У�Ȼ��core0�����߳�C�����߳�B����ٽ��������̲�ִ�н���֮���߳�A�ֻᱻ���ѣ�core0���������߳�A
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
