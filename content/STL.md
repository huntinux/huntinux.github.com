Title: STL in one article 
Date: 2016-07-07 09:00
Modified: 2016-07-07 09:09:37
Category: C++
Tags: STL 
Slug: 
Author: hongjin.cao 
Summary: A Summary for C++ STL knowledge. 



> 参考书籍：《标准模板库自修教程与参考手册 STL进行C++编程》

# 简介

## 模板参数明确说明

下面的函数模板将字符数组转换为任意的容器。因为只在返回值中用了模板参数，C++规定这种情况必须在函数调用时必须明确说明模板参数类型，否则会编译出错。
```c
template <typename Container>
Container make(const char s[])
{
    return Container(&s[0], &s[strlen(s)]);
}
int main()
{
    char arr[] = "hello world";
    list<int> l = make<list<int>>(arr); // 明确指出模板参数： 此外，这里可以使用auto：  auto l = make<list<int>>(arr); // c++11
    for_each(l.begin(), l.end(), [](int n){cout << static_cast<char>(n) << endl;});
    return 0;
}
```

## 默认模板参数
比如vector的定义,第二个模板参数就指定一个默认值。看来vector使用allocator来管理内存。
如`vector<int> 与 vector<int, std::allocator<int>> `等价。
```c
  template<typename _Tp, typename _Alloc = std::allocator<_Tp> >
    class vector : protected _Vector_base<_Tp, _Alloc>
```

注意：
同一个问题可以使用多种容器来解决，不过哪种容器最合适，需要好好选择，注意性能方面的差异。
STL容器并没有提供过多的操作，而是提供了通用的“类属算法”。比如find，它可以用来在所有的STL容器中进行查找。所以类属算法的特点就在于可以用于许多甚至所有容器上，对于各容器来说，就没有必要定义许多成员函数，从而可以减少并简化容器间的接口。

merge，可以看到该函数能够将不同类型的容器合并，是不是很灵活。
```c
    int narr[] = {1,3,5,7,9};
    vector<int> nvec = {2,4,6,8}; // c++11, 列表初始化
    list<int> nlist;
    merge(narr, narr + 5, nvec.begin(), nvec.end(), back_inserter(nlist)); // nlist为空，所以需要使用back_inserter
    for_each(nlist.begin(), nlist.end(), [](int n){cout << n << endl;}); // c++11, lambda 表达式
```

