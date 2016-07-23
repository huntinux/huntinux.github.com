Title: Muduo : Thread
Date: 2016-07-23 09:00
Modified: 2016-07-23 09:09:37
Category: Muduo 
Tags: Muduo, Multithread, Network
Slug: 
Author: hongjin.cao 
Summary: 分析了Muduo中Thread的实现。

#预备知识

## __thread (Thread-Local Storage)

> https://gcc.gnu.org/onlinedocs/gcc-3.3.1/gcc/Thread-Local.html

> Thread-local storage (TLS) is a mechanism by which variables are allocated such that there is one instance of the variable per extant thread. The run-time model GCC uses to implement this originates in the IA-64 processor-specific ABI, but has since been migrated to other processors as well. It requires significant support from the linker (ld), dynamic linker (ld.so), and system libraries (libc.so and libpthread.so), so it is not available everywhere. 

 __thread是GCC内置的线程局部存储设施，存取效率可以和全局变量相比。__thread变量每一个线程有一份独立实体，各个线程的值互不干扰。可以用来修饰那些带有全局性且值可能变，但是又不值得用全局变量保护的变量。
 __thread使用规则：只能修饰POD类型(类似整型指针的标量，不带自定义的构造、拷贝、赋值、析构的类型，二进制内容可以任意复制memset,memcpy,且内容可以复原)，不能修饰class类型，因为无法自动调用构造函数和析构函数，可以用于修饰全局变量，函数内的静态变量，不能修饰函数的局部变量或者class的普通成员变量，且__thread变量值只能初始化为编译器常量(值在编译器就可以确定const int i=5,运行期常量是运行初始化后不再改变const int i=rand()).
 
 
# CurrentThread

获取线程id需要进行一次系统调用，为了降低开销，会将第一次获取的线程id保存到线程局部存储中。即`t_cachedTid`。

