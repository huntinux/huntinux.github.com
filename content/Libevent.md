Title: Libevent 
Date: 2016-06-29 09:00
Modified: 2016-06-29 09:09:37
Category: Linux
Tags: Libevent 
Slug: 
Author: hongjin.cao 
Summary: 这篇文章是学习《LibeventBook》的翻译总结。

# 前言
以下内容是对《LibeventBook》的翻译

# Chapter6 : Creating a event_base
> Before you can use any interesting Libevent function, you need to allocate one or more event_base structures. Each event_base structure holds a set of events and can poll to determine which events are active.

使用libevent时，首先需要创建一个或多个event_base结构。每个event_base包含一些events，event_base能够poll出哪些事件发生了，并通知用户。

> If an event_base is set up to use locking, it is safe to access it between multiple threads. Its loop can only be run in a single thread, however. If you want to have multiple threads polling for IO, you need to have an event_base for each thread.

如果一个event_base被设置成使用locking（锁），那么多个线程访问它是安全的（线程安全的）。不过它的事件循环只能在一个线程中运行。如果向让多个线程对IO进行polling， 那么需要让每个线程都拥有一个event_base。

> Each event_base has a "method", or a backend that it uses to determine which events are ready. The recognized methods are:

event_base有一个用来确定哪些事件就绪的method，包括：

- select
- poll
- epoll
- kqueue
- devpoll
- evport
- win32

用户可以通过环境变量来disable某种method，如设置EVENT_NOKQUEUE环境变量将禁止kqueue。在程序中可以使用`event_config_avoid_method()`函数来禁用某种method。

## 获取一个默认的event_base

```c
// <event2/event.h>
struct event_base *event_base_new(void);
```

event_base_new()函数分配并返回一个新的event_base(默认设置)。它会检查环境变量并返回一个指向新的event_base的指针。发生错误时，返回NULL。在选择method的时候，会选取当前OS支持的最快的method。

## 获取经过配置的event_base

```c
struct event_config *event_config_new(void);
struct event_base *event_base_new_with_config(const struct event_config *cfg);
void event_config_free(struct event_config *cfg);
```

## 确定event_base可以使用哪些method

```c
const char **event_get_supported_methods(void);
```
## 确定event_base在使用哪种method

```c
const char *event_base_get_method(const struct event_base *base);
enum event_method_feature event_base_get_features(const struct event_base *base);
```

## 释放event_base
```c
void event_base_free(struct event_base *base);
```

## 在fork()之后对event_base进行Reinitializing
```c
int event_reinit(struct event_base *base);
```

## 测试程序
```c
#include <event2/event.h>

int main()
{
    /* 查看当前支持哪些method */
    int i;
    const char **methods = event_get_supported_methods();
    printf("Starting Libevent %s. Available methods are:\n", event_get_version());
    for (i=0; methods[i] != NULL; ++i) {
        printf("%s\n", methods[i]);
    }

    /* 当前使用的什么method，以及该method的feature */
    struct event_base *base;
    enum event_method_feature f;
    base = event_base_new();
    if (!base) {
        puts("Couldn’t get an event_base!");
    } else {
        printf("Using Libevent with backend method %s.",
                event_base_get_method(base));
        f = event_base_get_features(base);
        if ((f & EV_FEATURE_ET))
            printf(" Edge-triggered events are supported."); /* 支持边缘触发 Edge-Triggered*/
        if ((f & EV_FEATURE_O1))
            printf(" O(1) event notification is supported."); /* poll,添加，删除一个event是O(1)的 */
        if ((f & EV_FEATURE_FDS))
            printf(" All FD types are supported."); /* 支持任意类型的文件描述符（fd）： 普通文件fd，socket fd */
        puts("");
    }
 
    /* 释放event_base */
    event_base_free(base);
    return 0;
}
```

# Chapter7 : Working with event loop
在创建了event_base，并在它上面注册了一些event之后，可以使用`event_base_loop()`来检测事件是否就绪。

```c
#define EVLOOP_ONCE             0x01
#define EVLOOP_NONBLOCK         0x02
#define EVLOOP_NO_EXIT_ON_EMPTY 0x04
int event_base_loop(struct event_base *base, int flags);
```

