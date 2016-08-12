Title: Muduo : TcpConnection's Read Buffer
Date: 2016-08-12 15:00
Modified: 2016-08-12 15:09:37
Category: Muduo 
Tags: Muduo, TcpConnection, Read Buffer
Slug: 
Author: hongjin.cao 
Summary: 分析了muduo输入缓冲的设计，并学习了TCP分包处理。

# 引言

这篇文章分析一下TcpConnection对输入的处理，异步非阻塞网络库是需要输入/输入缓冲区的，这点muduo的作者陈硕在书中7.4.2节已经说的很清楚了。对于输入的处理是`三个半事件`中的又一个重要事件。

# TcpConnection::handleRead
```c
void TcpConnection::handleRead(Timestamp receiveTime)
{
  loop_->assertInLoopThread();
  int savedErrno;
  ssize_t n = inputBuffer_.readFd(channel_->fd(), &savedErrno);
  if (n > 0) // 读到数据，调用用户回调
  {
    messageCallback_(shared_from_this(), &inputBuffer_, receiveTime);
  }
  else if (n == 0)
  {
    handleClose(); // read返回0，断开连接
  }
  else
  {
    // check savedErrno
  }
}
```
当某socketfd可读时`TcpConnection::handleRead`被调用，Timestamp是Poller返回的时间。如果读到了数据（n>0）,就调用用户设置的回调函数。

muduo采用Level Trigger，而不是Edge Trigger。原因作者提到了三点
1. 在文件描述符较少而且活动文件描述符较多时，ET模式不一定比LT高效；
2. LT编程更容易 
3.  读写操作时不必使用循环等候出现`EAGAIN`，这样可以节省系统调用次数，降低延迟。

此外，作者也提到了理想的方式是读操作使用LT、写操作使用ET，但是目前linux不支持。>_<

muduo设计的读操作在有数据时就会调用用户回调函数，并不能直接设置某些条件，比如在收到固定大小的数据时再调用callback。这属于TCP分包的问题，可以通过引入一个间阶层codec来解决。后面会总结。

# Buffer::readFd
```c
ssize_t Buffer::readFd(int fd, int* savedErrno)
{
  // FIXME use ioctl/FIONREAD to tell how much to read
  char extrabuf[65536];
  struct iovec vec[2];
  size_t writable = writableBytes();
  vec[0].iov_base = begin()+writerIndex_;
  vec[0].iov_len = writable;
  vec[1].iov_base = extrabuf;
  vec[1].iov_len = sizeof extrabuf;
  ssize_t n = readv(fd, vec, 2);
  if (n < 0)
  {
    *savedErrno = errno;
  }
  else if (implicit_cast<size_t>(n) <= writable)
  {
    writerIndex_ += n;
  }
  else
  { // 使用了栈上空间，则将它append到buffer后面
    writerIndex_ = buffer_.size();
    append(extrabuf, n - writable);
  }
  return n;
}
```
前面handleRead里面的`inputBuffer_.readFd`函数也是经过精心设计的。利用了`栈上空间` + `readv`实现。这使得输入缓冲区足够大，一次readv就能取完全部数据。这样节省了一个`ioctl(sockfd, FIONREAD, &length)`系统调用（该系统调用用来得知有多少数据可读，然后根据length在buffer中预留出足够的空间）。

# 处理分包

muduo的handleRead只有读到数据就调用用户回调，那么如何实现类似“收到16字节时再调用callback”这样的需求呢？

答案是引入一个间阶层codec。比如我们想在收到16字节数据时再调用我们设置的callback。

可以将回调设置为codec::FixedLengthCodec函数，然后在codec::FixLengthCodec里面做判断，当读到16字节时，在调用我们的回调函数。（呵呵，有点绕）