看过内核代码或LDD的同学应该记得[likely()/unlikely()](https://kernelnewbies.org/FAQ/LikelyUnlikely)。这两个函数是对编译器的提示，告诉编译器哪个分支最有可能为真，编译器因此能正确优化分支转移，提高代码效率。
定义在` include/linux/compiler.h`  :
```c
#define likely(x)       __builtin_expect(!!(x), 1)
#define unlikely(x)     __builtin_expect(!!(x), 0)
```
知道这一点理解tid()就很容易了。

```c
// CurrentThread.h

namespace CurrentThread
{
  __thread int t_cachedTid = 0;
  __thread char t_tidString[32];
  __thread int t_tidStringLength = 6;
  __thread const char* t_threadName = "unknown";
  const bool sameType = boost::is_same<int, pid_t>::value;
  BOOST_STATIC_ASSERT(sameType); // 保证int和pid_t是相同的类型

  void cacheTid();

  inline int tid()
  {
    if (__builtin_expect(t_cachedTid == 0, 0)) // 提示编译器，此条件通常不为真
    {
      cacheTid();
    }
    return t_cachedTid;
  }

  inline const char* tidString() // for logging
  {
    return t_tidString;
  }

  inline int tidStringLength() // for logging
  {
    return t_tidStringLength;
  }

  inline const char* name()
  {
    return t_threadName;
  }

  bool isMainThread();

  void sleepUsec(int64_t usec);
}
}
```

cacheTid()的定义：
```c
void CurrentThread::cacheTid()
{
  if (t_cachedTid == 0)
  {
    t_cachedTid = detail::gettid();
    t_tidStringLength = snprintf(t_tidString, sizeof t_tidString, "%5d ", t_cachedTid);
  }
}
pid_t detail::gettid()
{
  return static_cast<pid_t>(::syscall(SYS_gettid)); // 系统调用，获取tid
}
```
这里是通过系统调用`syscall(SYS_gettid)`获取线程id。这与使用`pthread_self`的返回值是不同的。这篇[文章](http://blog.csdn.net/delphiwcdj/article/details/8476547)有分析。


# ThreadNameInitializer
```c
void afterFork()
{
  muduo::CurrentThread::t_cachedTid = 0;
  muduo::CurrentThread::t_threadName = "main";
  CurrentThread::tid();
  // no need to call pthread_atfork(NULL, NULL, &afterFork);
}

class ThreadNameInitializer
{
 public:
  ThreadNameInitializer()
  {
    muduo::CurrentThread::t_threadName = "main";
    CurrentThread::tid();
    pthread_atfork(NULL, NULL, &afterFork);
  }
};

ThreadNameInitializer init;
```
> 关于pthread_atfork: http://blog.csdn.net/cywosp/article/details/27316803

ThreadNameInitializer进行主线程初始化操作（利用全局变量）：包括设置默认的线程name、缓存线程id。如果进行了fork，那么在子进程中运行`afterFork`函数进行同样的初始化工作。

# Thread

```c
class Thread : boost::noncopyable // 不允许复制
{
 public:
  typedef boost::function<void ()> ThreadFunc;

  explicit Thread(const ThreadFunc&, const string& name = string()); // 必须显示调用
#ifdef __GXX_EXPERIMENTAL_CXX0X__
  explicit Thread(ThreadFunc&&, const string& name = string());
#endif
  ~Thread();

  void start(); // 启动线程
  int join(); // return pthread_join()

  bool started() const { return started_; }
  // pthread_t pthreadId() const { return pthreadId_; }
  pid_t tid() const { return *tid_; }
  const string& name() const { return name_; }

  static int numCreated() { return numCreated_.get(); }

 private:
  void setDefaultName();

  bool       started_;
  bool       joined_;
  pthread_t  pthreadId_;
  boost::shared_ptr<pid_t> tid_;
  ThreadFunc func_;
  string     name_;

  static AtomicInt32 numCreated_; // 记录创建了多少线程
};
```
Thread即有`pthread_t`也有`pid_t`，它们各有用处，`pthread_t`给pthread_XXX函数使用，而`pid_t`作为线程标识。（疑问：直接使用pthread_t作为线程标识不行吗？）

线程的默认name与它是第几个线程相关，std::string 没有format，那么格式化可以使用snprintf，或者使用ostringstream，或者boost::format也是可以的。
```
void Thread::setDefaultName()
{
  int num = numCreated_.incrementAndGet();
  if (name_.empty())
  {
    char buf[32];
    snprintf(buf, sizeof buf, "Thread%d", num);
    name_ = buf;
    //name_ = str(boost::format("Thread%1%") % num); // 使用boost::format
  }
}
```

线程启动函数，调用`pthread_create`创建线程，线程函数为detail::startThread，传递给线程函数的参数data是在heap上分配的，data存放了线程`真正要执行的函数`记为func、线程id、线程name等信息。detail::startThread会调用func启动线程，所以detail::startThread可以看成是一个跳板或中介。
```c
void Thread::start()
{
  assert(!started_); // 确保线程没有启动
  started_ = true;   // 设置标记，线程已经启动
  // FIXME: move(func_)
  detail::ThreadData* data = new detail::ThreadData(func_, name_, tid_);
  if (pthread_create(&pthreadId_, NULL, &detail::startThread, data))
  {
    started_ = false;
    delete data; // or no delete?
    LOG_SYSFATAL << "Failed in pthread_create";
  }
}
```
detail::startThread首先将参数转型为ThreadData*，然后调用data->runInThread()。
```c
void* detail::startThread(void* obj)
{
  ThreadData* data = static_cast<ThreadData*>(obj);
  data->runInThread();
  delete data;
  return NULL;
}
```
runInThread()最终会调用func()。
```c
  void ThreadData::runInThread()
  {
    pid_t tid = muduo::CurrentThread::tid();

    boost::shared_ptr<pid_t> ptid = wkTid_.lock();
    if (ptid)
    {
      *ptid = tid;
      ptid.reset();
    }

    muduo::CurrentThread::t_threadName = name_.empty() ? "muduoThread" : name_.c_str();
    ::prctl(PR_SET_NAME, muduo::CurrentThread::t_threadName); // 设置名字
    try
    {
      func_(); // 调用真正的线程函数
      muduo::CurrentThread::t_threadName = "finished";
    }
    catch (const Exception& ex)
    {
      muduo::CurrentThread::t_threadName = "crashed";
      fprintf(stderr, "exception caught in Thread %s\n", name_.c_str());
      fprintf(stderr, "reason: %s\n", ex.what());
      fprintf(stderr, "stack trace: %s\n", ex.stackTrace());
      abort();
    }
    catch (const std::exception& ex)
    {
      muduo::CurrentThread::t_threadName = "crashed";
      fprintf(stderr, "exception caught in Thread %s\n", name_.c_str());
      fprintf(stderr, "reason: %s\n", ex.what());
      abort();
    }
    catch (...)
    {
      muduo::CurrentThread::t_threadName = "crashed";
      fprintf(stderr, "unknown exception caught in Thread %s\n", name_.c_str());
      throw; // rethrow
    }
  }
```

# ThreadData
```c
struct ThreadData
{
  typedef muduo::Thread::ThreadFunc ThreadFunc;
  ThreadFunc func_;
  string name_;
  boost::weak_ptr<pid_t> wkTid_;

  ThreadData(const ThreadFunc& func,
             const string& name,
             const boost::shared_ptr<pid_t>& tid)
    : func_(func),
      name_(name),
      wkTid_(tid)
  { }
  // ...
```

###线程id

线程id存放在`Thread::tid_`中， 而`tid_`是一个`shared_ptr`。为什么还要使用`shared_ptr`？直接存放成`pid_t`不好吗。

看了ThreadData就明白了，线程id只有在启动的时候才能被确定，需要在ThreadData类中对Thead类中的成员`tid_`做修改，那么使用`shared_ptr`是合适的。ThreadData中的wkTid是一个`weak_ptr`,因为TheadData并不拥有`tid_`。但是`weak_ptr`可以通过`lock()`获取对应的`shared_ptr`, 进而对`Thread::tid_`进行修改。


#一些总结

##为什么不能直接在创建线程的时候执行某个类的成员函数？

因为`pthread_create`的线程函数定义为`void *func(void*)`，无法将non-staic成员函数传递给`pthread_create`。

试想，如果`pthread_create`的线程函数参数定义为`boost::function<void*(void*)>`,那么结合boost::bind，就可以将一个成员函数作为参数了，像这样：
```c
pthread_create(&tid, NULL, boost::bind(&Class::func, &obj, _1), arg);
```
所以boost::function和boost::bind还是挺强大的。在C++11中已经成为标准纳入到std中了。

##指针可以连接C和C++

`pthread_create`, `epoll_event.data.ptr` 都可以用指针来连接C和C++。一般是将某个类的对象的指针传递给这些C-api/C-struct，在使用时进行转型。所以指针还是很重要的。
