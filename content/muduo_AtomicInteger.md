Title: Muduo : AtomicInteger
Date: 2016-07-24 09:00
Modified: 2016-07-24 09:09:37
Category: Muduo 
Tags: Muduo, Atomic, Multithread, Network
Slug: 
Author: hongjin.cao 
Summary: 分析了Muduo中AtomicInteger,即原子整型的实现, 底层使用的是gcc的built-in函数`__sync_fetch_and_add`等。

> https://gcc.gnu.org/onlinedocs/gcc-4.4.3/gcc/Atomic-Builtins.html

> http://blog.csdn.net/huntinux/article/details/51994877

上面这篇文章学习了Linux下的无锁原子操作，使用的是gcc的built-in函数：
```c
// 先获取变量值再改变它
type __sync_fetch_and_add (type *ptr, type value);
type __sync_fetch_and_sub (type *ptr, type value);
type __sync_fetch_and_or (type *ptr, type value);
type __sync_fetch_and_and (type *ptr, type value);
type __sync_fetch_and_xor (type *ptr, type value);
type __sync_fetch_and_nand (type *ptr, type value);

// 先改变变量再获取它
type __sync_add_and_fetch (type *ptr, type value);
type __sync_sub_and_fetch (type *ptr, type value);
type __sync_or_and_fetch (type *ptr, type value);
type __sync_and_and_fetch (type *ptr, type value);
type __sync_xor_and_fetch (type *ptr, type value);
type __sync_nand_and_fetch (type *ptr, type value);

/*
type in each of the expressions can be one of the following:

    int
    unsigned int
    long
    unsigned long
    long long
    unsigned long long
*/

bool __sync_bool_compare_and_swap (type *ptr, type oldval type newval, ...)
type __sync_val_compare_and_swap (type *ptr, type oldval type newval, ...)

/*
这两个函数提供原子的比较和交换，如果*ptr == oldval,就将newval写入*ptr,
第一个函数在相等并写入的情况下返回true.
第二个函数在返回操作之前的值。*/
```
muduo正是使用的这些built-in函数实现了AtomicIntegerT，它是一个类模板。成员变量value_存放数值。muduo封装的Thread类中便使用了该类模板，统计产生了多少个线程。

```c
namespace muduo
{

namespace detail
{
template<typename T>
class AtomicIntegerT : boost::noncopyable
{
 public:
  AtomicIntegerT()
    : value_(0)
  {
  }

  // uncomment if you need copying and assignment
  //
  // AtomicIntegerT(const AtomicIntegerT& that)
  //   : value_(that.get())
  // {}
  //
  // AtomicIntegerT& operator=(const AtomicIntegerT& that)
  // {
  //   getAndSet(that.get());
  //   return *this;
  // }

  T get()
  {
    // in gcc >= 4.7: __atomic_load_n(&value_, __ATOMIC_SEQ_CST)
    return __sync_val_compare_and_swap(&value_, 0, 0); // 如果value_为0，那么将value_设置为0，并返回0
  }

  T getAndAdd(T x)
  {
    // in gcc >= 4.7: __atomic_fetch_add(&value_, x, __ATOMIC_SEQ_CST)
    return __sync_fetch_and_add(&value_, x);
  }

  T addAndGet(T x)
  {
    return getAndAdd(x) + x;
  }

  T incrementAndGet()
  {
    return addAndGet(1);
  }

  T decrementAndGet()
  {
    return addAndGet(-1);
  }

  void add(T x)
  {
    getAndAdd(x);
  }

  void increment()
  {
    incrementAndGet();
  }

  void decrement()
  {
    decrementAndGet();
  }

  T getAndSet(T newValue)
  {
    // in gcc >= 4.7: __atomic_store_n(&value, newValue, __ATOMIC_SEQ_CST)
    return __sync_lock_test_and_set(&value_, newValue); // 返回原值，然后设置成新值newValue
  }

 private:
  volatile T value_;
};
}

typedef detail::AtomicIntegerT<int32_t> AtomicInt32;
typedef detail::AtomicIntegerT<int64_t> AtomicInt64;
}
```

最后使用typedef定义了AtomicInt32和AtomicInt64，方便使用。

C++11中提供了`std::atomic<T>`:
> http://www.cplusplus.com/reference/atomic/atomic/
