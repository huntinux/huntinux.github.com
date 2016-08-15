Title: Muduo : TcpConnection
Date: 2016-08-11 15:00
Modified: 2016-08-11 15:09:37
Category: Muduo 
Tags: Muduo, TcpConnection
Slug: 
Author: hongjin.cao 
Summary: 学习了Muduo的TcpConnection的实现。它的生命期管理最为复杂，需要好好理解。港真，我已经用了洪荒之力来理解它了。

# 引言

前面学习了TcpServer的实现，TcpServer对每个连接都会新建一个TcpConnection（使用shared_ptr管理）。接下来学习一下TcpConnection的设计细节。

# 连接状态

muduo对于一个连接的从生到死进行了状态的定义，类似一个状态机。
```c
enum States { kDisconnected, kConnecting, kConnected, kDisconnecting };
```
分别代表：已经断开、初始状态、已连接、正在断开

# 成员变量

```c
private
  EventLoop* loop_; // 神一样的存在，EventLoop
  string name_;
  States state_;  // FIXME: use atomic variable
  // we don't expose those classes to client.
  boost::scoped_ptr<Socket> socket_;   // 已连接套接字
  boost::scoped_ptr<Channel> channel_; // 已连接套接字对应的Channel
  InetAddress localAddr_;
  InetAddress peerAddr_;
  ConnectionCallback connectionCallback_;
  MessageCallback messageCallback_;
  WriteCompleteCallback writeCompleteCallback_;
  ConnectionCallback closeCallback_;
  Buffer inputBuffer_;  // 输入缓冲区
  // MutexLock mutex_;
  Buffer outputBuffer_; // 输出缓冲区
  boost::any context_;  // 存放上下文
```

先理解上面的 `loop_`, `socket_`, `channel_`好了，不明白请翻阅前几篇文章。

# 构造/析构函数

```c
TcpConnection::TcpConnection(EventLoop* loop,
                             const string& name__,
                             int sockfd,
                             const InetAddress& localAddr,
                             const InetAddress& peerAddr)
  : loop_(CHECK_NOTNULL(loop)),
    name_(name__),
    state_(kConnecting),          // 初始状态为kConnecting
    socket_(new Socket(sockfd)),  // RAII管理已连接套接字
    channel_(new Channel(loop, sockfd)), // 使用Channel管理套接字上的读写
    localAddr_(localAddr),
    peerAddr_(peerAddr)
{
  // 设置一些回调函数（好的，这很muduo）
  // 在已连接套接字可读时，调用TcpConnection::handleRead，进而调用用户设置的回调函数messageCallback_
  channel_->setReadCallback(
      boost::bind(&TcpConnection::handleRead, this, _1));
  channel_->setWriteCallback(
      boost::bind(&TcpConnection::handleWrite, this));
  channel_->setCloseCallback(
      boost::bind(&TcpConnection::handleClose, this));
  channel_->setErrorCallback(
      boost::bind(&TcpConnection::handleError, this));
  LOG_DEBUG << "TcpConnection::ctor[" <<  name_ << "] at " << this
    << " fd=" << sockfd;
}

TcpConnection::~TcpConnection()
{
  LOG_DEBUG << "TcpConnection::dtor[" <<  name_ << "] at " << this
    << " fd=" << channel_->fd();
}
```
构造函数在初始化列表中对socket、channel等进行了初始化，在函数体中设置了回调函数。

# TcpConnection::handleRead

```c
void TcpConnection::handleRead(Timestamp receiveTime)
{
  loop_->assertInLoopThread();
  int savedErrno;
  ssize_t n = inputBuffer_.readFd(channel_->fd(), &savedErrno);
  if (n > 0)
  {
    // 调用回调函数，使用shared_from_this()得到自身的shared_ptr, 延长了该对象的生命期，保证了它的生命期长过messageCallback_函数，messageCallback_能安全的使用它。
    messageCallback_(shared_from_this(), &inputBuffer_, receiveTime);
  }
  else if (n == 0)
  {
    handleClose();
  }
  else
  {
    // check savedErrno
  }
}
```
前面提到了，在已连接套接字可读时，调用`TcpConnection::handleRead`，进而调用用户设置的回调函数`messageCallback_`


# 连接的断开

这是muduo提到的`三个半事件`中的另一个事件，即处理连接的断开。这个过程比较绕，是这样事儿的，图中的`X`表示TcpConnection通常在此析构:

