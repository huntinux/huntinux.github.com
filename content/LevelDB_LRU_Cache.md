Title: LevelDB : LRU Cache
Date: 2016-06-24 09:00
Modified: 2016-06-24 09:09:37
Category: LevelDB
Tags: LevelDB, LRU Cache, HashTable
Slug: 
Author: hongjin.cao 
Summary: 这篇文章分析了LevelDB中的LRU Cache。实现方式是双向循环链表+HashTable。由于cache中的移动操作频繁，因此使用双向循环链表。而为了弥补双向链表查找性能缺陷，引入hashtable。


> 关于LRU Cache

> 1. http://blog.csdn.net/huntinux/article/details/39290833

> 2. http://www.cnblogs.com/liuhao/archive/2012/11/29/2795455.html

> 3. http://blog.itpub.net/26239116/viewspace-1842049/ （重点参考）

> 4. http://mingxinglai.com/cn/2013/01/leveldb-cache/ (重要参考，建议移步这里)

引文1中给出了LRU cache 的一种实现方式是： 双向链表 + hashtable。由于cache中的移动操作频繁，因此使用双向链表。为了弥补双向链表查找性能缺陷，引入hashtable。读者可以理解了引文1中的简单实现再继续往下看。

#LRUHandle
用来表示哈希表中的元素

```c
// An entry is a variable length heap-allocated structure.  Entries
// are kept in a circular doubly linked list ordered by access time.
struct LRUHandle {
  void* value;
  void (*deleter)(const Slice&, void* value);
  LRUHandle* next_hash; // 作为Hash表中的节点，指向hash值相同的节点（解决hash冲突采用链地址法）
  LRUHandle* next; // 作为Cache中的节点，指向后继
  LRUHandle* prev; // 作为Cache中的节点，指向前驱
  size_t charge;      // TODO(opt): Only allow uint32_t?
  size_t key_length; // key的长度
  uint32_t refs; // 引用计数
  uint32_t hash;      // 哈希值，Hash of key(); used for fast sharding and comparisons
  char key_data[1];   // Beginning of key

  Slice key() const {
    // For cheaper lookups, we allow a temporary Handle object
    // to store a pointer to a key in "value".
    if (next == this) {
      return *(reinterpret_cast<Slice*>(value));
    } else {
      return Slice(key_data, key_length);
    }
  }
};
```
其中比较有意思的是`char key_data[1];`，会有这样的疑问：为什么不直接定义成指针呢？
定义成指针将会占用4字节（32位机器）或8字节（64位机器）的空间，而这样定义只占用1字节空间。而且key_data位于结构体的最后面，可在申请内存时，申请足够多的空间。
往下面看会看到这句：
```c
  LRUHandle* e = reinterpret_cast<LRUHandle*>(
      malloc(sizeof(LRUHandle)-1 + key.size()));
```
注意在使用malloc申请空间时，`sizeof(LRUHandle)-1`。其中减去的1就是key_data[1]，然后根据key.size()动态申请空间。最后，key_data还是指向这块空间的。看来key_data[1]只是一个占位符。（个人理解）

#哈希表 HandleTable

bucket：桶，哈希表当中有若干bucket，而每个bucket是一个链表，用来存放hash值相同的元素。（所以这里使用的解决“hash冲突”的方法是链表法）

HandleTable中：

- length_ : hash表桶（bucket）的数量
- elems_ : 放入哈希表中元素的个数
当元素个数大于桶的个数时（elems_ > length_ ），就重新hash（rehash），这样hash表平均查找效率为O(1)。（可以与Redis中哈希表的rehash对比一下。）
- list_ : 是一个数组，数组中的每个元素是一个指针，构成链表存储hash值相同的元素。在这里，每个元素的类型是 LRUHandle *

##构造函数
构造函数的初始化列表将桶个数和元素个数设置为0，然后在函数体中进行Resize()，Resize函数对哈希表大小进行调整，然后对所有元素进行rehash。经过resize，哈希表的初始大小为4。
```c
HandleTable() : length_(0), elems_(0), list_(NULL) { Resize(); // 初始大小length_为4}
```
##查找
查找一个元素是否在哈希表中。首先根据该元素的hash值定位到某个hash bucket（是一个链表），然后在链表中顺序查找。最后，如果找到了就返回一个指向该元素的指针。否则返回该桶的最后一个位置的指针。

