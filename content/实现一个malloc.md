Title: Malloc: a simple implement
Date: 2017-01-06 09:00
Modified: 2017-01-07 09:09:37
Category: Linux
Tags: Memory-Management
Slug: 
Author: hongjin.cao 
Summary: 实现一个简单的malloc


> 原文： http://www.ibm.com/developerworks/cn/linux/l-memory/

> 参考： http://www.geeksforgeeks.org/memory-layout-of-c-program/

# C程序内存布局

C程序的内存布局如下图所示：

![这里写图片描述](http://d1hyf4ir1gqw6c.cloudfront.net//wp-content/uploads/Memory-Layout.gif)

# heap

图中的heap就是堆空间，它的开始位置位于bss段的最后，结束地址可以调用sbrk(0)获取，原文中称这个地址为“系统中断点”。如图所示heap会向高地址扩展。通常我们会使用库函数malloc、free为用户在heap上分配和释放动态内存。而malloc、free在底层是通过sbrk或mmap实现的。

# sbrk & mmap

 > 基于 UNIX 的系统有两个可映射到附加内存中的基本系统调用：
    sbrk： sbrk() 是一个非常简单的系统调用。 还记得系统中断点吗？该位置是进程映射的内存边界。 sbrk() 只是简单地 将这个位置向前或者向后移动，就可以向进程添加内存或者从进程取走内存。
    mmap： mmap()，或者说是“内存映像”，类似于 brk()，但是更为灵活。首先，它可以映射任何位置的内存， 而不单单只局限于进程。其次，它不仅可以将虚拟地址映射到物理的 RAM 或者 swap，它还可以将 它们映射到文件和文件位置，这样，读写内存将对文件中的数据进行读写。不过，在这里，我们只关心 mmap 向进程添加被映射的内存的能力。 munmap() 所做的事情与 mmap() 相反。 
如您所见， brk() 或者 mmap() 都可以用来向我们的 进程添加额外的虚拟内存。在我们的例子中将使用 brk()，因为它更简单，更通用。 

接下来我们来尝试实现自己的malloc和free。

# 实现一个简单的malloc

首先我们定义malloc和free的接口：

```
void * hmalloc(size_t size);
void hfree(void *mem);
```

我们将heap视为一个内存区间，使用[heap_start,heap_end)表示，他们是全局变量：

```
void *heap_start = 0;
void *heap_end = 0;
```
在第一次使用hmalloc时必须对这个区间进行初始化，一开始的可用空间为空。

```c
void hmalloc_init()
{
	heap_start = heap_end = sbrk(0);
}
```
对每块分配的内存，我们需要记录它的一些信息（metadata），如是否被占用、大小等。因此定义每块内存的metadata为：

```c
struct hmem_meta {
	uint8_t is_available; /* 是否可用 */
	size_t size; /* 占用空间大小，包括metadata */
};
```

我们的hmalloc给用户返回的是metadata后的内存区域，当用户调用hfree释放时某个ptr时，只需要给ptr减去metadata的固定偏移大小就可以得到metadata的地址了。因此hfree的实现也很简单：

```c
void hfree(void *mem)
{
	if(!mem) return;

	struct hmem_meta *hmm = mem - sizeof(struct hmem_meta);
	hmm->is_available = 1;
}
```

最后，我们来实现hmalloc吧。我们的分配策略很简单，就是从heap的区间[heap_start,heap_end)中顺序查找。如果没有找到合适的就使用sbrk增加heap的空间。

```c
void * hmalloc(size_t n)
{
	if(!heap_start) hmalloc_init();
	
	n += sizeof(struct hmem_meta);
	
	void *memory_location = NULL;
	void *current_mem = heap_start;
	while(current_mem != heap_end)
	{
		struct hmem_meta *hmm = current_mem;
		if(hmm->is_available && hmm->size >= n)
		{
			hmm->is_available = 0;
			memory_location = current_mem;
			break;
		}
		current_mem += hmm->size;
	}

	if(!memory_location)
	{
		sbrk(n);
		memory_location = heap_end;
		struct hmem_meta *hmm = memory_location;
		hmm->is_available = 0;
		hmm->size = n;
		heap_end += n;
	}
	
	return memory_location + sizeof(struct hmem_meta);
}
```