![这里写图片描述](https://lh3.googleusercontent.com/hpgbPt4QAAJ0RrfDgCfSvjUbOrJkMjLy_uy0-AALrlZAJ5Vyh_IlEhrPafS-7KHT7zyGdgTTadiw3rzICvJRqiAcLs9rlQd20D9gsETRaaO6RaHyxulErmpRmvBxUgx58GJdo4XHlYxjVv0MvjmElV6yYJSBHFVKEJesM54fd1gLaJgJ-OtdPwDD3cFf6gO8UTfWUR1UavniqHPzCU454o7YR6wnHQMXtVHmZzTXjF_VKKyQa3dV1d3sMouZ86WzI1ku13m1QbbzBuVWAEJjZ8bQU4ebDhMT08yoAL4uIWbKzGatRrFPaX9hNWrSh8jjmG5geeogs_yjOA6sELYpwqGXDiA7m0ew9E0ZkjzqVz0Ke_e14HRME88QpTYa1ZrnTIQXwyasr5Mkss3uABAVwOA0kG3_wlLxc7EeaplEDAOBXbJLuFvDqA1CDcnFOn7ZfEGNnz0w60bJneiwTT-Y0NRTwPVF0ASdZ7-S_JV4AydlK-ULQpl-cRoMd3wcnnNDi790Am_GYxzW-fwmlxjzTeXGCcMKKnFSiC8BbzjJKL1MYtSzD9MYfVqkeE8iuXrpD8A9gG5yUeuYn77OpLtwCi9W_7hflg=w806-h509-no)

为什么看上去这么绕？

一个对象在被使用时，必然是不能被析构的。这里的`currentActiveChannel->handleEvent`在执行时必须保证`currentActiveChannel`不会被析构，一般小的程序当然不会有这么显而易见的错误。不过对于稍微复杂点的程序是需要考虑的。

TcpConnection是拥有一个Channel的，它负责管理该Channel的生命周期，但是却必须把Channel的裸指针暴露给EventLoop（确切的讲是暴露给Poller），因为Poller需要对Channel的事件进行管理（添加、修改、删除）。

此外，TcpConnection是在TcpServer中创建的，但是连接断开事件是被TcpConnection得知的。TcpConnection需要将TcpServer中存放自己shared_ptr的容器中的对应响删除掉，然后才能析构。为了在TcpServer进行erase时不会将TcpConnection析构，需要使用一定的手段（`shared_from_this`）

而且上面讲到了，TcpConnection的Channel的裸指针暴露给了EventLoop的Poller。根据上图的调用链，不能在使用Channel时将TcpConnection析构，因为TcpConnection析构时，Channel也会被析构，这就造成正在使用一个对象时，它确被析构了，将导致严重的问题。所以muduo使用`queueInLoop`使得TcpConnection的析构点位于使用完channel之后的位置（见EventLoop::loop）。

看来，对于对象的生命期管理有时还是很负责。

下面会继续进行分析。

## TcpConnection::handleClose
```c
void TcpConnection::handleClose()
{
  loop_->assertInLoopThread();
  // we don't close fd, leave it to dtor, so we can find leaks easily.
  setState(kDisconnected); // 设置状态为kDisconnected，表示已断开
  channel_->disableAll();  // 移除注册的事件，使用epoll时是EPOLL_CTL_DEL

  TcpConnectionPtr guardThis(shared_from_this()); // 延长本对象的生命周期，引用计数为2
  
  // 调用用户回调函数
  connectionCallback_(guardThis); // 参数为shared_ptr,保证了 connectionCallback_能安全的使用本对象

  // 调用TcpServer::removeConnection
  // must be the last line
  closeCallback_(guardThis);
}
```
连接断开时，会调用`TcpConnection::handleClose`；接着调用用户回调`connectionCallback_`；最后调用`closeCallback_`，即`TcpServer::removeConnection`(TcpServer创建TcpConnection时设置的)

## TcpServer::removeConnection
```c
void TcpServer::removeConnection(const TcpConnectionPtr& conn)
{
  loop_->runInLoop(boost::bind(&TcpServer::removeConnectionInLoop, this, conn));
}

void TcpServer::removeConnectionInLoop(const TcpConnectionPtr& conn)
{
  loop_->assertInLoopThread();
  LOG_INFO << "TcpServer::removeConnectionInLoop [" << name_
           << "] - connection " << conn->name();

  // 根据conn的name，从map容器中删除，此时引用计数会减1。erase之前引用计数为2（由前面的shared_from_this()保证），所以执行完erase，引用计数变为1
  size_t n = connections_.erase(conn->name());
  assert(n == 1);

  // 然后调用conn->connectDestroyed
  EventLoop* ioLoop = conn->getLoop();
  ioLoop->queueInLoop(
      boost::bind(&TcpConnection::connectDestroyed, conn)); // bind延长了conn的生命期，connectDestroyed完成后，TcpConnection被析构。
  // FIXME wake up ?
}
```


TcpServer先将该conn从map容器中删除，因为erase之前使用了`shared_from_this`,所以erase之前引用计数为2，那么erase之后引用计数将变为1。
如果没用`shared_from_this`，仅仅传递了一个裸指针过来，erase之后引用计数变为0，那么该TcpConnection会被析构！这意味着TcpConnection的Channel也会被析构，可是你现在正在使用该Channel啊（结合上图看），怎么能在使用某个对象的时候把它析构呢，这是严重的错误。所以muduo使用shared_ptr管理TcpConnection，避免了上述问题。

最后`queueInLoop`就是将`TcpConnection::connectDestroyed`函数移动到EventLoop中执行，执行位置就是在`Channel->handleEvent`之后，此时可以安全的析构TcpConnection。（这么做的原因见前面）

注意上面最后的boost::bind,它让TcpConnection的生命期长到调用connectDestroyed的时刻。在`connectDestroyed`执行完之后，TcpConnection才被析构。

## TcpConnection::connectDestroyed
```c
void TcpConnection::connectDestroyed()
{
  loop_->assertInLoopThread();
  if (state_ == kConnected)
  {
    setState(kDisconnected);
    channel_->disableAll();

    connectionCallback_(shared_from_this());
  }

  // 将EventLoop.Poller中的该channel从容器中删除
  loop_->removeChannel(get_pointer(channel_));
}
```

`TcpConnection::connectDestroyed`是该对象析构前调用的最后一个成员函数，它会通知用户连接已经断开。

我已经用了洪荒之力来理解TcpConnection，实在是太绕了。
