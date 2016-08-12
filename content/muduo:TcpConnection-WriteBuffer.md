Title: Muduo : TcpConnection's Write Buffer
Date: 2016-08-12 16:00
Modified: 2016-08-12 16:09:37
Category: Muduo 
Tags: Muduo, TcpConnection, Write Buffer
Slug: 
Author: hongjin.cao 
Summary: 分析了muduo输出缓冲的设计。重点在于何时关注writeable事件，以及写完后移除对writeable的关注，并调用用户回调。此外，还要注意一些错误情况的处理。

# 引言

前面的文章分别分析到了`三个半事件`中的连接建立、连接断开、数据读入，这里分析最后`半个事件`，即发送数据。muduo作者将该事件称为是半个事件是有道理的，因为这里的发送是指将数据放到TCP协议栈的发送缓冲区，由TCP协议栈负责将数据发送到对端，因此称为半个事件。

# 发送数据

发送数据比接收数据更难，因为发送数据是主动的，接收读取数据是被动的。因为muduo采用的是LT模式，因为合适注册writeable事件需要好好考虑。muduo的send函数的策略是这样的，先判断outputBuffer中是否有数据，如果没有那么尝试直接发送数据，如果一次没有发送完就把剩余的数据放到outputBuffer中，并注册writeable事件，以后在handleWrite中发送剩余数据；如果outputBuffer中有数据就不能尝试先发送了，因为会造成数据乱序。

## TcpConnection::send
send函数有3个重载，大体相同，这里只给出一个。
```c
void TcpConnection::send(const void* data, size_t len)
{
  if (state_ == kConnected)
  {
    // 在IO线程执行，保证线程安全
    if (loop_->isInLoopThread())
    {
      sendInLoop(data, len);
    }
    else
    {
      string message(static_cast<const char*>(data), len);
      loop_->runInLoop(
          boost::bind(&TcpConnection::sendInLoop,
                      this,
                      message));
    }
  }
}

void TcpConnection::send(const StringPiece& message)
{
	// ...
}

// FIXME efficiency!!!
void TcpConnection::send(Buffer* buf)
{
	// ...
}

void TcpConnection::sendInLoop(const void* data, size_t len)
{
  loop_->assertInLoopThread();
  ssize_t nwrote = 0;

  // 如果outputBuffer没有数据，就尝试直接发送
  // if no thing in output queue, try writing directly
  if (!channel_->isWriting() && outputBuffer_.readableBytes() == 0)
  {
    nwrote = ::write(channel_->fd(), data, len);
    if (nwrote >= 0)
    {
      if (implicit_cast<size_t>(nwrote) < len)
      {
        LOG_TRACE << "I am going to write more data";
      }
      else if (writeCompleteCallback_)
      { // 一次就发送完了，那么可以调用`writeCompleteCallback`了，很好
        loop_->queueInLoop(boost::bind(writeCompleteCallback_, shared_from_this()));
      }
    }
    else // nwrote < 0
    {
      nwrote = 0;
      if (errno != EWOULDBLOCK)
      {
        LOG_SYSERR << "TcpConnection::sendInLoop";
      }
    }
  }

  assert(nwrote >= 0);
  if (implicit_cast<size_t>(nwrote) < len)
  { // 将剩余的数据添加到outputBuffer
    outputBuffer_.append(static_cast<const char*>(data)+nwrote, len-nwrote);
    // 开始关注writeable事件，剩余的数据在handleWrite中发送
    if (!channel_->isWriting())
    {
      channel_->enableWriting();
    }
  }
}
```

## TcpConnection::handleWrite

```c
void TcpConnection::handleWrite()
{
  loop_->assertInLoopThread();
  if (channel_->isWriting())
  {
    ssize_t n = ::write(channel_->fd(), outputBuffer_.peek(), outputBuffer_.readableBytes());
    if (n > 0)
    {
      outputBuffer_.retrieve(n);
      if (outputBuffer_.readableBytes() == 0)
      { // 发送完了，不再关注writeable事件，调用`writeCompleteCallback`
        channel_->disableWriting();
        if (writeCompleteCallback_)
        {
          loop_->queueInLoop(boost::bind(writeCompleteCallback_, shared_from_this()));
        }
        if (state_ == kDisconnecting)
        {
          shutdownInLoop();
        }
      }
      else
      { // 使用的是LT模式，当可写时，handleWrite会被继续调用
        LOG_TRACE << "I am going to write more data";
      }
    }
    else
    {
      LOG_SYSERR << "TcpConnection::handleWrite";
      abort();  // FIXME
    }
  }
  else
  {
    LOG_TRACE << "Connection is down, no more writing";
  }
}
```

经过muduo的封装，用户需要发送数据时直接把数据交给send就可以了，send没有返回值，muduo在底层会将数据发送完毕，最后调用用户设置好的回调，看来很方便。

可以想一想在发送数据时，client断开连接的情况，handleWrite发现后没有做过多处理(see the last else)，因为handleRead会在read返回0时发现这一点，然后断开连接。
