Title: Multi-Thread下对int进行原子操作
Date: 2016-07-21 09:00
Modified: 2016-07-21 09:09:37
Category: Multithread 
Tags: Multithread, Atomic Int 
Slug: 
Author: hongjin.cao 
Summary: 学习了多线程环境下如何对int进行原子操作


## 原文链接
这是一系列文章，作者做了详细的讨论。

> http://www.alexonlinux.com/do-you-need-mutex-to-protect-int

> http://www.alexonlinux.com/pthread-spinlocks

> http://www.alexonlinux.com/multithreaded-simple-data-type-access-and-atomic-variables

## 学习总结
作者首先提出了一个问题：是否需要用mutex对int进行protect，对一个int使用mutex或semaphore进行保护开销太大了，然后得出结论是使用spinlock，即自旋锁（busy-wait），比较合适。但是在获取自旋锁时要记得不能进行其他较为耗时的操作。

> Intel x86 and x86_64 processor architectures (as well as vast majority of other modern CPU architectures) has instructions that allow one to lock FSB, while doing some memory access. FSB stands for Front Serial Bus. This is the bus that processor use to communicate with RAM. I.e. locking FSB will prevent from any other processor (core), and process running on that processor, from accessing RAM. And this is exactly what we need to implement atomic variables.
Atomic variables being widely used in kernel, but from some reason no-one bothered to implement them for user-mode folks. Until gcc 4.1.2.

作者提到，Intel x86/x86_64处理器架构有只允许单独锁住FSB的指令。FSB即为Front Serial Bus，处理器使用该总线与RAM交互。某个处理器（记为A）锁住FSB之后，其他处理器，以及在A上运行的进程都不能访问RAM，因此可以使用这一点实现atomic variable。
atomic variable在linux kernel中被广泛使用，但是直到gcc 4.1.2才可以在用户模式下使用。

## 相关函数

这些函数都是built-in函数，不需要包含头文件

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
```

##测试程序

```c
#define _GNU_SOURCE
#include <stdio.h>
#include <pthread.h>
#include <unistd.h>
#include <stdlib.h>
#include <sched.h>
#include <linux/unistd.h>
#include <sys/syscall.h>
#include <errno.h>

#define INC_TO 1000000 // one million...

int global_int = 0;

pid_t gettid( void )
{
	return syscall( __NR_gettid );
}

void *thread_routine( void *arg )
{
	int i;
	int proc_num = (int)(long)arg;
	cpu_set_t set;

	CPU_ZERO( &set );
	CPU_SET( proc_num, &set );

	if (sched_setaffinity( gettid(), sizeof( cpu_set_t ), &set ))
	{
		perror( "sched_setaffinity" );
		return NULL;
	}

	for (i = 0; i < INC_TO; i++)
	{
		// global_int++; // 不使用原子操作，结果是不对的，不过作者指出加上-O2能得到正确结果
		__sync_fetch_and_add( &global_int, 1 );
	}

	return NULL;
}

int main()
{
	int procs = 0;
	int i;
	pthread_t *thrs;

	// Getting number of CPUs
	procs = (int)sysconf( _SC_NPROCESSORS_ONLN );
	if (procs < 0)
	{
		perror( "sysconf" );
		return -1;
	}

	thrs = malloc( sizeof( pthread_t ) * procs );
	if (thrs == NULL)
	{
		perror( "malloc" );
		return -1;
	}

	printf( "Starting %d threads...\n", procs );

	for (i = 0; i < procs; i++)
	{
		if (pthread_create( &thrs[i], NULL, thread_routine,
			(void *)(long)i ))
		{
			perror( "pthread_create" );
			procs = i;
			break;
		}
	}

	for (i = 0; i < procs; i++)
		pthread_join( thrs[i], NULL );

	free( thrs );

	printf( "After doing all the math, global_int value is: %d\n",
		global_int );
	printf( "Expected value is: %d\n", INC_TO * procs );

	return 0;
}
```
编译
```sh
$ gcc -pthread yourfilename
```

程序首先获取处理器个数N，然后创建N个线程分别在N个处理器上运行（原来还可以这么完>_<）。这四个线程都对`global_int`进行加1操作，正确结果应该是1000000×N。如果不进行一些同步控制（mutex、semaphore、spinlock）或使用上面提到的built-in原子操作函数，那么结果是随机的。尽管加上-O2也能得到正确结果，但是还是使用原子操作比较合理。

## 一些细节

```c
for (i = 0; i < procs; i++)
{
  if (pthread_create( &thrs[i], NULL, thread_routine,
	(void *)(long)i ))
  // ...
}
```
注意`pthread_create`传递的最后一个参数是否会出现“竞争”。这里的代码不会出现。因为i是以值传递过去的。
