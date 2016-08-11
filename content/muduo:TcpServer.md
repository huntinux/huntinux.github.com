Title: Muduo : TcpServer
Date: 2016-08-11 14:00
Modified: 2016-08-11 14:09:37
Category: Muduo 
Tags: Muduo, TcpServer
Slug: 
Author: hongjin.cao 
Summary: 学习了Muduo的TcpServer的实现。

# 引言

上篇博文学习了`Acceptor` class 的实现，它仅仅是对`Channel和Socket`的简单封装，对使用者来说简单易用。这得益于底层架构Reactor。接下来，开始学习muduo对于建立连接的处理。这属于muduo提到的`三个半事件`中的第一个。可以想想一下，`TcpServer` class应该也是对`Acceptor`，`Poller`的封装。

# 连接处理过程

![这里写图片描述](https://lh3.googleusercontent.com/zDYpgl5on-2BqheH5pa_FplZJRUbTYTeRb6ZY1I-UE5zOTQm7REmkuqzENudsOR55sGSHCs3kkgEqhVW0tEPZHT8grHa9-JstgC7YWfFFHdJVZaNuZ518Uxjm0c5J_akVyPkzMoIj-zlv8uepO5fYHFWVGtLAe1Zxstd5TjZrNCvaRAQMjj1yY1GeItmWpqiFsa1YxkoHMdukRneqz6rz33ZSpnpWbVkoVfbU73Uqkq9ofglFAOtKQ3nE5kSaUO35iNNp0nncyry5n6prjDCdxiByR4Nvn7-DPM2McCDrCVMpHopHHb_MEXpwTT-9P1pHO81kDzl6SsAM7gCJcGT-zlCB1Em5NQWYjCiGC_4hokEhY3P9YEQkqiSgEnuBGFXSxWH8diPAoSNlwfGo4eih4QZyu-6JmMpHjQAKV_Pm-uMQfyqR5S6MOgqtEREycf8QkxMp_TYUz6uHpeJZgmVykvyajRQYlK228uilfqsBhA_xjCyPMHNH7A-jM15Pp0LCS9l92f643NSOwTDrmqScVFsd0C_7x9g0gseAaCkScB1mLRHjDUEkmu_0vE-oWOdmnqHKFvJvuAXHOaVeep9espbgvtISQ=w1029-h460-no)

首先TcpServer通过Acceptor向Poller注册了一个Channel，该Channel关注acceptSocket的readable事件，并设置了回调函数`Acceptor::newConnectionCallback`为`TcpServer::newConnection`

然后，当有client连接时，Poller返回该Channel，接着调用该Channel::handleEvent-->handleRead。在Acceptor中`accept`该连接，然后调用设置好的`Acceptor::newConnectionCallback`,即`TcpServer::newConnection`

接着，对于每个连接，TcpServer会创建一个TcpConnnection来管理。BTW，TcpConnection是最为复杂的一个class，使用shared_ptr管理，因为它的生命周期比较模糊，这一点后面再分析。

最后，会调用`TcpConnnection::connectEstablish`,它会回调用户设置好的回调函数connectionCallback。

（类与类之间通过回调函数联系在了一起）

# 成员变量

```c
 private:
  typedef std::map<string, TcpConnectionPtr> ConnectionMap;

  EventLoop* loop_;  // the acceptor loop
  const string hostport_; // 端口号
  const string name_;     // 名字
  boost::scoped_ptr<Acceptor> acceptor_; // avoid revealing Acceptor
  boost::scoped_ptr<EventLoopThreadPool> threadPool_;
  ConnectionCallback connectionCallback_;
  MessageCallback messageCallback_;
  WriteCompleteCallback writeCompleteCallback_;
  bool started_;
  // always in loop thread
  int nextConnId_;
  ConnectionMap connections_;
```
挑几个重点成员：

- `boost::scoped_ptr<Acceptor> acceptor_`;  这是上篇文章分析的用于接收连接的class，只在TcpServer内部使用，因此使用scoped_ptr管理

- `EventLoop* loop_;`  Reactor的关键class

- `map<string, TcpConnectionPtr> connections_`； 管理TcpConnection的容器，确切的讲应该是TcpServer通过shared_ptr管理TcpConnection（即TcpConnectionPtr），主要是因为TcpConnection拥有模糊的生命周期。muduo网络库的使用这也会使用TcpConnectionPtr作为参数。每个连接有一个唯一的名字，在创建时生成。

# TcpServer::newConnection
```c
void TcpServer::newConnection(int sockfd, const InetAddress& peerAddr)
{
  // 这两句先不用关心
  loop_->assertInLoopThread();
  EventLoop* ioLoop = threadPool_->getNextLoop();

  // 生成唯一的name
  char buf[32];
  snprintf(buf, sizeof buf, ":%s#%d", hostport_.c_str(), nextConnId_);
  ++nextConnId_;
  string connName = name_ + buf;

  LOG_INFO << "TcpServer::newConnection [" << name_
           << "] - new connection [" << connName
           << "] from " << peerAddr.toHostPort();
           
  // 创建一个新的TcpConnection，使用shared_ptr管理
  InetAddress localAddr(sockets::getLocalAddr(sockfd));
  // FIXME poll with zero timeout to double confirm the new connection
  TcpConnectionPtr conn(
      new TcpConnection(ioLoop, connName, sockfd, localAddr, peerAddr)); 
      
  // 将该TcpConnection加入到TcpServer的map容器中
  connections_[connName] = conn;

  // 设置一些回调函数，将用户给TcpServer设置的回调传递给TcpConnection
  conn->setConnectionCallback(connectionCallback_);
  conn->setMessageCallback(messageCallback_);
  conn->setWriteCompleteCallback(writeCompleteCallback_);
  conn->setCloseCallback(
      boost::bind(&TcpServer::removeConnection, this, _1));
  
  // 调用conn->connectEstablished()
  ioLoop->runInLoop(boost::bind(&TcpConnection::connectEstablished, conn));
}
```

具体过程见注释，这就是`三个半事件`中的第一个，比较简单。

# 使用示例

> https://github.com/huntinux/muduo-learn/tree/v0.3

```c
void onConnection(const muduo::net::TcpConnectionPtr& conn)
{
    if(conn->connected()) {
        std::cout << "New connection" << std::endl;
    } else {
        std::cout << "Connection failed" << std::endl;
    }
}

void onMessage(const muduo::net::TcpConnectionPtr& conn,
               muduo::net::Buffer *buffer)
              //const char* data,
              //ssize_t len)
{
    const std::string readbuf = buffer->retrieveAllAsString();
    std::cout << "Receive :" << readbuf.size()<< " bytes." << std::endl
              << "Content:"  << readbuf << std::endl; 
}

int main()
{

    muduo::net::EventLoop loop;
    muduo::net::TcpServer server(&loop, "8090");
    server.setConnectionCallback(onConnection);
    server.setMessageCallback(onMessage);
    server.start();
    loop.loop();
}
```
可以看到TcpServer使用比较方便，只需要设置好相应的回调函数，然后start()。
TcpServer在后台默默地做了很多事情：socket、bind、listen、epoll_wait、accept等等。

此外，示例代码是从muduo源码提取出来的，仅供参考。
