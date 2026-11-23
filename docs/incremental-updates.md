# 增量更新（parts）

目标：中国大陆慢网络下更新不再每次下 ~140 MB 整包。整包、老安装器、离线包完全不变；新东西都是“加在旁边”。

## 服务器上多了什么（发布打包时生成）

和整包放在同一个 releases 目录（线上 app 只服务 `/bundles/<名字>.tar.gz`，所以文件名都以 `.tar.gz` 结尾，与内容编码无关）：

| 文件 | 内容 |
|---|---|
| `veradroid-<系列>-<版本>.parts.tar.gz` | 索引（真正的 tar.gz）：`index`、`rootfs.sums`（目标系统镜像每个文件 / 目录 / 链接的 sha256、权限、属主）、`*.shas` |
| `vdp-<内容 id>.tar.gz` | 部件，**xz** 压缩的 tar（字典 8 MiB，解压只要 ~9 MB 内存）。按内容命名：内容不变的部件跨版本同名，Cloudflare 一直缓存，发布时不用再拷 |

部件：整包每个顶层目录一个（boot / bin / fonts / apks / screensaver / models / user0 / kmod / entries …），`lib`（libandroid_runtime.so），`top`（其余顶层文件）；
系统镜像：`full`（整个镜像 tar.xz）、`vol`（安装器 / 宿主会改的原版文件：VeraHome、VeraIME、libandroid_runtime.so、netd、hwcomposer）、
`delta`（相对之前最近 3 个已发布镜像：新镜像里**内容**不在旧镜像中的文件）。

元数据只加字段（老安装器只读 version / url / sha256 / size，`"parts_url"` 之类的名字也避开了老 `apply_patch` 认的 `patch_*`）：
`"parts":"<索引地址>","parts_sha256":"…","parts_size":N`。publish.sh / publish-legacy.sh 检查索引和每个部件的 sha256，拷进 releases（已有的同名部件必须内容相同），元数据带上这三个字段。

## 设备上怎么装（bootstrap.sh 的 `vd_parts_*`）

1. 下载阶段（Android 可能还在跑，只读）：下索引；给本机已有文件算 sha256——程序目录、系统里的 VeraHome / VeraIME / libandroid_runtime、
   KUAL 扩展、`$SYS/vd-pristine`（上次安装留的原版文件），以及整个已装镜像和 `$SYS/slim-removed`（不跨挂载点）。**不信版本号或记录，按内容认**。
   - 程序目录：一个部件的文件本机全有就从本机拷，否则下载这个部件。组装好的目录逐个文件和索引核对 sha256 + 权限。
   - 系统镜像：缺的内容 ⊆ 什么都不用下 / vol / 某个 delta(+vol) / full，选下载最少的。
2. Android 停下后、动任何东西之前：`cp -al` 旧镜像得到 `$SYS/rootfs.vdnew`（硬链接，不占空间），按 `rootfs.sums` 修：多的删、不对的换、
   缺的从本机其他位置（硬链接）或下载的部件（拷贝）补；然后**整棵树和完整目标逐项核对**（sha256 / 权限 / 属主 / 链接 / 目录）。
   inode 没变的文件复用第 1 步算过的 sha256，所以整个过程只完整算一遍。
3. 之后完全是原来的整包流程（备份、换程序目录、数据目录处理、VeraHome / VeraIME / odex 规则……），只有“解开 rootfs.tar.gz”换成 `mv rootfs.vdnew rootfs`
   （或者 full 时 `xzcat | tar`）。镜像就位后把 vol 那几个原版文件留一份到 `$SYS/vd-pristine/<sha256>`（约 4 MB），下次不用再下。

回退：索引 / 部件下载失败、sha 不对、本机工具缺（sha256sum、xzcat、find、stat、xargs）、组装后的程序目录核对不过、空间不够、部件总量不比整包小 → 整包。
第 2 步组装 / 核对不过 → 下载整个镜像（full，xz）；再失败 → 停下报错（此时什么都还没改）。`VD_PARTS=0` 关掉增量（network.conf 里也可以写）。

## 尺寸（真实 0.89 / 0.90 / 0.91 包）

| | 大小 |
|---|---|
| 整包 gz（线上） | 144.0 MB |
| 全部部件 xz（新装 / 镜像也变时最坏情况） | 12.6 + 96.2 = 108.9 MB |
| 镜像 gz → xz -9e dict 8 MiB / xz -9 (64 MiB) / zstd -19 --long=27 | 128.2 → 96.2 / 93.9 / 104.6 MB |
| 只改了宿主脚本（0.91 → 测试 0.92） | boot 125 KB + top 59 KB + （第一次）vol 1.7 MB |
| 镜像差量 0.89 → 0.90 | 47 个文件，25.2 MB（xz） |
| 镜像差量 0.88 → 0.90 | 85 个文件，36.3 MB |

解压（busybox xzcat，整个镜像 96 MB）：PW6 模拟器 44 s / 峰值 10.5 MB，KT5（512 MB，5.18.2）126 s / 9.5 MB，PW2（256 MB，5.12.2）44 s / 8.8 MB；
gzip 同一镜像分别 29 / 135 / 28 s、< 2 MB（模拟器数字，KT5 那次宿主机负载高）。

zstd 只有 5.20 固件自带，3.0 / 4.1 老机型没有；xz 解码所有机型的 busybox 都有（PW2 5.12.2 的 busybox 1.28 起），所以用 xz。
文件级差量（不是二进制差分）：设备上不需要新程序，也不用把旧镜像的 tar 留在设备上；代价是变了的大文件（boot.oat 等）整个下。

## dalvik-cache 只在镜像变了时清（全包和增量都适用）

以前每次安装都 `rm -rf $SYS/data/dalvik-cache`：重定位的 boot image 换了校验和，所有应用的 odex 作废，只改宿主脚本的更新之后
也要把所有应用重编一遍。现在 `vd_dalvik_decide`：换镜像前后各算一个指纹（system/framework、system/app、system/priv-app 下每个文件的
大小 + 修改时间；修改时间来自镜像 tar，解压和增量组装都保留；slim 挪出去、镜像里确实没有的应用按原路径算回来；VeraHome / VeraIME 不算）。
一样 → 保留缓存，只删 VeraHome / VeraIME 的缓存项（安装器可能换了这两个 APK）；不一样或算不出来 → 照旧整个清
（旧缓存里可能有另一个 Settings.apk 的 dex：任何系统 APK / jar 变了都会让指纹变）。VD_FACTORY=1 照旧清。