注意该函数的返回值是一个二级指针，调用这可以使用该指针对其进行修改。

此外，hash值是如何与数组下标联系起来的呢？ 通过 hash & (length -1) ，length为数组大小，并且length是4的倍数（见Resize函数）那么length-1相当于一个mask，与hash做与操作就计算出了该元素在哪个桶了。
```c
  // Return a pointer to slot that points to a cache entry that
  // matches key/hash.  If there is no such cache entry, return a
  // pointer to the trailing slot in the corresponding linked list.
  LRUHandle** FindPointer(const Slice& key, uint32_t hash) {
    // 通过hash定位到某个桶
    LRUHandle** ptr = &list_[hash & (length_ - 1)];
    // 在链表中顺序查找（比对key）
    while (*ptr != NULL &&
           ((*ptr)->hash != hash || key != (*ptr)->key())) {
      ptr = &(*ptr)->next_hash;
    }
    // 返回查找结果
    return ptr;
  }
```

##插入操作
这是将一个元素插入到哈希表的接口。
```c
  LRUHandle* Insert(LRUHandle* h) {
    // 在链表中查找是否有该元素
    LRUHandle** ptr = FindPointer(h->key(), h->hash);
    LRUHandle* old = *ptr;
    // old==NULL表示没有找到，执行插入操作
    // 否则表示找到了相同元素，那么也要用新的代替旧的
    h->next_hash = (old == NULL ? NULL : old->next_hash);
    *ptr = h;
    if (old == NULL) {
      ++elems_; // 元素个数加1
      if (elems_ > length_) {
        // 必要时，调整哈希表大小
        Resize();
      }
    }
    // 返回旧节点，旧节点在外面被释放
    return old;
  }
```

##删除

```c
  LRUHandle* Remove(const Slice& key, uint32_t hash) {
    LRUHandle** ptr = FindPointer(key, hash);
    LRUHandle* result = *ptr;
    if (result != NULL) {
      *ptr = result->next_hash;
      --elems_;
    }
    return result;
  }
```

##Resize (Rehash)
该函数保证桶的个数大于元素的个数。
```c
  void Resize() {
    uint32_t new_length = 4;
    while (new_length < elems_) {
      new_length *= 2;
    }
    // 分派新的桶数组，初始化每个桶为空
    LRUHandle** new_list = new LRUHandle*[new_length];
    memset(new_list, 0, sizeof(new_list[0]) * new_length);
    uint32_t count = 0;

    // 对每个元素，重新计算在新的表中的位置
    for (uint32_t i = 0; i < length_; i++) {
      LRUHandle* h = list_[i];
      while (h != NULL) {
        LRUHandle* next = h->next_hash;
        uint32_t hash = h->hash;
        LRUHandle** ptr = &new_list[hash & (new_length - 1)];
        h->next_hash = *ptr;
        *ptr = h;
        h = next;
        count++;
      }
    }

    assert(elems_ == count); // 确保所有元素都被重新放入了新表中
    delete[] list_; // 删除旧的桶数组
    list_ = new_list; // 让list_指向新的桶数组
    length_ = new_length; // 更新length_
  }
};
```

#LRUCache

一个LRUCache的实现，成员变量介绍：

```c
  // Initialized before use.
  size_t capacity_; // cache的容量

  // mutex_ protects the following state.
  mutable port::Mutex mutex_;
  size_t usage_; // cache已经使用的容量

  // Dummy head of LRU list.
  // lru.prev is newest entry, lru.next is oldest entry.
  LRUHandle lru_; // LRU链表（双向循环链表），按照访问先后进行排序，表头的prev是最近访问的

  HandleTable table_; // 存放节点的哈希表，用于快读查找
```
可以看到，LRUCache就是是通过 双向链表 + hashtable 实现的（理由在最上面）。

