#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# 把编译产物 root/（ramdisk 内容）和 system/ 合成一个根文件系统 tar.gz，所有文件属主统一为 root。
# 用法：sh mk-rootfs.sh [out目录]   输出：<out目录>/veradroid-rootfs.tar.gz
set -e
OUT=${1:?usage: sh mk-rootfs.sh <out/target/product/kindle>}
STAGE=$OUT/rootfs-stage
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -a "$OUT/root/." "$STAGE/"
cp -a "$OUT/system/." "$STAGE/system/"
for d in data cache mnt storage sdcard dev proc sys; do [ -e "$STAGE/$d" ] || [ -L "$STAGE/$d" ] || mkdir "$STAGE/$d"; done
mkdir -p "$STAGE/storage/emulated/0"
# 2016 年的 AOSP 7.1 根证书太旧（没有 ISRG Root X1 等），很多网站 / 云盘 HTTPS 验证不过：把当前的 Mozilla 根证书补进去（不覆盖已有的）
CA=${CACERTS_EXTRA:-$(dirname "$0")/cacerts-extra}
if [ -d "$CA" ]; then
    for f in "$CA"/*.[0-9]; do
        b=$(basename "$f")
        [ -e "$STAGE/system/etc/security/cacerts/$b" ] || cp "$f" "$STAGE/system/etc/security/cacerts/$b"
    done
fi
# 墨水屏纯阅读器硬件声明（参考文石 Go 6 Gen 2：明确无相机/GPS/NFC/电话基带，避免第三方应用反复探测耗电与报错）
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
UNAVAIL="$SCRIPT_DIR/overlay/system/etc/permissions/veradroid_eink_unavailable_features.xml"
if [ -f "$UNAVAIL" ]; then
    mkdir -p "$STAGE/system/etc/permissions"
    cp "$UNAVAIL" "$STAGE/system/etc/permissions/veradroid_eink_unavailable_features.xml"
    chmod 644 "$STAGE/system/etc/permissions/veradroid_eink_unavailable_features.xml"
fi
# 去掉无硬件串口的蓝牙服务，防止后台每 8 秒死循环重启耗电拖慢系统
rm -rf "$STAGE/system/app/Bluetooth" "$STAGE/system/lib/hw/bluetooth.default.so" "$STAGE/system/etc/permissions/android.hardware.bluetooth.xml"
# 若编译产物包含 OEC / Onyx 墨水屏深度定制类，则自动在 build.prop 标记启用，并补齐文石级 ART 堆回收、白屏启动窗与墨水屏去光晕默认值
BP="$STAGE/system/build.prop"
if [ -f "$BP" ]; then
    grep -q '^ro\.vd\.oec=' "$BP" || printf '\n# VeraDroid e-ink deep customization\nro.vd.oec=2\nro.vd.onyx=1\npersist.vd.splash=1\npersist.vd.no_edge_glow=true\npersist.sys.strictmode.disable=true\ndalvik.vm.heapstartsize=16m\ndalvik.vm.heapminfree=2m\ndalvik.vm.heapmaxfree=16m\ndalvik.vm.heaptargetutilization=0.75\n' >> "$BP"
fi
tar --owner=0 --group=0 --numeric-owner -czf "$OUT/veradroid-rootfs.tar.gz" -C "$STAGE" .
rm -rf "$STAGE"
ls -la "$OUT/veradroid-rootfs.tar.gz"
