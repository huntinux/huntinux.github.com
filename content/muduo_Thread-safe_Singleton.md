Title: Muduo : Thread-Safe Singleton
Date: 2016-07-28 11:00
Modified: 2016-07-28 11:09:37
Category: Muduo 
Tags: Muduo, Multithread, Network, Singleton,  Thread-Safe 
Slug: 
Author: hongjin.cao 
Summary: 分析了Muduo介绍的thread-safe的Singleton的实现，通过`pthread_once`实现。此外本文也总结了其他几种实现Singleton的方法：如`local-static`， `DCL+memory berri`， 以及在C++11中的方法。

# 使用pthread_once
```c
#include <boost/noncopyable.hpp>
#include <pthread.h>

template<typename T>
class Singleton : private boost::noncopyable {

public:
    static T& instance()
    {
        pthread_once(&ponce_, &Singleton::init);
        return *obj_;
    }
private:
    Singleton();
    ~Singleton();
    static void init()
    {
        obj_ = new T();
    }
    static pthread_once_t ponce_;
    static T *obj_;
};

template<typename T>
pthread_once_t Singleton<T>::ponce_ = PTHREAD_ONCE_INIT;

template<typename T>
T* Singleton<T>::obj_ = NULL;
```
如果想定制new，那么需要使用模板特化（template specialization）（EffectiveC++ rule25）

```c
#include <iostream>
struct Foo {
    Foo(int i) : v_(i) {}
    int v_; 
};

// 对类Foo，调用此版本
template<>
void Singleton<Foo>::init()
{
    std::cout << "call this template specialization" << std::endl;
    obj_ = new Foo(0x10);
}

int main()
{
    Foo& f = Singleton<Foo>::instance();
    Foo& f2 = Singleton<Foo>::instance();
    std::cout << &f << std::endl;
    std::cout << &f2 << std::endl;
    return 0;
}
```

# 其他Singleton方法

> http://preshing.com/20130930/double-checked-locking-is-fixed-in-cpp11/
> http://stackoverflow.com/questions/2576022/efficient-thread-safe-singleton-in-c

## local-static
那么使用local-static呢？C++11已经保证local-static是thread-safe的了。所以使用C++11的话，使用local-static也是可以的，而且是跨平台的， 并且有资源释放。
> http://stackoverflow.com/questions/8102125/is-local-static-variable-initialization-thread-safe-in-c11

## DCL ： Double Checked Locked
> http://www.cs.wustl.edu/~schmidt/editorial-3.html
> http://www.cs.umd.edu/~pugh/java/memoryModel/DoubleCheckedLocking.html

### 典型的DCL

> http://www.aristeia.com/Papers/DDJ_Jul_Aug_2004_revised.pdf

```c
static Singleton* instance()
{
    if(obj_ == NULL){ // 1st test
        Lock lock; // auto lock
        if(obj_ == NULL) { // 2nd test
            obj_ = new Singleton;
        }
    } // auto unlock
    return obj_;
}
```
上面的DCL解决了: 
1. 经过第一个new之后，以后的获取操作不用加锁，这是由第一个test保证的（1st test）
2. 防止对此new，由第二个test保证。比如thread1判断obj_为NULL，进入了if的{}，但是在Lock之前，有另外的thread2更快的进入了if并更快的Lock了，那么第二个test能确保只有一个new。

但是还是存在问题的，因为new操作不是原子操作，它由几个步骤构成：
> Step 1: Allocate memory to hold a Singleton object.
Step 2: Construct a Singleton object in the allocated memory.
Step 3: Make pInstance point to the allocated memory.

而编译器有可能将这三个步骤的顺序弄乱（交换2和3的顺序），比如 step1->step3->step2。

那么DCL有可能变成：(step1-> step3-> step2)
```c
static Singleton* instance()
{
    if(obj_ == NULL){
        Lock lock;
        if(obj_ == NULL) {
            //obj_ = new Singleton;
            obj_ =  // step3
                operator new(sizeof(Singleton)); // step1
            new(obj_) Singleton; // step2
        }
    }
    return obj_;
}
```
thread1执行到了step3，此时指针obj_已经不是NULL，但是这是还有没构造好。
thread2有可能就使用了还没有构造好的obj_，很危险！

倒是可以使用使用`memory barrier`阻止编译器改变指令顺序来保证线程安全，但是这么做不是portable的。

```c
Singleton* Singleton::getInstance() {
    Singleton* tmp = m_instance;
    ...                     // insert memory barrier
    if (tmp == NULL) {
        Lock lock;
        tmp = m_instance;
        if (tmp == NULL) {
            tmp = new Singleton;
            ...             // insert memory barrier
            m_instance = tmp;
        }
    }
    return tmp;
}
```
对于C++11下面的文章讨论的比较详细：
http://preshing.com/20130930/double-checked-locking-is-fixed-in-cpp11/

# 总结

- 可以将Singleton的初始化放到程序的开始阶段，这就避免了多线程的问题。

- 使用pthread_once能很好的解决Singleton的thread-safe问题。不过不能跨平台。

- local-static在C++11也是thread-safe的了。感觉是处理直接初始化之外最简单的了。

- 还有 DCL+memory barrier，个人觉得比较复杂。

- 最后C++11中的解决方案见这里：
http://preshing.com/20130930/double-checked-locking-is-fixed-in-cpp11/