##查找
查找操作就是调用前面介绍的哈希表的查找函数。
```c
Cache::Handle* LRUCache::Lookup(const Slice& key, uint32_t hash) {
  MutexLock l(&mutex_);
  // 在哈希表中查找
  LRUHandle* e = table_.Lookup(key, hash);
  if (e != NULL) {
    e->refs++; // 增加引用计数
    // 从cache中移动到最前面（现remove再append）
    LRU_Remove(e); 
    LRU_Append(e);
  }
  return reinterpret_cast<Cache::Handle*>(e);
}

// remove和append只是关于双向链表的操作，比较简单
void LRUCache::LRU_Remove(LRUHandle* e) {
  e->next->prev = e->prev;
  e->prev->next = e->next;
}

void LRUCache::LRU_Append(LRUHandle* e) {
  // Make "e" newest entry by inserting just before lru_
  e->next = &lru_;
  e->prev = lru_.prev;
  e->prev->next = e;
  e->next->prev = e;
}

// 引用计数减一。引用计数变为0时，调用删除器deleter。
void LRUCache::Unref(LRUHandle* e) {
  assert(e->refs > 0);
  e->refs--;
  if (e->refs <= 0) {
    usage_ -= e->charge;
    (*e->deleter)(e->key(), e->value);
    free(e);
  }
} 
```

##插入

```c
Cache::Handle* LRUCache::Insert(
    const Slice& key, uint32_t hash, void* value, size_t charge,
    void (*deleter)(const Slice& key, void* value)) {
  MutexLock l(&mutex_);

  // 由key、hash、value等创建一个新的元素，将被插入到cache中
  LRUHandle* e = reinterpret_cast<LRUHandle*>(
      malloc(sizeof(LRUHandle)-1 + key.size()));
  e->value = value;
  e->deleter = deleter;
  e->charge = charge;
  e->key_length = key.size();
  e->hash = hash;
  e->refs = 2;  // One from LRUCache, one for the returned handle
  memcpy(e->key_data, key.data(), key.size());
  LRU_Append(e);
  usage_ += charge;

  // 哈希表的Insert函数在插入时如果发现有相同元素，则将旧的返回，将新的替换旧的
  // 然后将旧的进行释放
  LRUHandle* old = table_.Insert(e);
  if (old != NULL) {
    LRU_Remove(old);
    Unref(old);
  }

  // 当cache满了，需要移除oldest的元素
  while (usage_ > capacity_ && lru_.next != &lru_) {
    LRUHandle* old = lru_.next;
    LRU_Remove(old);
    table_.Remove(old->key(), old->hash);
    Unref(old);
  }

  return reinterpret_cast<Cache::Handle*>(e);
}
```
设置cache的容量
```c
  // Separate from constructor so caller can easily make an array of LRUCache
  void SetCapacity(size_t capacity) { capacity_ = capacity; }
```
此外，Erase将清空cache，而Prune会移除引用计数为1的元素（即外部没有使用）
```c
void LRUCache::Erase(const Slice& key, uint32_t hash) {
  MutexLock l(&mutex_);
  LRUHandle* e = table_.Remove(key, hash);
  if (e != NULL) {
    LRU_Remove(e);
    Unref(e);
  }
}

void LRUCache::Prune() {
  MutexLock l(&mutex_);
  for (LRUHandle* e = lru_.next; e != &lru_; ) {
    LRUHandle* next = e->next;
    if (e->refs == 1) {
      table_.Remove(e->key(), e->hash);
      LRU_Remove(e);
      Unref(e);
    }
    e = next;
  }
}
```

#SharedLRUCache
> 不错的分析：http://mingxinglai.com/cn/2013/01/leveldb-cache/

SharedLRUCache中有一个LRUCache的数组，SharedLRUCache做的工作就是计算出元素的hash值，然后根据hash值的高4位确定使用哪一个LRUCache，这么做的理由(摘自上面的引文)：
>这是因为levelDB是多线程的，每个线程访问缓冲区的时候都会将缓冲区锁住，为了多线程访问，尽可能快速，减少锁开销，ShardedLRUCache内部有16个LRUCache，查找Key时首先计算key属于哪一个分片，分片的计算方法是取32位hash值的高4位，然后在相应的LRUCache中进行查找，这样就大大减少了多线程的访问锁的开销。

最后，引用引文4中的图作为总结。
![这里写图片描述](http://i.imgur.com/Gtnn06N.jpg)





