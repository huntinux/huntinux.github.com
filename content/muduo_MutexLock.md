Title: Muduo : MutexLock
Date: 2016-07-25 09:00
Modified: 2016-07-25 09:09:37
Category: Muduo 
Tags: Muduo, Multithread, Network, MutexLock
Slug: 
Author: hongjin.cao 
Summary: 分析了Muduo中MutexLock的实现。

## 介绍

> https://github.com/chenshuo/muduo/blob/master/muduo/base/Mutex.h

MutexLock是对互斥锁的封装，使用时用作一个类的成员变量，保护另一个常用被互斥访问。

##成员变量
```c
  pthread_mutex_t mutex_;
  pid_t holder_; // 由哪个线程持有
```

## default构造函数：
```c
  MutexLock()
    : holder_(0) // 没有holder thread
  {
    MCHECK(pthread_mutex_init(&mutex_, NULL)); // 对mutex初始化
  }
```
MCHECK的解释在最后，主要用于检查函数返回值是否为成功，失败了就终止程序。

## 加锁、解锁
```c
  void lock()
  {
    MCHECK(pthread_mutex_lock(&mutex_));
    assignHolder();
  }

  void unlock()
  {
    unassignHolder();
    MCHECK(pthread_mutex_unlock(&mutex_));
  }

  pthread_mutex_t* getPthreadMutex() /* non-const */
  {
    return &mutex_;
  }
```
加锁、解锁分别调用`pthread_mutex_lock`和`pthread_mutex_unlock`。其中`getPthreadMutex`返回mutex的指针，可以供pthread中需要mutex*作为参数的函数使用（如`pthread_cond_wait`）。

## UnassignGuard

该类的唯一成员变量是一个MutexLock引用，在构造时将MutexLock的holder清空、析构时将holder设置为当前线程。该类型是RAII型。在muduo::Condition条件变量中用到。
```c
  class UnassignGuard : boost::noncopyable
  {
   public:
    UnassignGuard(MutexLock& owner)
      : owner_(owner)
    {
      owner_.unassignHolder();
    }

    ~UnassignGuard()
    {
      owner_.assignHolder();
    }

   private:
    MutexLock& owner_;
  };
```

## MutexLockGuard
这又是一个RAII型，作为栈上变量使用，在构造时加锁，析构时解锁。
```c
// Use as a stack variable, eg.
// int Foo::size() const
// {
//   MutexLockGuard lock(mutex_);
//   return data_.size();
// }
class MutexLockGuard : boost::noncopyable
{
 public:
  explicit MutexLockGuard(MutexLock& mutex)
    : mutex_(mutex)
  {
    mutex_.lock();
  }

  ~MutexLockGuard()
  {
    mutex_.unlock();
  }

 private:

  MutexLock& mutex_;
};
```

##MCHECK

接下来分析一下MCHECK
```c
#ifdef CHECK_PTHREAD_RETURN_VALUE

#ifdef NDEBUG
__BEGIN_DECLS
extern void __assert_perror_fail (int errnum,
                                  const char *file,
                                  unsigned int line,
                                  const char *function)
    __THROW __attribute__ ((__noreturn__));
__END_DECLS
#endif

#define MCHECK(ret) ({ __typeof__ (ret) errnum = (ret);         \
                       if (__builtin_expect(errnum != 0, 0))    \
                         __assert_perror_fail (errnum, __FILE__, __LINE__, __func__);})

#else  // CHECK_PTHREAD_RETURN_VALUE

#define MCHECK(ret) ({ __typeof__ (ret) errnum = (ret);         \
                       assert(errnum == 0); (void) errnum;})

#endif // CHECK_PTHREAD_RETURN_VALUE
```

如果没有define`CHECK_PTHREAD_RETURN_VALUE`，那么MCHECK是这样事儿的：

```c
#define MCHECK(ret) ({ __typeof__ (ret) errnum = (ret);         \
                       assert(errnum == 0); (void) errnum;})
```

MCHECK就是用来检查返回值的。如果没有成功就退出程序（使用assert）。

### `__typedef__`
其中[`__typedef__`](https://gcc.gnu.org/onlinedocs/gcc/Typeof.html)是gcc的keyword，用来得到参数（参数可以为表达式）的类型。（感觉和C++11的`decltype`好像，而且gcc还有`__auto_type`, 和C++11的`auto`类似）。最后一句`(void) errnum;`没明白有什么作用。


### `__BEGIN_DECLS`
```
/* C++ needs to know that types and declarations are C, not C++.  */
#ifdef	__cplusplus
# define __BEGIN_DECLS	extern "C" {
# define __END_DECLS	}
#else
# define __BEGIN_DECLS
# define __END_DECLS
#endif
```
C++在调用C函数的时候，需要使用`extern "C"`来告诉编译器，这些函数是C函数，在链接时（linkage）按照C的函数命名取查找。（主要原因是C++引入了重载，编译出来的函数名为了区分做了一些修饰(mangled)，而C语言则没有）。使用objdump查看动态链接库中有哪些函数，然后可以使用`c++filt`将一个函数demangled。

> http://stackoverflow.com/questions/1041866/in-c-source-what-is-the-effect-of-extern-c

> extern "C" makes a function-name in C++ have 'C' linkage (compiler does not mangle the name) so that client C code can link to (i.e use) your function using a 'C' compatible header file that contains just the declaration of your function. Your function definition is contained in a binary format (that was compiled by your C++ compiler) that the client 'C' linker will then link to using the 'C' name.
Since C++ has overloading of function names and C does not, the C++ compiler cannot just use the function name as a unique id to link to, so it mangles the name by adding information about the arguments. A C compiler does not need to mangle the name since you can not overload function names in C. When you state that a function has extern "C" linkage in C++, the C++ compiler does not add argument/parameter type information to the name used for linkage.

### `__assert_perror_fail`

> http://osxr.org:8080/glibc/source/assert/assert-perr.c?v=glibc-2.18#0028

该函数定义在glibc中，会打印出错误信息，然后调用abort终止程序。因为它是个C函数所以用`extern "C"`包裹了一下。（其他C的标准头文件应该是自动处理了，不需要手动添加`extern "C"`，可以看`/usr/include/string.h`来验证一下）。

此外，`__builtin_expect`已经在前面的[文章](http://blog.csdn.net/huntinux/article/details/51995913#t2)中学习过，不在赘述。
