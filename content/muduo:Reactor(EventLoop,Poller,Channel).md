Title: Muduo : Reactor(EventLoop, Channel, Poller)
Date: 2016-08-10 11:00
Modified: 2016-08-10 11:09:37
Category: Muduo 
Tags: Muduo, Reactor
Slug: 
Author: hongjin.cao 
Summary: 学习了Muduo的Reactor实现方法，包括事件循环EventLoop、IO Multiplexing的封装Poller、将事件与回调函数联系起来的Channel

> Linux多线程服务器编程 6.4.1

> TCP网络编程最本质的是处理`三个半事件`:

> 1. 连接的建立, 包括server accept新连接,客户端成功connect.TCP连接一旦建立,server和client的地位是相等的,可以各自收发数据.

> 2. 连接的断开,包括主动断开(close,shutdown)和被动断开(read返回0)

> 3. 消息到达,文件描述符可读.(对该事件的处理方式决定了网络编程的风格,阻塞还是非阻塞?如何处理分包?应用层缓冲如何设计?)

> 3.5  消息发送完毕,这算半个,这里的发送完毕是指将数据写入操作系统的缓冲区,将由TCP协议栈负责数据的发送和重传,不代表对方已经接收到数据.

接下来就来学习下muduo是如何处理这`三个半事件的`

# Reactor Pattern

`《Linux高性能服务器编程》`的8.4小节中介绍了Reactor和Proactor,Reactor是向工作线程通知`事件的发生`,而Proactor则是通知`事件的完成`.