## 迭代器
![](https://lh3.googleusercontent.com/JWBQ8OzmwPeACDV0EYL33gBqu2UFqm24zeHToTNdWy3hBa41a4Mr1PLTD0fiaIMHxr5uMaPV4lFgnlTrmuPcwMQJrYA16e2VskA3e0URICO1UAhlaqqEFUdjLAOf3PAgTIFa77KQsByU2aojhDtYix9XOARbsem_BS9jXC2sLs-goVgueLTMb50I1aQNWCpsJz3vNorkiY6WTMg7LeepIcIGrzB2MwDGTuYJAm0Sivcuabdaq49ZWa22NIb53tBQrXYQYtEqQCyBmaNv-YPcRkPLiihhDg2kNhi-N_4566ReAW5XIANopi5mMx6tgjUTHlsdfN_6J-ylSzbXuLO6LEKXasGUe-qzhM9nhJ8e-MjbBM4ohr8kSRzLnN_FA_d1mrWfa9v1ruLM8fecYmte_KNxIMQkKayYDIqBtOyknRvv_0k3WlfDtolaqFwoqgspCsdipmLfU9hDiiMgqVwWbsC6EpFB6J24JWvl9FfhbcCMZyRQHEjYAxKssxFpgJB2_h_45uKaSMpfh8yehlyoJ8OwvQood1N39-xrNH1TslO0dGtaWwbiiF8rJd2EqWCVIdmULYBOMFQ8N3pvlFFAA5geaKqr3w=w783-h877-no)


迭代器是“连接”容器和算法等组件的桥梁。STL定义了5种迭代器：输入迭代器，输出迭代器，前向迭代器，双向迭代器，随机访问迭代器。

看看自己实现一个accumulate， 为了与std::accumulate区分，这里的函数名首字母大写。
```c
template <typename InputIterator, typename T>
T Accumulate(InputIterator first, InputIterator last, T init)
{
    while(first != last) {
        init = init + *first;
        ++first;
    }
    return init;
}
```
该函数用到了迭代器的`*`, `++`， `!=` 。

输入迭代器： `*`, 前置/后置`++`， `!=`  `==` 这5个操作是STL对输入迭代器的规定。注意，对于输入迭代器，`*`只能用于读取，不能用于写。
输出迭代器： 与输入迭代器一样，不过`*`只能用于写，不能用于读。
此外还有：前向迭代器、双向迭代器、随机访问迭代器。

对Accumulate进一步抽象,将+抽象为函数对象
```
template <typename InputIterator, typename T, typename BinaryOperation >
T Accumulate(InputIterator first, InputIterator last, T init, BinaryOperation binary_op)
{
    while(first != last) {
        //init = init + *first++;
        init = binary_op(init, *first);
        first++;
    }
    return init;
}
int main()
{
    int narr[] = {1,3,5,7,9};
    cout << Accumulate(narr, narr+5, 1, multiplies<int>()) << endl;
    return 0;
}
```

## 适配器
用来改变其他组件接口的组件称为适配器。

## 组件的互换性

STL中的算法不是用它们操作的数据结构直接定义的。相反，STL算法和容器是通过下面的方式联系起来的：
 
- 对于某种容器，规定了它可以提供哪些类型的迭代器。
- 对于某种算法，规定了它可以使用哪种类型的迭代器。

STL使用迭代器，而不是直接使用数据结构定义算法，从而使得算法可以不依赖数据结构。因此迭代器是关键所在。

## 算法/容器兼容性
理论上，可以让所有STL算法和容器组件都能进行交互，但是STL的设计者们故意没有这么做。因为某些容器在使用某些算法时效率很低。
比如sort，它采用的算法仅在能够随机访问数据的情况下具有较高的效率。数组、vector、dequeu提供对数据的随机访问，而list确不提供。
```c
list<int> l = {4,2,1,8};
sort(l.begin(), l.end()); // error
l.sort(); // ok 

vector<int> v = {1,2,3};
sort(v.begin(), v.end()); // ok
```
将list与sort结合是错误的，为了高效的对list进行排序，list类提供了成员函数sort。

# 迭代器

迭代器是类似指针的对象，STL算法利用它们对存储在容器中的对象序列进行遍历。一个典型的问题是：如何才嫩知道哪种算法和哪种容器能够一起工作？ 理解5种迭代器类型是理解该问题的关键。5种迭代器：输入、输出、前向、双向、随机访问迭代器。
算法通常使用一个迭代器区间 [first, last)，注意它是左闭右开的。
STL将迭代器分为不同类型是为了满足某些特定算法的需求。
请注意，输入迭代器一词不是指某种类型，而是指一系列类型。

输入、输出、前向、双向、随机访问迭代器将上面的图。

迭代器层次结构：
![](https://lh3.googleusercontent.com/_mUkPDKaVOBMmQ_60l1HGQnokv5yrzAimIexlOJ2wY1bY_9J1Yym6SDLFjAGPNWd_JFt6jiw_e9s0s56zUy0oVlKA9ERYI-KSA6sSyXnQCqludzVkqVvccGrrm0am0R_c8pVWqmHj98lgiWthfRf0NoIBQjkoCBpvxilUkK8bM3nWj4udMI_JyNSx9lmRzXGZsPRq3vG-dkmD-cgNhKxXdOqHng3Qs9feG3LMGNVC26KYngpNtPrYEsqHqMF-VFD2v27Z9AAbof7sQIGs-aEaEuVI7RhvVBM9OyRHiGPrtDM8U-VwRd-HtJ6SdsaUNPaR8P3kQcmuY9NxvdpTyz3G7pNMFiCNkYGmKRxl6kgZ3YHShctowMbr_RWt3k2dgNsIE9Rwkq6jo3W0cbzOuBPzqn8Nz7cUEkadWSXd9-YtVRm9hBvj3UCQ62i6emZNo6PCAsM9mcGWyKLPaaTefbX919GXcDfabrvEVj16xk3I74_pRk9UMIvEwm4XBXPR4aFsNBrTO5mD-gaNCsk5wgqomWENi9RI6OgK2O394-CWsFASuqNUm8gQaHoOjgAO4PEUdZvGPCGJs2Q7ZkDgWhIVV5Rr47K3A=w854-h380-no)

![](https://lh3.googleusercontent.com/P0FdfTx5GDJ6s5ULv33OMXF25xXsmo7jfof4tcY0WWRPE-Cm9uAiCSpGZ7nZ5_5xTIhjPLMHcZKk2e0_rS9Qf0saN4CYL3f4bAxU_PKrcgmzVfYQR3VSmPWkHCHlqX25fuwxWPxy-CCJ6Bu284afNRPrrBamw-HqUyk2e2-_N0lmldtF8y-RS6SNsAI8sTJGoOK7A1_yo0qvsGlHSAI2h451rKcvfVschDH3MIdc7-iSWpq0igOYL5wEAkT4PoM1F2xK5w4T9AE5Rjw5rMGQU7a22wDLpkwdY41t9QrxY47FEtZ7O6Ausv70-nmPEIOui5VXITF-vRVE5GZQuWlXOxgHtQ_yCDmthETQBCZhqJKm74lRp9IhvXFmxaE4yoa1Gkk8r-NXYdl1B1a4cuOKGS_muJOakig0VaZT1Piif8Qbp9Gaet5tQvebKb5P2hbft6STS4raiHsz761hYnOl2tk2d9tYH6nRQDV3Wmu8f6BPgPrfB7H5VaHY9l9HXxd03fOGlSylnWWog2bpxwbmTaY9yGSJqUOGh83Xb5btWRHkBMdq6Xv1h2dYZ3v_FAUUiAjuDxGjc2IJW4TrM9R20_3wm3TEeA=w895-h173-no)

## 插入迭代器
通常情况下算法是“改写”模式，而插入迭代器将算法转入到“插入模式”。
3种插入迭代器,它们都是类模板。
```c
back_insert_iterator<Container>  // 对迭代器解引用的赋值操作，使用Container的push_back
front_insert_iterator<Container> // 对迭代器解引用的赋值操作，使用Container的push_front
insert_iterator<Container>       // 对迭代器解引用的赋值操作，使用Container的insert
```
为了使用方便，STL定义了函数模板back_inserter。
```c
vector<int> v;                   // empty
fill_n(v.begin(), 10, 1);        // runtime error
fill_n(back_insert_iterator<vector<int>>(v), 10, 1); // ok
fill_n(back_inserter(v), 10, 1); // ok
```

下面是back_insert_iterator的部分源码，可以看到，该类模板重载了operator=， 是的对迭代器解引用赋值会调用Container的push_back。
```c
      back_insert_iterator&
      operator=(const typename _Container::value_type& __value)
      {
	    container->push_back(__value);
	    return *this;
      }

      back_insert_iterator&
      operator=(typename _Container::value_type&& __value)
      {
	    container->push_back(std::move(__value));
	    return *this;
      }
```
而back_inserter是为了方便使用而定义的，源码如下：
```c
  template<typename _Container>
    inline back_insert_iterator<_Container>
    back_inserter(_Container& __x)
    { return back_insert_iterator<_Container>(__x); }

```
## 流迭代器

- istream_iterator 类， 用于输入
- ostream_iterator 类， 用于输出

诸如merge的一类算法仅仅单方向遍历和读取数据对象，而无需对数据对象赋值，所以可以将这类算法用于输入迭代器。

istream_iterator用法：
```c
    vector<int> vec = {1,2,3,4,5}; // c++11，列表初始化
    list<int> list;
    merge(vec.begin(), vec.end(), 
            istream_iterator<int>(cin),
            istream_iterator<int>(), // 代表输入迭代器结束标志
            back_inserter(list));
```
ostream_iterator用法：
```c
    vector<int> vec = {1,2,3,4};
    list<int> list = {1,2,3,4};
    merge(vec.begin(), vec.end(), list.begin(), list.end(),
            ostream_iterator<int>(cout, " "));
```

可以通过查看算法的定义来确定算法要求使用哪种迭代器。查看merge的定义可以看到它要求前4个参数是输入迭代器，第5个是输出迭代器。
```c
template <class InputIterator1, class InputIterator2, class OutputIterator>
  OutputIterator merge (InputIterator1 first1, InputIterator1 last1,
                        InputIterator2 first2, InputIterator2 last2,
                        OutputIterator result)
```

注意：对于set和multiset，它们的iterator和const_iterator的类型都是**常量**双向迭代器。原因是，对于set和multiset，修改键值的唯一方法是先删除然后再插入（delete---> insert）。对于map和multimap也有类似的限制，`map<Key, T>`对象中存储的类型是`pair<const Key, T>`，其中键的部分不能直接修改，但可以修改值T。


