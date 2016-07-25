Title: Muduo : Condition 
Date: 2016-07-25 11:00
Modified: 2016-07-25 11:09:37
Category: Muduo 
Tags: Muduo, Multithread, Network, Condition 
Slug: 
Author: hongjin.cao 
Summary: 分析了Muduo中Condition的实现。

> https://github.com/chenshuo/muduo/blob/master/muduo/base/Condition.h

前面分析了互斥锁MutexLock的实现，这里分析一下条件变量Condition的实现。条件变量需要一个互斥锁来保护。关于互斥锁和条件变量的基本用法见[这里](http://blog.csdn.net/huntinux/article/details/51384065)。

## 成员变量
```c
  MutexLock& mutex_;
  pthread_cond_t pcond_;
```
`mutex_`是个引用型变量，用来保护条件变量`pcond_`。

## 构造/析构

```c
  explicit Condition(MutexLock& mutex)
    : mutex_(mutex)
  {
    MCHECK(pthread_cond_init(&pcond_, NULL));
  }
  ~Condition()
  {
    MCHECK(pthread_cond_destroy(&pcond_));
  }
```
构造函数为explicit，必须显示调用。`pcond_`的初始化使用`pthread_cond_init`。析构时使用`pthread_cond_destroy`。都使用MCHECK来检测返回值是否是成功，失败时终止程序。

## 唤醒等待的线程
```
  void notify()
  {
    MCHECK(pthread_cond_signal(&pcond_)); // 通知一个
  }

  void notifyAll()
  {
    MCHECK(pthread_cond_broadcast(&pcond_)); // 通知所有
  }

```

## 进行等待

下面两个函数其实就是对`pthread_cond_wait`和`pthread_cond_timewait`的wrapper。

```c

  void wait()
  {
    MutexLock::UnassignGuard ug(mutex_); 
    MCHECK(pthread_cond_wait(&pcond_, mutex_.getPthreadMutex()));
  }

  // returns true if time out, false otherwise.
  bool waitForSeconds(int seconds);

```
### wait()
```c
  void wait()
  {
    MutexLock::UnassignGuard ug(mutex_); 
    MCHECK(pthread_cond_wait(&pcond_, mutex_.getPthreadMutex()));
  }
```
在执行等待之前，使用UnassignGuard的构造函数将`mutex_`的holder清空（因为当前线程会休眠，暂时失去对`mutex_`的所有权）。接着调用`pthread_cond_wait`等待其他线程的通知。当其他某个线程调用了notify/notifyAll时，当前线程被唤醒，接着在wait返回时，UnassignGuard的析构函数自动将`mutex_`的holder设置为当前线程。

### waitForSeconds()
```
// returns true if time out, false otherwise.
bool muduo::Condition::waitForSeconds(int seconds)
{
  struct timespec abstime;
  // FIXME: use CLOCK_MONOTONIC or CLOCK_MONOTONIC_RAW to prevent time rewind.
  clock_gettime(CLOCK_REALTIME, &abstime);
  abstime.tv_sec += seconds;
  MutexLock::UnassignGuard ug(mutex_);
  return ETIMEDOUT == pthread_cond_timedwait(&pcond_, mutex_.getPthreadMutex(), &abstime);
}
```
waitForSeconds行为与wait类似，只是多了个等待时间。
