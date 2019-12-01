Title: leetcode
Date: 2019-12-01 09:00
Category: leetcode 
Tags: leetcode
Slug: 
Author: hongjin.cao 
Summary: leetcode cpp notes

# 前言

> https://github.com/soulmachine/leetcode

## Remove Duplicates from Sorted Array

> Given a sorted array, remove the duplicates in place such that each element appear only once
and return the new length.
Do not allocate extra space for another array, you must do this in place with constant memory.
For example, Given input array A = [1,1,2],
Your function should return length = 2, and A is now [1,2].

```cpp
int removeDuplicates(int A[], int n) {
  if (n <= 0) return 0;

  int len = 0;
  for (int i = 1; i < n; ++i) {
   if (A[len] != A[i-1]) A[++len] = A[i];
  }
  return len + 1;
}
```

使用c++标准库函数, std::unique std::distance

```cpp
int removeDuplicates(int A[], int n) {
  return std::distance(A, std::unique(A, A + n));
}
```

使用std::upper_bound进一步扩展	

```cpp
int removeDuplicates(int A[], int n) {
  return removeDuplicates(A, A + n, A) - A;
}
template<typename InIt, typename OutIt>
OutIt removeDuplicates(InIt first, InIt last, OutIt output) {
  while (first != last) {
    *output++ = *first;
    first = std::upper_bound(first, last, *first);
  }
  return output;
}
```

