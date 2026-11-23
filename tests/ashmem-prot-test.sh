#!/bin/sh
# Host test of the ashmem shim's protection masks (android/device/veradroid/kindle/shim/vdshim.c, tests/ashmem/run.c).
# Regression: GET_PROT_MASK always answered rwx, so Chromium-based WebViews that ship with the app (番茄小说's
# libwebviewbytedance.so) CHECK-failed on every read-only shared memory region ("...wrong protection mask: it is not
# read-only but it should be", SIGTRAP at start; user diagnostics PW6 5.17.1, 2026-11-19) and the app went to its safe mode.
# Needs Linux with gcc and memfd. The shim is built for the host from the same source; only the
# ioctl() prototype differs between bionic and glibc.
set -eu
[ "$(uname -s)" = Linux ] || { echo "SKIP ashmem-prot-test: needs Linux (memfd)"; exit 0; }
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
sed 's/^int ioctl(int fd, int req, \.\.\.)$/int ioctl(int fd, unsigned long req, ...)/' "$R/android/device/veradroid/kindle/shim/vdshim.c" > "$T/vdshim.c"
grep -q 'unsigned long req' "$T/vdshim.c" || { echo "FAIL: ioctl prototype not found in vdshim.c"; exit 1; }
gcc -O2 -std=gnu99 -Wall -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -o "$T/run" "$T/vdshim.c" "$R/tests/ashmem/run.c"
rc=0
"$T/run" || rc=1
# every host that ships the shim ships it built from this source
for so in "$R"/host/*/bin/libvdshim.so; do
    [ -f "$so" ] || continue
    grep -q 'vdshim: ashmem prot masks in the file mode' "$so" || { echo "FAIL $so is older than vdshim.c (no prot masks)"; rc=1; }
done
[ $rc = 0 ] && echo "ashmem-prot-test: ok"
exit $rc
