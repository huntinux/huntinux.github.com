Title: Muduo : Acceptor
Date: 2016-08-11 11:00
Modified: 2016-08-11 11:09:37
Category: Muduo 
Tags: Muduo, Acceptor
Slug: 
Author: hongjin.cao 
Summary: 学习了Muduo的Acceptor的实现。Acceptor其实是对Channel、Socket的封装，如果理解了上一节的muduo：Reactor，那么理解Acceptor也不在话下。

# 引言

Acceptor用于接受（accept）客户端的连接，通过设置回调函数通知使用者。它只在muduo网络库内部的TcpServer使用，由TcpServer控制它的生命期。

实际上，Acceptor只是对Channel的封装，通过Channel关注listenfd的readable可读事件，并设置好回调函数就可以了。因此理解了上一节的`muduo：Reactor`，那么Acceptor也比较容易理解。

# 成员变量

```c
 private:
  EventLoop* loop_;
  Socket acceptSocket_;   // 监听套接字，Socket是个RAII型，析构时自动close文件描述符
  Channel acceptChannel_; // 通过该channel，设置监听套接字的readable事件以及回调函数
  NewConnectionCallback newConnectionCallback_;
  bool listenning_;
  int idleFd_;
```

其中`NewConnectionCallback`是个typedef：
```c
typedef NewConnectionCallback boost::function<void(int sockfd, const InetAddress&)>
```

# 构造函数/析构函数

```c
Acceptor::Acceptor(EventLoop* loop, const InetAddress& listenAddr, bool reuseport)
  : loop_(loop),
    acceptSocket_(sockets::createNonblockingOrDie(listenAddr.family())), // socket
    acceptChannel_(loop, acceptSocket_.fd()),
    listenning_(false),
    idleFd_(::open("/dev/null", O_RDONLY | O_CLOEXEC))
{
  assert(idleFd_ >= 0);
  acceptSocket_.setReuseAddr(true);
  acceptSocket_.setReusePort(reuseport);
  acceptSocket_.bindAddress(listenAddr); // bind 
  acceptChannel_.setReadCallback(
      boost::bind(&Acceptor::handleRead, this)); // 设置监听套接字可读时的回调函数
}
```

```c
Acceptor::~Acceptor()
{
  acceptChannel_.disableAll(); // 移除注册的事件
  acceptChannel_.remove();     // Poller会持有Channel的裸指针，所以需要将该Channel从Poller中删除，避免Channel析构后，Poller持有空悬指针。
  ::close(idleFd_);
}

```

# 公有接口

`Acceptor::listen()`
```c
void Acceptor::listen()
{
  loop_->assertInLoopThread();
  listenning_ = true;
  acceptSocket_.listen();         // listen
  acceptChannel_.enableReading(); // 注册监听套接字的readable事件
}
```

# 私有接口

`Acceptor::handleRead()`在有新连接时被调用。

```c
void Acceptor::handleRead()
{
  loop_->assertInLoopThread();
  InetAddress peerAddr;
  //FIXME loop until no more
  int connfd = acceptSocket_.accept(&peerAddr); // accept
  if (connfd >= 0)
  {
    // string hostport = peerAddr.toIpPort();
    // LOG_TRACE << "Accepts of " << hostport;
    if (newConnectionCallback_)
    {
      newConnectionCallback_(connfd, peerAddr); // 执行用户回调
    }
    else
    {
      sockets::close(connfd);
    }
  }
  else
  {
    LOG_SYSERR << "in Acceptor::handleRead";
    // Read the section named "The special problem of
    // accept()ing when you can't" in libev's doc.
    // By Marc Lehmann, author of libev.
    if (errno == EMFILE)
    {
      ::close(idleFd_);
      idleFd_ = ::accept(acceptSocket_.fd(), NULL, NULL);
      ::close(idleFd_);
      idleFd_ = ::open("/dev/null", O_RDONLY | O_CLOEXEC);
    }
  }
}

```

# 使用示例

> https://github.com/huntinux/muduo-learn/blob/v0.2/

```c
void newConnection(int sockfd, struct sockaddr &in_addr, socklen_t in_len)
{
    printf_address(sockfd, &in_addr, in_len);
    ::write(sockfd, "jinger\n", 8);
    ::close(sockfd);
}

int main()
{
    muduo::net::EventLoop loop;
    muduo::net::Acceptor acceptor(&loop, "8090");
    acceptor.setNewConnectionCallback(newConnection);
    acceptor.listen();
    loop.loop();
    return 0;
}
```

使用者只需要设置好回调函数然后listen即可。`socket->bind->listen->accept` 这些步骤在底层都已经封装好了。

此外，上面的代码与muduo真实代码有些出入，但是原理是一样的。


