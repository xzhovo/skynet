#include "skynet.h"

#include "skynet_socket.h"
#include "socket_server.h"
#include "skynet_server.h"
#include "skynet_mq.h"
#include "skynet_harbor.h"

#include <stdio.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

static struct socket_server * SOCKET_SERVER = NULL;

/*
从初始化代码来看，我们可以知道skynet的网络层使用了epoll模型，epoll属于同步io，当没有任何一个fd能收到客户端发送过来的数据包，
或者任何一个fd有要向客户端推送数据包时，那么socket线程将被阻塞，当有任意一个fd能够接收数据包或者发送数据包时，就会唤醒socket线程，并对数据包进行处理。
不同于select和poll，当有事件触发时，epoll不需要轮询并测试所有的fd（效率为O(n)），只返回准备好的fd及事件(效率是O(1))。
 */
/*
此外，skynet的网络层，还在单个节点内使用管道，这里的目的是，其他线程向socket线程发送数据包，这样做的好处是，
socket线程能够像处理网络消息一样，处理来自其他线程的请求，并且完全不用加任何锁，保证了线程安全，也简化了逻辑复杂度。
对于 worker 线程当前处理消息的服务是外部 socket 连接的代理服务，可尝试在前面没有 该 socket fb 没有被发送包的情况下直接发送(有的话不能发，会乱包)
 */

/*
skynet监听和绑定端口的流程
	我们要真正接收来自客户端的消息时，通常需要创建一个gate服务，用于接收从socket线程发送过来的消息，首先我们要通过gate，绑定和监听一个端口。
这里，我们在gate创建阶段监听一个端口，在worker线程内，gate服务创建绑定了一个端口，并且监听了它，此时，gate服务（worker线程内）通过管道向socket线程发送了一个请求，
向socket slot里添加一个专门用于监听端口的socket（类型为SOCKET_TYPE_LISTEN），并且在epoll里添加这个socket的监听事件，这样当有关于该socket的epoll事件触发时，
由于epoll的event数据包含socket的指针，该socket对应的类型为SOCKET_TYPE_LISTEN，因此我们可以知道该epoll事件，其实是有一个连接可以建立了。
在连接建立以后，socket线程会向gate服务发送一条消息，通知gate服务新建立连接socket的slot id，让gate自己处理。

skynet建立和客户端连接流程
	我们在创建了一个监听端口的socket并且为其添加epoll事件以后，当有客户端发送连接请求的时候，socket线程会accept他们，并在socket slot里添加新的socket，
此时，socket线程也会向gate服务的次级消息队列，插入一个消息，告知它，有新的连接建立，并且告诉gate新创建socket在socket slot的id，gate接收到新连接建立事件后，
会根据会创建一个lua服务–agent服务（这里忽略登陆验证的情况），并且以socket的slot id为key，agent服务地址为value存入一个table，以便于gate接收到消息的时候，
通过socket slot id查找agent地址并将数据包转发给agent服务。此外，这里也以agent服务地址为key，socket slot id为value，将信息存入另一个table表，以便于agent要推送消息时，
通过管道，将要下传的数据以及socket slot id一起发给socket线程，socket线程通过id，找到对应的socket指针，并将数据通过fd传给客户端。

skynet接收客户端消息流程 
	由于单个skynet节点内，所有的socket都归gate服务管理，当socket收到数据包以后，就会往gate服务的次级消息队列，push数据包消息，gate在收到消息以后，
	首先会对数据进行分包和粘包处理，当收齐所有字节以后，又会向agent服务转发（向agent的次级消息队列push消息），最后agent会一个一个消费这些从客户端上传的请求。

服务端向客户端发送数据流程 
	agent服务向客户端发送消息时，直接通过管道，将数据包从worker线程发送往socket线程，socket线程收到后，会将数据包存入对应socket的write buffer中，最后再向客户端推送。
 */

void 
skynet_socket_init() {
	SOCKET_SERVER = socket_server_create(skynet_now());
}

void
skynet_socket_exit() {
	socket_server_exit(SOCKET_SERVER);
}

void
skynet_socket_free() {
	socket_server_release(SOCKET_SERVER);
	SOCKET_SERVER = NULL;
}

void
skynet_socket_updatetime() {
	socket_server_updatetime(SOCKET_SERVER, skynet_now());
}

// mainloop thread
static void
forward_message(int type, bool padding, struct socket_message * result) {
	struct skynet_socket_message *sm;
	size_t sz = sizeof(*sm);
	if (padding) {
		if (result->data) {
			size_t msg_sz = strlen(result->data);
			if (msg_sz > 128) {
				msg_sz = 128;
			}
			sz += msg_sz;
		} else {
			result->data = "";
		}
	}
	sm = (struct skynet_socket_message *)skynet_malloc(sz);
	sm->type = type;
	sm->id = result->id;
	sm->ud = result->ud;
	if (padding) { //message.data = result->data
		sm->buffer = NULL;
		memcpy(sm+1, result->data, sz - sizeof(*sm));
	} else {
		sm->buffer = result->data;
	}

	struct skynet_message message;
	message.source = 0;
	message.session = 0;
	message.data = sm;
	message.sz = sz | ((size_t)PTYPE_SOCKET << MESSAGE_TYPE_SHIFT); // lua 中的 skynet.PTYPE_SOCKET type
	
	if (skynet_context_push((uint32_t)result->opaque, &message)) {
		// todo: report somewhere to close socket
		// don't call skynet_socket_close here (It will block mainloop)
		skynet_free(sm->buffer);
		skynet_free(sm);
	}
}