例如muduo的chat server：
```c
class ChatServer : boost::noncopyable
{
 public:
  ChatServer(EventLoop* loop,
             const InetAddress& listenAddr)
  : loop_(loop),
    server_(loop, listenAddr, "ChatServer"),
    // 设置读到足够数据时的回调为`ChatServer::onStringMessage`
    codec_(boost::bind(&ChatServer::onStringMessage, this, _1, _2, _3))
  {
    server_.setConnectionCallback(
        boost::bind(&ChatServer::onConnection, this, _1));

    // 将数据到达的回调设置为codec::onMessage
    server_.setMessageCallback(
        boost::bind(&LengthHeaderCodec::onMessage, &codec_, _1, _2, _3));
  }

  void start()
  {
    server_.start();
  }

 private:
  void onConnection(const TcpConnectionPtr& conn)
  {
    LOG_INFO << conn->localAddress().toHostPort() << " -> "
        << conn->peerAddress().toHostPort() << " is "
        << (conn->connected() ? "UP" : "DOWN");

    MutexLockGuard lock(mutex_);
    if (conn->connected())
    {
      conn->setContext(Timestamp());
      connections_.insert(conn);
    }
    else
    {
      connections_.erase(conn);
    }
  }

  void onStringMessage(const TcpConnectionPtr&,
                       const string& message,
                       Timestamp)
  {
    MutexLockGuard lock(mutex_);
    for (ConnectionList::iterator it = connections_.begin();
        it != connections_.end();
        ++it)
    {
      codec_.send(get_pointer(*it), message);
    }
  }

  typedef std::set<TcpConnectionPtr> ConnectionList;
  EventLoop* loop_;
  TcpServer server_;
  LengthHeaderCodec codec_;
  MutexLock mutex_;
  ConnectionList connections_;
};
```

codec的定义：
```c
class LengthHeaderCodec : boost::noncopyable
{
 public:
  typedef boost::function<void (const muduo::net::TcpConnectionPtr&,
                                const muduo::string& message,
                                muduo::Timestamp)> StringMessageCallback;

  explicit LengthHeaderCodec(const StringMessageCallback& cb)
    : messageCallback_(cb)
  {
  }

  void onMessage(const muduo::net::TcpConnectionPtr& conn,
                 muduo::net::Buffer* buf,
                 muduo::Timestamp receiveTime)
  {
    muduo::Timestamp& receiveTime_ = boost::any_cast<muduo::Timestamp&>(conn->getContext());
    if (!receiveTime_.valid())
    {
      receiveTime_ = receiveTime;
    }

    if (buf->readableBytes() >= kHeaderLen)
    {
      const void* data = buf->peek();
      int32_t tmp = *static_cast<const int32_t*>(data);
      int32_t len = muduo::net::sockets::networkToHost32(tmp);
      if (len > 65536 || len < 0)
      {
        LOG_ERROR << "Invalid length " << len;
        conn->shutdown();
      }
      else if (buf->readableBytes() >= len + kHeaderLen)
      { // 有足够的数据时，才调用回调函数
        buf->retrieve(kHeaderLen);
        muduo::string message(buf->peek(), len);
        buf->retrieve(len);
        messageCallback_(conn, message, receiveTime_); // 调用回调函数
        receiveTime_ = muduo::Timestamp::invalid();
      }
    }
  }

  void send(muduo::net::TcpConnection* conn, const muduo::string& message)
  {
    muduo::net::Buffer buf;
    buf.append(message.data(), message.size());
    int32_t len = muduo::net::sockets::hostToNetwork32(static_cast<int32_t>(message.size()));
    buf.prepend(&len, sizeof len);
    conn->send(&buf);
  }

 private:
  StringMessageCallback messageCallback_;
  const static size_t kHeaderLen = sizeof(int32_t);
};
```

通过引入codec分包的过程大体上是这样的：

有数据到达时，将数据放到TcpConnection::inputBuffer中，然后调用callback，这里被设置为codec::onMessage，该函数会判断buffer中的数据是否足够16字节，如果够了才调用ChatServer::onStringMessage。

虽然感觉有点绕，但是通信双方可以公用一份codec（两端是同一种语言），可以尽可能的避免分包处理出错。
