#!/bin/sh
# Host test of the ashmem shim's protection masks (android/device/veradroid/kindle/shim/vdshim.c, tests/ashmem/run.c).
# Regression: GET_PROT_MASK always answered rwx, so Chromium-based WebViews that ship with the app (番茄小说's
# libwebviewbytedance.so) CHECK-failed on every read-only shared memory region ("...wrong protection mask: it is not
# read-only but it should be", SIGTRAP at start; user diagnostics PW6 5.17.1, 2026-11-19) and the app went to its safe mode.
# Needs Linux with gcc and memfd; also runs the /dev/vdshm fallback of 3.0 kernels (legacy line). The shim is built for the host from the same source; only the
# ioctl() prototype differs between bionic and glibc.
set -eu
[ "$(uname -s)" = Linux ] || { echo "SKIP ashmem-prot-test: needs Linux (memfd)"; exit 0; }
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# 发出去的路：宿主开机前装（vdshim_prepare 在 display_prepare 里，命名空间和 chroot 两种模式都走），打包带上，
# 安装器留原版、部件的 vol 里有它（宿主改过镜像里的这个文件，下次增量更新不用下整个镜像）
for h in "$R"/host/*/bin/libvdshim.so; do
    [ -f "$h" ] || continue
    c=${h%/bin/libvdshim.so}/boot/lib/container.sh
    awk '/^display_prepare\(\)/ {p=1} p && /^ *vdshim_prepare$/ {ok=1} p && /^}/ {exit} END {exit !ok}' "$c" || { echo "FAIL $c: display_prepare does not call vdshim_prepare"; exit 1; }
done
sed 's/^int ioctl(int fd, int req, \.\.\.)$/int ioctl(int fd, unsigned long req, ...)/' "$R/android/device/veradroid/kindle/shim/vdshim.c" > "$T/vdshim.c"
grep -q 'unsigned long req' "$T/vdshim.c" || { echo "FAIL: ioctl prototype not found in vdshim.c"; exit 1; }
gcc -O2 -std=gnu99 -Wall -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -o "$T/run" "$T/vdshim.c" "$R/tests/ashmem/run.c"
rc=0
"$T/run" || rc=1
# 老机型 3.0 内核（PW2 / PW3 / Voyage / Oasis 2）没有 memfd_create：区域是 /dev/vdshm 上已删除的文件（0600，宿主建的 tmpfs）。
# 同一份源码，memfd_create 换成不存在的系统调用（ENOSYS）、/dev/vdshm 换成临时目录，再跑一遍同样的检查。
mkdir "$T/vdshm"
sed -e 's#syscall(__NR_memfd_create, "ashmem", VD_MFD_CLOEXEC)#syscall(-1L, "ashmem", VD_MFD_CLOEXEC)#' \
    -e 's#"/dev/vdshm/s%d-%u-%d"#VDSHM_DIR "s%d-%u-%d"#' -e 's#strncmp(l, "/dev/vdshm/", 11)#strncmp(l, VDSHM_DIR, sizeof(VDSHM_DIR) - 1)#' \
    "$T/vdshim.c" > "$T/vdshim30.c"
[ "$(grep -c -e 'syscall(-1L, "ashmem"' -e 'VDSHM_DIR "s%d' -e 'strncmp(l, VDSHM_DIR' "$T/vdshim30.c")" = 3 ] || { echo "FAIL: 3.0 fallback lines not found in vdshim.c"; exit 1; }
gcc -O2 -std=gnu99 -Wall -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 "-DVDSHM_DIR=\"$T/vdshm/\"" -o "$T/run30" "$T/vdshim30.c" "$R/tests/ashmem/run.c"
"$T/run30" > "$T/run30.out" 2>&1 || { sed 's/^/  3.0: /' "$T/run30.out"; rc=1; }
[ -z "$(ls -A "$T/vdshm")" ] || { echo "FAIL 3.0 fallback left files in vdshm: $(ls "$T/vdshm")"; rc=1; }
[ $rc = 0 ] && echo "  3.0 fallback (/dev/vdshm, no memfd): ok"
# every host that ships the shim ships it built from this source
for so in "$R"/host/*/bin/libvdshim.so; do
    [ -f "$so" ] || continue
    grep -q 'vdshim: ashmem prot masks in the file mode' "$so" || { echo "FAIL $so is older than vdshim.c (no prot masks)"; rc=1; }
done
[ $rc = 0 ] && echo "ashmem-prot-test: ok"
exit $rc