//socket 线程工作
int 
skynet_socket_poll() {
	struct socket_server *ss = SOCKET_SERVER;
	assert(ss);
	struct socket_message result;
	int more = 1;
	int type = socket_server_poll(ss, &result, &more); //发送消息并获得发送带来的结果(并不是回复)当前的 soket type
	// 将结果 result 回复给服务，以插入服务专属消息队列形式
	switch (type) {
	case SOCKET_EXIT:
		return 0;
	case SOCKET_DATA:
		forward_message(SKYNET_SOCKET_TYPE_DATA, false, &result);
		break;
	case SOCKET_CLOSE:
		forward_message(SKYNET_SOCKET_TYPE_CLOSE, false, &result);
		break;
	case SOCKET_OPEN:
		forward_message(SKYNET_SOCKET_TYPE_CONNECT, true, &result); // SOCKET_OPEN -> SKYNET_SOCKET_TYPE_CONNECT
		break;
	case SOCKET_ERR:
		forward_message(SKYNET_SOCKET_TYPE_ERROR, true, &result);
		break;
	case SOCKET_ACCEPT:
		forward_message(SKYNET_SOCKET_TYPE_ACCEPT, true, &result);
		break;
	case SOCKET_UDP:
		forward_message(SKYNET_SOCKET_TYPE_UDP, false, &result);
		break;
	case SOCKET_WARNING:
		forward_message(SKYNET_SOCKET_TYPE_WARNING, false, &result);
		break;
	default:
		skynet_error(NULL, "Unknown socket message type %d.",type);
		return -1;
	}
	if (more) {
		return -1;
	}
	return 1;
}

//call by lua-socket.c:lsend 来源 worker 线程 lua 服务 send 语义
int
skynet_socket_send(struct skynet_context *ctx, int id, void *buffer, int sz) {
	//skynet_error(ctx, "skynet_socket_send %u.", skynet_context_handle(ctx));
	return socket_server_send(SOCKET_SERVER, id, buffer, sz);
}

//call by lua-socket.c:lsendlow 来源 worker 线程 lua 服务 send 语义
int
skynet_socket_send_lowpriority(struct skynet_context *ctx, int id, void *buffer, int sz) {
	return socket_server_send_lowpriority(SOCKET_SERVER, id, buffer, sz);
}

// lua socket listen
int 
skynet_socket_listen(struct skynet_context *ctx, const char *host, int port, int backlog) {
	uint32_t source = skynet_context_handle(ctx);
	return socket_server_listen(SOCKET_SERVER, source, host, port, backlog);
}

int 
skynet_socket_connect(struct skynet_context *ctx, const char *host, int port) {
	uint32_t source = skynet_context_handle(ctx);
	return socket_server_connect(SOCKET_SERVER, source, host, port);
}

int 
skynet_socket_bind(struct skynet_context *ctx, int fd) {
	uint32_t source = skynet_context_handle(ctx);
	return socket_server_bind(SOCKET_SERVER, source, fd);
}

void 
skynet_socket_close(struct skynet_context *ctx, int id) {
	uint32_t source = skynet_context_handle(ctx);
	socket_server_close(SOCKET_SERVER, source, id);
}

void 
skynet_socket_shutdown(struct skynet_context *ctx, int id) {
	uint32_t source = skynet_context_handle(ctx);
	socket_server_shutdown(SOCKET_SERVER, source, id);
}

void 
skynet_socket_start(struct skynet_context *ctx, int id) {
	uint32_t source = skynet_context_handle(ctx);
	socket_server_start(SOCKET_SERVER, source, id);
}

void
skynet_socket_nodelay(struct skynet_context *ctx, int id) {
	socket_server_nodelay(SOCKET_SERVER, id);
}

int 
skynet_socket_udp(struct skynet_context *ctx, const char * addr, int port) {
	uint32_t source = skynet_context_handle(ctx);
	return socket_server_udp(SOCKET_SERVER, source, addr, port);
}

int 
skynet_socket_udp_connect(struct skynet_context *ctx, int id, const char * addr, int port) {
	return socket_server_udp_connect(SOCKET_SERVER, id, addr, port);
}

int 
skynet_socket_udp_send(struct skynet_context *ctx, int id, const char * address, const void *buffer, int sz) {
	return socket_server_udp_send(SOCKET_SERVER, id, (const struct socket_udp_address *)address, buffer, sz);
}

const char *
skynet_socket_udp_address(struct skynet_socket_message *msg, int *addrsz) {
	if (msg->type != SKYNET_SOCKET_TYPE_UDP) {
		return NULL;
	}
	struct socket_message sm;
	sm.id = msg->id;
	sm.opaque = 0;
	sm.ud = msg->ud;
	sm.data = msg->buffer;
	return (const char *)socket_server_udp_address(SOCKET_SERVER, &sm, addrsz);
}

struct socket_info *
skynet_socket_info() {
	return socket_server_info(SOCKET_SERVER);
}
