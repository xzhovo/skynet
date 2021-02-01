#include "skynet.h"
#include "skynet_server.h"
#include "skynet_imp.h"
#include "skynet_mq.h"
#include "skynet_handle.h"
#include "skynet_module.h"
#include "skynet_timer.h"
#include "skynet_monitor.h"
#include "skynet_socket.h"
#include "skynet_daemon.h"
#include "skynet_harbor.h"

#include <pthread.h>
#include <unistd.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

/*
有4种线程：
monitor 监视线程：5秒检查一次是否有消息卡住

timer 定时器线程：每2.5毫秒工作一次(由于 skynet 最小时间单位为10毫秒，不过这决定了无法用1毫秒，一般更小粒度只能设为5毫秒)，
并试图唤醒一个睡眠的工作线程；
处理 skynet.timeout, skynet.sleep 等函数时间轮添加节点，在32位数据中
32位是分第1~8,9~14,15~20,21~26,27~32位的，5个级别，分别对应 t[3][0],t[0],t[1],t[2],t[3] ,相差0~2.55s以内存 near ,大于 2.55s 存单位刻度向量 t

socket 网络线程：epoll(linux) 处理网络消息，不停工作
主要是外部连接的流量接收和组网消息的收发，其中外部流量的发送一般在 worker 工作线程中直接发送了，不管 socket 线程的事，
除非多服务 socket.write 可能并发，锁住走 epoll 管道排队发送；epoll 用默认模式，注册事件，不停通知，wait 后处理所有触发的事件
epoll 是由一个红黑树事件节点表和一个双向链表事件触发通知表组成

worker 工作线程：处理服务队列消息，不停工作，直到全局队列没有服务消息队列了(没消息了)，睡眠，等被 timer 线程唤醒
由初始分配的线程的权重决定处理多少消息，< 4 时由于数量太少，为了保证没有服务被饿死，
每次只处理一个服务消息队列中的一条消息，> 4 < 8 时处理全部消息，有线程保证不饿死了，我们就是来榨干 CPU 的，
> 8 时处理的消息数递减，保证流畅？
建议核少时 worker 线程数量 == 核数，核多时 核数*2-3 ?
 */

struct monitor {
	int count;
	struct skynet_monitor ** m;
	pthread_cond_t cond;
	pthread_mutex_t mutex;
	int sleep;
	int quit;
};

struct worker_parm {
	struct monitor *m;
	int id;
	int weight;
};

static volatile int SIG = 0;

static void
handle_hup(int signal) {
	if (signal == SIGHUP) { //挂起信号 kill -HUP 处理log文件切割
		SIG = 1;
	}
}

#define CHECK_ABORT if (skynet_context_total()==0) break;

static void
create_thread(pthread_t *thread, void *(*start_routine) (void *), void *arg) {
	if (pthread_create(thread,NULL, start_routine, arg)) {
		fprintf(stderr, "Create thread failed");
		exit(1);
	}
}

static void
wakeup(struct monitor *m, int busy) {
	if (m->sleep >= m->count - busy) { // 睡眠的工作线程数大于等于 1 吗，是即唤醒一个工作线程(仅一个)
		// signal sleep worker, "spurious wakeup" is harmless
		pthread_cond_signal(&m->cond); //发送一个信号给另外一个正在处于阻塞等待状态的线程,使其脱离阻塞状态,继续执行( thread_worker pthread_cond_wait 处)
	}
}

static void *
thread_socket(void *p) {
	struct monitor * m = p;
	skynet_initthread(THREAD_SOCKET);
	for (;;) { //不停工作
		int r = skynet_socket_poll();
		if (r==0) //结束
			break;
		if (r<0) { //报错或更多没处理
			CHECK_ABORT
			continue;
		}
		wakeup(m,0); // check 是不是全睡着了，是则唤醒一个
	}
	return NULL;
}

static void
free_monitor(struct monitor *m) {
	int i;
	int n = m->count;
	for (i=0;i<n;i++) {
		skynet_monitor_delete(m->m[i]);
	}
	pthread_mutex_destroy(&m->mutex);
	pthread_cond_destroy(&m->cond);
	skynet_free(m->m);
	skynet_free(m);
}

static void *
thread_monitor(void *p) {
	struct monitor * m = p;
	int i;
	int n = m->count;
	skynet_initthread(THREAD_MONITOR);
	for (;;) {
		CHECK_ABORT
		for (i=0;i<n;i++) { //遍历所有监视器(每隔5秒一次)
			skynet_monitor_check(m->m[i]);
		}
		for (i=0;i<5;i++) { //暂停5秒，每秒 check 结束
			CHECK_ABORT
			sleep(1);
		}
	}

	return NULL;
}

// 挂起一下 log file 句柄，重定向打开，以供外部处理 log file
static void
signal_hup() {
	// make log file reopen

	struct skynet_message smsg;
	smsg.source = 0;
	smsg.session = 0;
	smsg.data = NULL;
	smsg.sz = (size_t)PTYPE_SYSTEM << MESSAGE_TYPE_SHIFT;
	uint32_t logger = skynet_handle_findname("logger");
	if (logger) {
		skynet_context_push(logger, &smsg);
	}
}

static void *
thread_timer(void *p) {
	struct monitor * m = p;
	skynet_initthread(THREAD_TIMER);
	for (;;) {
		skynet_updatetime();
		skynet_socket_updatetime();
		CHECK_ABORT
		wakeup(m,m->count-1);
		usleep(2500); //0.0025秒
		if (SIG) { //处理挂起信号
			signal_hup();
			SIG = 0;
		}
	}
	// ABORT
	// wakeup socket thread
	skynet_socket_exit();
	// wakeup all worker thread
	pthread_mutex_lock(&m->mutex);
	m->quit = 1;
	pthread_cond_broadcast(&m->cond);
	pthread_mutex_unlock(&m->mutex);
	return NULL;
}