event_base_loop的伪代码
```
while (any events are registered with the loop,
        or EVLOOP_NO_EXIT_ON_EMPTY was set) {
    if (EVLOOP_NONBLOCK was set, or any events are already active)
        If any registered events have triggered, mark them active.
    else
        Wait until at least one event has triggered, and mark it active.
            
    for (p = 0; p < n_priorities; ++p {
        if (any event with priority of p is active) {
            Run all active events with priority of p.
            break; /* Do not run any events of a less important priority */
        }
    }
    if (EVLOOP_ONCE was set or EVLOOP_NONBLOCK was set)
        break;
}
```
可以使用event_base_dispatch，它与event_base_loop相同，只不过没有flag参数，它会一直运行，直到没有注册事件或`event_base_loopbreak() or event_base_loopexit()`被调用。
```c
int event_base_dispatch(struct event_base *base);
```

# Chapter8 : Working with events
libevent的基本操作单元是event，每个event代表了一些条件：

- A file descriptor being ready to read from or write to. 
- A file descriptor becoming ready to read from or write to (Edge-triggered IO only).
- A timeout expiring.
- A signal occurring.
- A user-triggered event.

每个event的生命周期是这样的:
> Events have similar lifecycles. Once you call a Libevent function to set up an event and associate it with an event base, it becomes **initialized**. At this point, you can add, which makes it **pending** in the base. When the event is pending, if the conditions that would trigger an event occur (e.g., its file descriptor changes state or its timeout expires), the event becomes **active**, and its (user-provided) callback function is run. If the event is configured **persistent**  , it remains pending. If it is not persistent, it stops being pending when its callback runs. You can make a pending event non-pending by deleting it, and you can add a non-pending event to make it pending again.

## 创建一个event
```c
/** Indicates that a timeout has occurred.  It's not necessary to pass
 * this flag to event_for new()/event_assign() to get a timeout. */
#define EV_TIMEOUT	0x01
/** Wait for a socket or FD to become readable */
#define EV_READ		0x02
/** Wait for a socket or FD to become writeable */
#define EV_WRITE	0x04
/** Wait for a POSIX signal to be raised*/
#define EV_SIGNAL	0x08
/**
 * Persistent event: won't get removed automatically when activated.
 *
 * When a persistent event with a timeout becomes activated, its timeout
 * is reset to 0.
 */
#define EV_PERSIST	0x10
/** Select edge-triggered behavior, if supported by the backend. */
#define EV_ET       0x20

typedef void (*event_callback_fn)(evutil_socket_t, short, void *);
struct event *event_new(struct event_base *base, evutil_socket_t fd, short what, event_callback_fn cb, void *arg);
void event_free(struct event *event);
```

创建了一个event之后，使用event_add让event加入event_base, 进入pending状态。
```c
int event_add(struct event *ev, const struct timeval *tv);
```

# Chapter10 ： Bufferevents

>This buffered IO pattern is common enough that Libevent provides a generic mechanism for it. A "bufferevent" consists of an underlying transport (like a socket), a read buffer, and a write buffer. Instead of regular events, which give callbacks when the underlying transport is ready to be read or written, a bufferevent invokes its user-supplied callbacks when it has read or written enough data.

通常的做法是在关注的socket可读或可写时调用callback；而bufferevent则在读取了足够的数据或写入了足够的数据时才去调用用户定义的回调函数。因此，前者是通知“就绪”，后者是通知“完成”。

bufferevent的类型：
1. socket-based bufferevents : 
A bufferevent that sends and receives data from an underlying stream socket, using the event_* interface as its backend.
2. asynchronous-IO bufferevents :
A bufferevent that uses the Windows IOCP interface to send and receive data to an underlying stream socket. (Windows
only; experimental.)
3. filtering bufferevents : 
A bufferevent that processes incoming and outgoing data before passing it to an underlying bufferevent object—for exam-
ple, to compress or translate data.
4. paired bufferevents :
Two bufferevents that transmit data to one another.

## Bufferevents and evbuffers
每个Bufferevents都有两个数据区： input buffer 和 output buffer。类型都是`struct evbuffer`。
当你有数据要写到bufferevent上时，就将数据添加到output buffer。
当bufferevent有数据可读时，可以从input buffer得到它们。

## Callbacks and watermarks
> Every bufferevent has two data-related callbacks: a read callback and a write callback. By default, the read callback is called whenever any data is read from the underlying transport, and the write callback is called whenever enough data from the output buffer is emptied to the underlying transport. You can override the behavior of these functions by adjusting the read and write "watermarks" of the bufferevent.

bufferevent有两个数据相关的回调函数：`read callback and  write callback`。默认情况下，`read callback`会当 从关注的socket读到了任意的数据时被调用；`write callback` 在全部的数据从output buffer传送给了对端时被调用。可以通过修改bufferevent的读写watermarks（读写水位）来修改`read callback and  write callback`的行为。

