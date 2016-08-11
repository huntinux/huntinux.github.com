Title: Linux Device Driver 
Date: 2014-01-01 09:00
Modified: 2014-06-08 09:09:37
Category: Linux
Tags: LDD, Driver
Slug: 
Author: hongjin.cao 
Summary: A Summary for Linux Device Driver Development.


# 学习总结

## 学习内核自带的文档

昨天阅读了一下内核中的文档：
README
Documentation/HOWTO
学到了不少东西。知道了一个网站 http://kernelnewbies.org,一些FAQ , 摘录如下

### Code Browsing

#### cscope，tags

原来内核中有生成 cscope和tags的脚本
```sh
make cscope
make tags
```

给make加上V=1，可以看到哪些命令被执行。
```sh
$ make cscope V=1
  /bin/bash linux-2.6.32.63/scripts/tags.sh cscope
.....
+ cscope -b -f cscope.out
```
可以看到调用的是 scripts/tags.sh 这个脚本。

#### find + grep 
查找结构体定义
```sh
find . -name '*.[chS]' | xargs grep -EnH "\W*struct\W+task_struct\W*{"
```

查找函数定义
```sh
find . -name '*.[chS]' | xargs grep -EnH "cdev_init\W*\(struct cdev"
```
#### lxr    （很好的网站）
`http://lxr.oss.org.cn/`

### 编写好的驱动，怎么运行
保证开发板内核/虚拟机内核 与 你编译驱动时的内核版本一样

#### 在开发板上运行
我有个mini2440开发板，一般是在PC上使用交叉编译工具编译好之后，放到开发的文件系统上即可。（文件系统最好用网络文件系统，这样比较方便）

#### 建立一个虚拟机
找一个内核为 2.6.32以下（因为我要以2.6.32为研究对象）的linux发行版本。fedora12是2.6.31。可以编译安装2.6.32内核，然后编写驱动测试。
下载fedora 12:

使用axel应该比wget快点。
```sh
axel -n 6 http://archives.fedoraproject.org/pub/archive/fedora/linux/releases/12/
```

# 学习资料

## LDD3 book

* [英文](http://lwn.net/Kernel/LDD3/)
* [中文](http://oss.org.cn/kernel-book/ldd3/index.html)

## 驱动代码下载
* [kernel 2.6.x](http://examples.oreilly.com/9780596005900/)
* [kernel 3.x](https://github.com/kerneltravel/ldd3-examples-3.x)
* [other](https://github.com/4get/ldd3_examples)