TODO: 总结[Reactor](https://en.wikipedia.org/wiki/Reactor_pattern)

muduo也是基于Reactor模型的.

# muduo 的Reactor
![这里写图片描述](https://lh3.googleusercontent.com/LS86ZKntcADnDQdezB-26s0kBTn34LgFWwgsaP77BEKZwUBLqOoAZT6yRrjFcBsrMR9hjV-N8nhZ7qvWYNI3zJ3Ofe9yGIGdz8kwDkGBjCc3RCdNh_QqAICu0b7qETT7sgGzOqRLaPci7H1SAT7jsJVhdXsASJoqayHjAk5_lK2ZBQQt31rfZpUms7J5DcODEIwvg7teog10colnwKkT0vRSTtJD54pXimYvbi0fB0qrElyTepiz90Ox9o6esof4eIn1hHvOqtQMX4l84tL5EhH-vN3fmmHl5GhD1wdKAKVlPmDnJblPe6JtDE9fGFHTzDWKhKtllzpAjlsMIi2hVlpNyfXfUcH3S-94bG5SPoNBvNigv9sQVD7xaCOlxPZ2UeNvv-gXiGmGgadmixo0kZdcTYmtlFDcbEJC-1DHQx4v_yTHU5IzRP44JNyMfqRK5_0-q5Oe2H2J7WIhvawtm1K3EWFmnQNUErtU6L7ULQXTiCB-AcomI6h5RfeqsqSxAPaoqGoAJO8jhrxrf7-asqBfHJYtR40dpmnW8vSCOkaNxBCVrlUvqtNF0KM84oPt73g1BkMnCgzK69ATR63KgNhDbAFtzQ=w944-h576-no)

# EventLoop

为了保证每个线程只有一个EventLoop，EventLoop会记录创建它的线程ID，并且使用`__thread`（TLS线程局部存储）来记录当前线程创建的EventLoop对象的指针。当某线程创建了超过一个EventLoop时,就结束程序。这样就能保证一个线程只有一个EventLoop,即`one loop per thread`

EventLoop会进行事件循环，使用某种IO Multiplexing技术（select、poll、epoll）监听关心的文件描述符fds是否发生了关注的事件，然后调用相应的handler。因此线程会阻塞在此，当然也可以设置超时时间。 为了能及时唤醒该线程，可以让EventLoop自身也有一个fd，关注它的readable事件，想将EventLoop所在线程唤醒时，只需要向该fd进行写操作即可。

EventLoop的生命周期与所在线程相同，不必是heap上的。此外，将拥有EventLoop的线程称为`IO线程`，应为该线程只关心socket fd上的IO。其他线程可以称为‘工作线程’，负责业务逻辑。

`activeChannels_`用来存放发生了事件的Channel的集合，通过poller来获得（poller负责设置Channel发生了什么事件）。然后调用每个Channel的`handleEvent`来处理发生的事件，`handleEvent`根据poller设置的发生事件，调用想用的处理函数。

最主要的事件循环就是这样的：
```c
void EventLoop::loop()
{
  // ...
  while (!quit_)
  {
    activeChannels_.clear();
    // 通过poller获取就绪的channel，放到activeChannels_中，poller会将发生的事件类型填写到channel的revents_中，供Channel::handleEvent使用
    pollReturnTime_ = poller_->poll(kPollTimeMs, &activeChannels_);
    ++iteration_;

    eventHandling_ = true;
    for (ChannelList::iterator it = activeChannels_.begin();
        it != activeChannels_.end(); ++it)
    {
      currentActiveChannel_ = *it;
      // 调用channel的事件处理函数handleEvent，根据poller设置的发生的事件类型，调用相应的用户回调函数
      currentActiveChannel_->handleEvent(pollReturnTime_);
    }
    currentActiveChannel_ = NULL;
    eventHandling_ = false;
    // ...
  }
//...
}
```

# Channel

每个Channel只负责一个文件描述符fd的IO事件分发，但它不拥有这个fd，也不在析构时关闭该fd。Channel会把不同的IO事件分发给不同的回调函数，如ReadCallback、WriteCallback。

每个Channel自始至终只属于一个EventLoop，所以每个Channel只属于一个`IO线程`

Channel处理事件（其中revents_代表事件类型，由poller负责填写）：
```c
void Channel::handleEvent(Timestamp receiveTime)
{
  eventHandling_ = true;
  LOG_TRACE << reventsToString();
  if ((revents_ & POLLHUP) && !(revents_ & POLLIN))
  {
    if (logHup_)
    {
      LOG_WARN << "fd = " << fd_ << " Channel::handle_event() POLLHUP";
    }
    if (closeCallback_) closeCallback_();
  }

  if (revents_ & POLLNVAL)
  {
    LOG_WARN << "fd = " << fd_ << " Channel::handle_event() POLLNVAL";
  }

  if (revents_ & (POLLERR | POLLNVAL))
  {
    if (errorCallback_) errorCallback_();
  }
  if (revents_ & (POLLIN | POLLPRI | POLLRDHUP))
  {
    if (readCallback_) readCallback_(receiveTime);
  }
  if (revents_ & POLLOUT)
  {
    if (writeCallback_) writeCallback_();
  }
  eventHandling_ = false;
}
```

# Poller

 Poller是对IO Multiplexing的封装（可用select、poll、epoll），它属于某个EventLoop，生命周期与EventLoop相同，使用时无需加锁。Poller并不拥有Channel，只是持有Channel的裸指针（`map<int,Channel*>`,一个fd对应一个channel），因此Channel在析构之前，需要自己unregister，即调用`EventLoop::removeChannel--->Poller::removeChannel`，将自己从Poller的channels中删除，避免空悬指针。

EPollPoller继承了Poller，主要的事件轮询poll实现如下，通过`epoll_wait`获取就绪的channel，放到activeChannels中，供EventLoop使用。
```c
Timestamp EPollPoller::poll(int timeoutMs, ChannelList* activeChannels)
{
  LOG_TRACE << "fd total count " << channels_.size(); // channels是一个map<fd, Channel*>,保存了fd对应的channel

  // 查询发生了哪些事件，存放在events_中
  int numEvents = ::epoll_wait(epollfd_,
                               &*events_.begin(),
                               static_cast<int>(events_.size()),
                               timeoutMs);
  if (numEvents > 0)
  {
    fillActiveChannels(numEvents, activeChannels); // 将就绪的channel放到activeChannels，供EventLoop使用
    if (implicit_cast<size_t>(numEvents) == events_.size())
    {
      events_.resize(events_.size()*2);
    }
  }
  else if (numEvents == 0)
  {
    LOG_TRACE << "nothing happended";
  }
  else
  {
    // error happens, log uncommon ones
    if (savedErrno != EINTR)
    {
      errno = savedErrno;
      LOG_SYSERR << "EPollPoller::poll()";
    }
  }
 //...
}

void EPollPoller::fillActiveChannels(int numEvents,
                                     ChannelList* activeChannels) const
{
  assert(implicit_cast<size_t>(numEvents) <= events_.size());
  for (int i = 0; i < numEvents; ++i)
  {
    // epoll_event.data.ptr存放的是Channel的指针
    Channel* channel = static_cast<Channel*>(events_[i].data.ptr);
    channel->set_revents(events_[i].events); // 设置发生的事件到Channel::revents_
    activeChannels->push_back(channel);
  }
}
```

channel注册事件通过`Poller::updateChannel`实现。其中channel有几个状态`kNew、kDeleted、kAdded`，分别表示`新的、已删除、已被添加到Poller`。在updateChannel时会根据Channel的状态执行不同的操作。可以看到底层操作使用的是`epoll_ctl`

```c
void EPollPoller::updateChannel(Channel* channel)
{
  const int index = channel->index();
  if (index == kNew || index == kDeleted)
  {
    // a new one, add with EPOLL_CTL_ADD
    int fd = channel->fd();
    if (index == kNew)
    {
      assert(channels_.find(fd) == channels_.end());
      channels_[fd] = channel;
    }
    else // index == kDeleted
    {
      assert(channels_.find(fd) != channels_.end());
      assert(channels_[fd] == channel);
    }

    channel->set_index(kAdded);
    update(EPOLL_CTL_ADD, channel);
  }
  else
  {
    // update existing one with EPOLL_CTL_MOD/DEL
    int fd = channel->fd();
    (void)fd;
    assert(channels_.find(fd) != channels_.end());
    assert(channels_[fd] == channel);
    assert(index == kAdded);
    if (channel->isNoneEvent())
    {
      update(EPOLL_CTL_DEL, channel);
      channel->set_index(kDeleted);
    }
    else
    {
      update(EPOLL_CTL_MOD, channel);
    }
  }
}

void EPollPoller::update(int operation, Channel* channel)
{
  struct epoll_event event;
  bzero(&event, sizeof event);
  event.events = channel->events();
  event.data.ptr = channel; // 保存Channel的指针
  int fd = channel->fd();
  LOG_TRACE << "epoll_ctl op = " << operationToString(operation)
    << " fd = " << fd << " event = { " << channel->eventsToString() << " }";
  if (::epoll_ctl(epollfd_, operation, fd, &event) < 0)
  {
    if (operation == EPOLL_CTL_DEL)
    {
      LOG_SYSERR << "epoll_ctl op =" << operationToString(operation) << " fd =" << fd;
    }
    else
    {
      LOG_SYSFATAL << "epoll_ctl op =" << operationToString(operation) << " fd =" << fd;
    }
  }
}

```
 可以看到`epoll_event.data.ptr`存放的是Channel的指针，这样在相应的fd变得active时，可以从`epoll_event.data.ptr`找到对应的Channel。可以看到指针的重要性，它连接了“两个世界”。
# Example

这是书上的使用示例，展示了EventLoop、Channel、Poller的使用方法：

```c

muduo::net::EventLoop* g_loop;

void timeout()
{
    std::cout << "Timeout!" << std::endl;
    g_loop->quit();
}

int main()
{
    muduo::net::EventLoop loop;
    g_loop = &loop;

    int timerfd = ::timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if(-1 == timerfd) {
        std::cerr << "timerfd_create faile" << std::endl;
        return -1;
    }

    // 创建一个Channel
    muduo::net::Channel channel(&loop, timerfd);
    // 设置读回调函数
    channel.setReadCallback(timeout);
    // 注册读事件
    channel.enableReading();

    struct itimerspec howlong;
    howlong.it_value.tv_sec = 2;
    ::timerfd_settime(timerfd, 0, &howlong, NULL);

    // 进行事件循环，通过Poller获取就绪的Channel，调用Channel::handleEvent，根据事件类型调用相应的回调函数
    loop.loop();
    
    ::close(timerfd);
    return 0;
}
```

可以发现muduo中类的设计比较有意思。Poller是EventLoop的成员变量，而Poller会持有EventLoop的指针，通过调用`EventLoop::assertInLoopThread`来保证某些操作只在所属的IO线程被调用。如Poller::updateChannel和Poller::removeChannel。

此外，Channel也持有EventLoop的指针，通过该指针间接地使用Poller的updateChannel和remvoeChannel。

# Source Code

从muduo源码中提取的，仅供学习使用
> https://github.com/huntinux/muduo-learn/tree/v0.1