static void *
thread_worker(void *p) {
	struct worker_parm *wp = p;
	int id = wp->id;
	int weight = wp->weight;
	struct monitor *m = wp->m;
	struct skynet_monitor *sm = m->m[id];
	skynet_initthread(THREAD_WORKER);
	struct message_queue * q = NULL;
	while (!m->quit) {
		q = skynet_context_message_dispatch(sm, q, weight);
		if (q == NULL) {
			if (pthread_mutex_lock(&m->mutex) == 0) {
				++ m->sleep;
				// "spurious wakeup" is harmless,
				// because skynet_context_message_dispatch() can be call at any time.
				if (!m->quit)
					pthread_cond_wait(&m->cond, &m->mutex);
				-- m->sleep;
				if (pthread_mutex_unlock(&m->mutex)) {
					fprintf(stderr, "unlock mutex error");
					exit(1);
				}
			}
		}
	}
	return NULL;
}

static void
start(int thread) {
	pthread_t pid[thread+3];

	struct monitor *m = skynet_malloc(sizeof(*m));
	memset(m, 0, sizeof(*m));
	m->count = thread;
	m->sleep = 0;

	m->m = skynet_malloc(thread * sizeof(struct skynet_monitor *));
	int i;
	for (i=0;i<thread;i++) { //几线程对应几监视器
		m->m[i] = skynet_monitor_new();
	}
	if (pthread_mutex_init(&m->mutex, NULL)) {
		fprintf(stderr, "Init mutex error");
		exit(1);
	}
	if (pthread_cond_init(&m->cond, NULL)) {
		fprintf(stderr, "Init cond error");
		exit(1);
	}

	create_thread(&pid[0], thread_monitor, m);
	create_thread(&pid[1], thread_timer, m);
	create_thread(&pid[2], thread_socket, m);

	//权重值决定一条线程一次消费多少条次级消息队列里的消息，
	//当权重值< 0，worker线程一次消费一条消息（从次级消息队列中pop一个消息）；第1-4条线程
	//当权重==0的时候，worker线程一次消费完次级消息队列里所有的消息；第5-8条线程
	//当权重>0时，假设次级消息队列的长度为mq_length，将mq_length转成二进制数值以后，向右移动weight（权重值）位次级消息队列的消息数。
	//第9-16条worker线程一次消费的消息数目大约是整个次级消息队列长度的一半，第17-24条线程一次消费的消息数大约是整个次级消息队列长度的四分之一，而第25-32条worker线程，则大约是次级消息总长度的八分之一

	/*
	这样做的目的，大概是希望避免过多的worker线程为了等待spinlock解锁，而陷入阻塞状态（因为一些线程，一次消费多条甚至全部次级消息队列的消息，
	因此在消费期间，不会对global_mq进行入队和出队操作，入队和出队操作时加自旋锁的，因此就不会尝试去访问spinlock锁住的临界区，该线程就在相当一段时间内不会陷入阻塞），
	进而提升服务器的并发处理能力。这里还有一个细节值得注意，就是前四条线程，每次只是pop一个次级消息队列的消息出来，这样做也在一定程度上保证了没有服务会被饿死。
	 */
	static int weight[] = { 
		-1, -1, -1, -1, 0, 0, 0, 0,
		1, 1, 1, 1, 1, 1, 1, 1, 
		2, 2, 2, 2, 2, 2, 2, 2, 
		3, 3, 3, 3, 3, 3, 3, 3, };
	struct worker_parm wp[thread];
	for (i=0;i<thread;i++) {
		wp[i].m = m;
		wp[i].id = i;
		if (i < sizeof(weight)/sizeof(weight[0])) {
			wp[i].weight= weight[i];
		} else {
			wp[i].weight = 0;
		}
		create_thread(&pid[i+3], thread_worker, &wp[i]);
	}

	for (i=0;i<thread+3;i++) {
		pthread_join(pid[i], NULL); 
	}

	free_monitor(m);
}

static void
bootstrap(struct skynet_context * logger, const char * cmdline) {
	int sz = strlen(cmdline);
	char name[sz+1];
	char args[sz+1];
	sscanf(cmdline, "%s %s", name, args);
	struct skynet_context *ctx = skynet_context_new(name, args);
	if (ctx == NULL) {
		skynet_error(NULL, "Bootstrap error : %s\n", cmdline);
		skynet_context_dispatchall(logger);
		exit(1);
	}
}

void 
skynet_start(struct skynet_config * config) {
	// register SIGHUP for log file reopen
	struct sigaction sa;
	sa.sa_handler = &handle_hup;
	sa.sa_flags = SA_RESTART;
	sigfillset(&sa.sa_mask);
	sigaction(SIGHUP, &sa, NULL);

	if (config->daemon) {
		if (daemon_init(config->daemon)) {
			exit(1);
		}
	}
	skynet_harbor_init(config->harbor);
	skynet_handle_init(config->harbor);
	skynet_mq_init();
	skynet_module_init(config->module_path);
	skynet_timer_init();
	skynet_socket_init();
	skynet_profile_enable(config->profile);

	struct skynet_context *ctx = skynet_context_new(config->logservice, config->logger);
	if (ctx == NULL) {
		fprintf(stderr, "Can't launch %s service\n", config->logservice);
		exit(1);
	}

	skynet_handle_namehandle(skynet_context_handle(ctx), "logger");

	bootstrap(ctx, config->bootstrap);

	start(config->thread);

	// harbor_exit may call socket send, so it should exit before socket_free
	skynet_harbor_exit();
	skynet_socket_free();
	if (config->daemon) {
		daemon_exit(config->daemon);
	}
}
