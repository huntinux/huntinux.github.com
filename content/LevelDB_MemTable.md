Title: LevelDB : MemTable
Date: 2016-06-28 09:00
Modified: 2016-06-28 09:09:37
Category: LevelDB
Tags: LevelDB, MemTable
Slug: 
Author: hongjin.cao 
Summary: 这篇文章分析了LevelDB中的MemTable。总体来说，MemTable是对SkipList的封装，因此理解了SkipList，那么MemTable也不在话下。

#引文
> 1. http://blog.csdn.net/xuqianghit/article/details/6948164
> 2. http://mingxinglai.com/cn/2013/01/leveldb-memtable/

下面是我结合引文的学习记录，仅用于笔记作用，因大部分出自引文，读者可以移步引文进行学习。

#MemTable的作用
以下内容摘自引文2：
>在levelDB中所有KV数据都是存储在Memtable，Immutable Memtable和SSTable中的，Immutable Memtable从结构上讲和Memtable是完全一样的，区别仅仅在于其是只读的，不允许写入操作，而Memtable则是允许写入和读取的。当Memtable写入的数据占用内存到达指定数量，则自动转换为Immutable Memtable，等待Dump到磁盘中，系统会自动生成新的Memtable供写操作写入新数据，理解了Memtable，那么Immutable Memtable自然不在话下。
LevelDb的MemTable提供了将KV数据写入，删除以及读取KV记录的操作接口，但是事实上Memtable并不存在真正的删除操作，删除某个Key的Value在Memtable内是作为插入一条记录实施的，但是会打上一个Key的删除标记，真正的删除操作是Lazy的，会在以后的Compaction过程中去掉这个KV。 需要注意的是，LevelDb的Memtable中KV对是根据Key大小有序存储的，在系统插入新的KV时，LevelDb要把这个KV插到合适的位置上以保持这种Key有序性。其实，LevelDb的Memtable类只是一个接口类，真正的操作是通过背后的SkipList来做的，包括插入操作和读取操作等，所以Memtable的核心数据结构是一个SkipList。

MemTable可以看做是对SkipList的封装。

#成员变量
首先看看MemTable的成员变量：
```c
  typedef SkipList<const char*, KeyComparator> Table;
  KeyComparator comparator_;
  int refs_;    // 引用计数
  Arena arena_; // 内存池
  Table table_; // Table就是SkipList<const char*, KeyComparator>
```

#添加/查询接口
暴露出来的添加、查询接口：
```c
  // Add an entry into memtable that maps key to value at the
  // specified sequence number and with the specified type.
  // Typically value will be empty if type==kTypeDeletion.
  void Add(SequenceNumber seq, ValueType type,
           const Slice& key,
           const Slice& value);

  // If memtable contains a value for key, store it in *value and return true.
  // If memtable contains a deletion for key, store a NotFound() error
  // in *status and return true.
  // Else, return false.
  bool Get(const LookupKey& key, std::string* value, Status* s);
```
##添加
```c
void MemTable::Add(SequenceNumber s, ValueType type,
                   const Slice& key,
                   const Slice& value) {
  // Format of an entry is concatenation of:
  //  key_size     : varint32 of internal_key.size()
  //  key bytes    : char[internal_key.size()]
  //  value_size   : varint32 of value.size()
  //  value bytes  : char[value.size()]
  size_t key_size = key.size();
  size_t val_size = value.size();
  size_t internal_key_size = key_size + 8;
  const size_t encoded_len =
      VarintLength(internal_key_size) + internal_key_size +
      VarintLength(val_size) + val_size;
  char* buf = arena_.Allocate(encoded_len);
  char* p = EncodeVarint32(buf, internal_key_size);
  memcpy(p, key.data(), key_size);
  p += key_size;
  EncodeFixed64(p, (s << 8) | type); // s 和 type 编码成8个字节
  p += 8;
  p = EncodeVarint32(p, val_size);
  memcpy(p, value.data(), val_size);
  assert((p + val_size) - buf == encoded_len);
  table_.Insert(buf); // 插入到SkipList中
}
```
将SequenceNumber, ValueType, key, value编码成一定的格式放在buf中，最后插入到table中。
编码格式为：` | internal_key_size | internal_key |  val_size | value |`
其中internal_key 是由 key，s，type组成的，而s 和 type被编码成8个字节, 所以：internal_key_size = key.size() + 8。编码完成后，将buf插入到table中。

