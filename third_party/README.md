# 第三方二进制

| 文件 | 来源 | 许可证 | SHA-256 |
|---|---|---|---|
| `slirp4netns-armv7l-v1.3.7` | https://github.com/rootless-containers/slirp4netns/releases/tag/v1.3.7（官方发布的 armv7l 静态二进制，未修改）| GPL-2.0-or-later（libslirp 为 BSD-3-Clause）| `91b54c16e093208b40e93f8e13bcbaf932016b800895f245c1f62bd711c753f5` |

对应源码：https://github.com/rootless-containers/slirp4netns/archive/refs/tags/v1.3.7.tar.gz ；分发本项目安装包时必须同时提供这个源码链接（GPL 要求），或把源码一起放进包里。

## 老机型的内核模块（安装包 `kmod/`，未入库，GPL-2.0-only / zram 为 Dual BSD/GPL）

| 模块 | 源码 | 构建 |
|---|---|---|
| 3.0.35 `binder.ko`、`zram.ko` | AOSP binder；Amazon 3.0.35 树的 `drivers/staging/zram` | `tools/kmod/build.sh`、`build-binder.sh`、`build-zram.sh` |
| 4.1.15 `<套件>/binder.ko`、`uinput.ko` | 该固件的亚马逊 GPL 包 `Kindle_src_<固件>_<编号>.tar.gz` → `gplrelease/linux-4.1.15.tar.gz`，未改 | `tools/kmod/build-fw.sh` / `build-amazon.sh`（docs/imx41.md §6、§10） |
| 4.1.15 `extra/<套件>/zram.ko`（0.8.14 起，pw4-5151 / kt4-5151 / ko3-5151） | 同上的亚马逊包，`drivers/block/zram/{zram_drv,zcomp,zcomp_lzo}.c` + `mm/zsmalloc.c` 原样；胶水 `tools/kmod/zram41/`（本项目，GPL-2.0） | `tools/kmod/build-zram41.sh`（docs/imx41.md §11，含三个包的 SHA-256） |

亚马逊源码包在 `https://fireos-eink-src.s3.amazonaws.com/` 上（Kindle Source Code Notice 页面的链接），对应源码 = 那个包 + 上面的构建脚本和胶水文件。