4个watermarks： 
- Read low-water mark ： 
Whenever a read occurs that leaves the bufferevent’s input buffer at this level or higher, the bufferevent’s read callback is invoked. Defaults to 0, so that every read results in the read callback being invoked.

- Read high-water mark ： 
If the bufferevent’s input buffer ever gets to this level, the bufferevent stops reading until enough data is drained from the input buffer to take us below it again. Defaults to unlimited, so that we never stop reading because of the size of the input buffer.

- Write low-water mark ： 
Whenever a write occurs that takes us to this level or below, we invoke the write callback. Defaults to 0, so that a write callback is not invoked unless the output buffer is emptied.

- Write high-water mark ： 
Not used by a bufferevent directly, this watermark can have special meaning when a bufferevent is used as the underlying
transport of another bufferevent. See notes on filtering bufferevents below.

## Working with socket-based bufferevent

socket-based的bufferevent是最简单易用的bufferevent类型， 它使用Libevent的事件机制来检查socket是否“读就绪”或“写就绪”，并使用网络系统调用（readv, writev, WSASend, or WSARecv）来收发数据。

### 创建一个socket-based bufferevent

```c
struct bufferevent *bufferevent_socket_new(
    struct event_base *base,
    evutil_socket_t fd,
    enum bufferevent_options options);
```
### 在socket-based bufferevent上发起连接
```c
int bufferevent_socket_connect(struct bufferevent *bev,
    struct sockaddr *address, int addrlen);
```

# Chapter13 : Connection Listener

```c
#include <event2/listener.h>
#include <event2/bufferevent.h>
#include <event2/buffer.h>
#include <arpa/inet.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>

static void
echo_read_cb(struct bufferevent *bev, void *ctx)
{
    /* This callback is invoked when there is data to read on bev. */
    struct evbuffer *input = bufferevent_get_input(bev);
    struct evbuffer *output = bufferevent_get_output(bev);
    /* Copy all the data from the input buffer to the output buffer. */
    evbuffer_add_buffer(output, input);
}

static void
echo_event_cb(struct bufferevent *bev, short events, void *ctx)
{
    if (events & BEV_EVENT_ERROR)
        perror("Error from bufferevent");
    if (events & (BEV_EVENT_EOF | BEV_EVENT_ERROR)) {
        bufferevent_free(bev);
    }
}

static void
accept_conn_cb(struct evconnlistener *listener,
        evutil_socket_t fd, struct sockaddr *address, int socklen,
        void *ctx)
{
    /* We got a new connection! Set up a bufferevent for it. */
    struct event_base *base = evconnlistener_get_base(listener);
    struct bufferevent *bev = bufferevent_socket_new(
            base, fd, BEV_OPT_CLOSE_ON_FREE);
    bufferevent_setcb(bev, echo_read_cb, NULL, echo_event_cb, NULL);
    bufferevent_enable(bev, EV_READ|EV_WRITE);
}

static void
accept_error_cb(struct evconnlistener *listener, void *ctx)
{
    struct event_base *base = evconnlistener_get_base(listener);
    int err = EVUTIL_SOCKET_ERROR();
    fprintf(stderr, "Got an error %d (%s) on the listener. "
            "Shutting down.\n", err, evutil_socket_error_to_string(err));
    event_base_loopexit(base, NULL);
}

int main(int argc, char **argv)
{
    struct event_base *base;
    struct evconnlistener *listener;
    struct sockaddr_in sin;
    int port = 9876;
    if (argc > 1) {
        port = atoi(argv[1]);
    }

    if (port<=0 || port>65535) {
        puts("Invalid port");
        return 1;
    }
    base = event_base_new();
    if (!base) {
        puts("Couldn’t open event base");
        return 1;
    }
    /* Clear the sockaddr before using it, in case there are extra
     * platform-specific fields that can mess us up. */
    memset(&sin, 0, sizeof(sin));
    /* This is an INET address */
    sin.sin_family = AF_INET;
    /* Listen on 0.0.0.0 */
    sin.sin_addr.s_addr = htonl(0);
    /* Listen on the given port. */
    sin.sin_port = htons(port);
    listener = evconnlistener_new_bind(base, accept_conn_cb, NULL,
            LEV_OPT_CLOSE_ON_FREE|LEV_OPT_REUSEABLE, -1,
            (struct sockaddr*)&sin, sizeof(sin));
    if (!listener) {
        perror("Couldn’t create listener");
        return 1;
    }
    evconnlistener_set_error_cb(listener, accept_error_cb);
    event_base_dispatch(base);
    return 0;
}
```