##查询
```c
bool MemTable::Get(const LookupKey& key, std::string* value, Status* s) {
  Slice memkey = key.memtable_key();
  Table::Iterator iter(&table_);
  iter.Seek(memkey.data());
  if (iter.Valid()) {
    // entry format is:
    //    klength  varint32
    //    userkey  char[klength]
    //    tag      uint64
    //    vlength  varint32
    //    value    char[vlength]
    // Check that it belongs to same user key.  We do not check the
    // sequence number since the Seek() call above should have skipped
    // all entries with overly large sequence numbers.
    const char* entry = iter.key();
    uint32_t key_length;
    const char* key_ptr = GetVarint32Ptr(entry, entry+5, &key_length);
    if (comparator_.comparator.user_comparator()->Compare(
            Slice(key_ptr, key_length - 8),
            key.user_key()) == 0) {
      // Correct user key
      const uint64_t tag = DecodeFixed64(key_ptr + key_length - 8);
      switch (static_cast<ValueType>(tag & 0xff)) {
        case kTypeValue: {
          Slice v = GetLengthPrefixedSlice(key_ptr + key_length);
          value->assign(v.data(), v.size());
          return true;
        }
        case kTypeDeletion:
          *s = Status::NotFound(Slice());
          return true;
      }
    }
  }
  return false;
}
```
该函数根据key在table中查找，找到时返回一个迭代器iter，那么entry就指向key（即上面Add函数中的buf）
```c
    const char* entry = iter.key();
```

buf的格式在上面总结过，是这样的：

`| internal_key_size | internal_key |  val_size | value |`

其中我们要查找的key是internal_key的一部分，而internal_key的构成是这样事儿的：

`| key | SequenceNumber | Type |`

其中SequenceNumber和Type被打包成一个8字节组。

那么找到key的过程是这样的：
首先要取出internal_key_size。还记得varint是个边长编码吗？但是varint最长不会超过5字节，所以函数`GetVarint32Ptr`可以从entry的前5个字节解码出internal_key_size。注意，该函数能够处理internal_key_size不足5个字节的情况，原因是：由于varint的编码方式是使用每个字节的第8位表示是否有后续字节，所以该函数可以处理变长的varint。^_^。同时，该函数将返回`internal_key`的首地址。
```c
const char* key_ptr = GetVarint32Ptr(entry, entry+5, &key_length);
```
然后比较要查找的key和找到的key是否相同，其中减去的8字节是上面提到的`SequenceNumber+Type`，它们不参与比较过程：
```c
    if (comparator_.comparator.user_comparator()->Compare(
            Slice(key_ptr, key_length - 8), 
            key.user_key()) == 0) 
    {...}
```

最后，如果Type是`kTypeValue`，那么就返回value部分；如果Type是`kTypeDeletion`，表示该数据被标记为删除类型，返回NotFound。
```c
//获得 SequenceNumber + Type , Type是最后一个字节，即下面的 tag & 0xff。
const uint64_t tag = DecodeFixed64(key_ptr + key_length - 8);
switch (static_cast<ValueType>(tag & 0xff)) {
  case kTypeValue: {
    Slice v = GetLengthPrefixedSlice(key_ptr + key_length);
    value->assign(v.data(), v.size());
    return true;
  }
  case kTypeDeletion:
    *s = Status::NotFound(Slice());
    return true;
}
```

#LookupKey
分析完上面的内容，有疑问如下：

1. 为什么感觉有两次比较过程？一次在`seek()`, 一次在`Compare()`。
原因是这样的： 这要从SkipList说起，还记得SkipList的`FindGreatorOrEqual`函数吗，seek在底层就是使用的该函数，函数返回的是大于或等于要查找值的元素。因此需要再使用Compare比较一下啦。

2. LookupKey是做什么的？ SequenceNumber的作用是什么？
LookupKey是helper类，将用户查询使用的userkey转化为internal_key的表示方式

成员变量：构成是这样的 `| klength | userkey | tag |`
```c
  // We construct a char array of the form:
  //    klength  varint32               <-- start_
  //    userkey  char[klength]          <-- kstart_
  //    tag      uint64
  //                                    <-- end_
  // The array is a suitable MemTable key.
  // The suffix starting with "userkey" can be used as an InternalKey.
  const char* start_;
  const char* kstart_;
  const char* end_;
  char space_[200];      // Avoid allocation for short keys
```
userkey是用户要查找的key，那么LookupKey将userkey转换为内部表示方式：
`| key_length | key | tag |`,其中tag就是SequenceNumber+Type。当key比较短时，使用space_空间，否则在堆上申请，在析构时释放。

构造函数是这样的：
```c
LookupKey::LookupKey(const Slice& user_key, SequenceNumber s) {
  size_t usize = user_key.size();
  size_t needed = usize + 13;  // A conservative estimate
  char* dst;
  if (needed <= sizeof(space_)) { // 决定使用space_还是在堆申请
    dst = space_;
  } else {
    dst = new char[needed];
  }
  start_ = dst;
  dst = EncodeVarint32(dst, usize + 8); // 额外的8字节是给tag使用，即SequenceNumber+Type
  kstart_ = dst;
  memcpy(dst, user_key.data(), usize);
  dst += usize;
  EncodeFixed64(dst, PackSequenceAndType(s, kValueTypeForSeek));
  dst += 8;
  end_ = dst;
}
```
目前，SequenceNumber没有理解，只是感觉和snapshot有关系。

#其他总结
此外，LevelDB中禁止类被复制的方法都是声明`拷贝构造函数`和`赋值操作符`为private，并且只提供声明，而不提供定义。（C++11中可以使用=delete）
