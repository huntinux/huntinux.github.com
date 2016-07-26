Title: Muduo : ThreadPool 
Date: 2016-07-26 11:00
Modified: 2016-07-26 11:09:37
Category: Muduo 
Tags: Muduo, Multithread, Network, ThreadPool 
Slug: 
Author: hongjin.cao 
Summary: 分析了Muduo中ThreadPool的实现。 线程池ThreadPool用到了前面分析的Thread、MutexLock、Condition。ThreadPool可以设置工作线程的数量，并向任务队列放入任务。放入到任务队列中的任务将由某个工作线程执行。

> https://github.com/chenshuo/muduo/blob/master/muduo/base/ThreadPool.h

> https://github.com/chenshuo/muduo/blob/master/muduo/base/ThreadPool.cc

线程池ThreadPool用到了前面分析的Thread、MutexLock、Condition。ThreadPool可以设置工作线程的数量，并向任务队列放入任务。放入到任务队列中的任务将由某个工作线程执行。

# 成员变量

```c
 private:
  mutable MutexLock mutex_; // mutable的，表示在const函数中也可以改变它
  Condition notEmpty_; // 任务队列queue_不为空了，有任务可以执行了，进而唤醒等待的线程
  Condition notFull_;  // 任务队列queue_不满了，有空间可以使用了，进而唤醒等待的线程
  
  string name_;
  Task threadInitCallback_; // 线程初始化函数
  boost::ptr_vector<muduo::Thread> threads_; // 工作线程容器
  std::deque<Task> queue_; // 任务队列
  size_t maxQueueSize_; // 队列最大大小
  bool running_;
```

使用[boost::ptr_vector](http://www.boost.org/doc/libs/1_61_0/libs/ptr_container/doc/ptr_container.html)存放Thead。

每个Task都是`  typedef boost::function<void ()> Task; 所有任务都放到`queue_`中。需要使用条件变量来维护线程将的同步，比如：通知其他线程有任务到来了，可以向任务队列放任务了等等。
`
# 构造/析构
```c
ThreadPool::ThreadPool(const string& nameArg)
  : mutex_(),
    notEmpty_(mutex_),
    notFull_(mutex_),
    name_(nameArg),
    maxQueueSize_(0),
    running_(false)
{
}

ThreadPool::~ThreadPool()
{
  if (running_)
  {
    stop();
  }
}
```
构造函数对成员变量进行初始化（使用初始化列表），没什么可说的。
析构函数会调用stop， 唤醒所有休眠的线程，然后等待所有线程处理完。
```c
void ThreadPool::stop()
{
  { // new scope
  MutexLockGuard lock(mutex_); // ctor of MutexLockGuard will lock mutex_
  running_ = false;
  notEmpty_.notifyAll(); // 唤醒所有休眠的工作线程
  } // dtor of MutexLockGuard will unlock mutex_
  for_each(threads_.begin(),
           threads_.end(),
           boost::bind(&muduo::Thread::join, _1)); // 等待所有工作线程结束
}
```

# 线程池start()

```c
void ThreadPool::start(int numThreads)
{
  assert(threads_.empty());
  running_ = true;
  threads_.reserve(numThreads); // 保证threads_容量至少为numThreads
  for (int i = 0; i < numThreads; ++i)
  {
    // 创建工作线程，线程函数为ThreadPool::runInThread
    char id[32];
    snprintf(id, sizeof id, "%d", i+1);
    threads_.push_back(new muduo::Thread(
          boost::bind(&ThreadPool::runInThread, this), name_+id));
    threads_[i].start();
  }
  if (numThreads == 0 && threadInitCallback_)
  {
    threadInitCallback_();
  }
}
```
参数为线程数量，会创建相应数量的线程，执行体为ThreadPool::runInThread。


```c
void ThreadPool::runInThread()
{
  try
  {
    if (threadInitCallback_) // 如果设置了，就执行它，进行一些初始化设置
    {
      threadInitCallback_();
    }
    while (running_)
    {
      Task task(take()); // 从任务队列取出一个任务，执行它
      if (task)
      {
        task();
      }
    }
  }
  catch (const Exception& ex) // 异常处理
  {
    fprintf(stderr, "exception caught in ThreadPool %s\n", name_.c_str());
    fprintf(stderr, "reason: %s\n", ex.what());
    fprintf(stderr, "stack trace: %s\n", ex.stackTrace());
    abort();
  }
  catch (const std::exception& ex)
  {
    fprintf(stderr, "exception caught in ThreadPool %s\n", name_.c_str());
    fprintf(stderr, "reason: %s\n", ex.what());
    abort();
  }
  catch (...)
  {
    fprintf(stderr, "unknown exception caught in ThreadPool %s\n", name_.c_str());
    throw; // rethrow
  }
}
```
# 获取一个task
```c
ThreadPool::Task ThreadPool::take()
{
  MutexLockGuard lock(mutex_);
  // always use a while-loop, due to spurious wakeup
  while (queue_.empty() && running_)
  {
    notEmpty_.wait(); // 没有任务，则等待（利用条件变量）
  }
  Task task;
  if (!queue_.empty()) // 有任务了，就返回一个任务
  {
    task = queue_.front();
    queue_.pop_front();
    if (maxQueueSize_ > 0)
    {
      notFull_.notify(); // 通知某个等待向队列放入task的线程
    }
  }
  return task;
}
```
条件变量的wait操作使用while包裹，预防“虚假唤醒”（如被其他线程抢占了）。

# 向线程池添加task

```c
void ThreadPool::run(const Task& task)
{
  if (threads_.empty())
  {
    task(); // 如果没有子线程，就在主线程中执行该task
  }
  else
  {
    MutexLockGuard lock(mutex_);
    while (isFull()) // 如果task队列queue_满了，就等待
    {
      notFull_.wait();
    }
    assert(!isFull());

    queue_.push_back(task); // 将任务加入队列
    notEmpty_.notify(); // 通知某个等待从queue_中取task的线程
  }
}
```

# 使用示例

```c

struct Foo {
public:
    void DoWork() {
        std::cout << "run member function in thread:" << CurrentThread::tid() << std::endl;
    }
    void operator() (){
        std::cout << "run functor in thread:" << CurrentThread::tid() << std::endl;
    }
};

void Task1()
{
    std::cout << "function run in thread:"  << CurrentThread::tid() << std::endl;
}


int main()
{
    ThreadPool tp("TestThreadPool");
    tp.setMaxQueueSize(10);

    tp.start(4); // 启动4个工作线程，启动之后，由于任务队列queue_为空，所以所有工作线程都休眠了
    tp.run(Task1); // 放入一个task，会唤醒某个工作线程

    Foo f;
    tp.run(boost::bind(&Foo::DoWork, &f));
    tp.run(f);

    tp.run( [](){ std::cout << "lambda function run in thread:" << CurrentThread::tid() << std::endl; });

    typedef void(*pFunc)();
    pFunc pf = Task1;
    tp.run(pf);
}
```

可以看到，ThreadPool可以很方便的将某个task放到任务队列中，该task会由某个线程执行。task使用boost::function表示，可以方便地将函数指针、普通函数、成员函数（结合boost::bind）、lambda、重载了函数调用运算符‘()’的类的对象（这些统称为可调用对象）放入到任务队列当中，非常方便。
