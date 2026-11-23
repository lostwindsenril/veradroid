#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Ensure install metadata/backups are consolidated under system/veradroid.
set -u
B=cloud/static/bootstrap.sh
fail=0
grep -q 'STABLE=$SYS/device-id' "$B" || { echo 'FAIL stable path'; fail=1; }
grep -q 'TMP=/mnt/base-us/veradroid/state/install.\$\$' "$B" || { echo 'FAIL temp path'; fail=1; }
grep -q 'INSTALL_LOCK=/mnt/base-us/veradroid/state/install.lock' "$B" || { echo 'FAIL install lock'; fail=1; }
grep -q 'BAK="\$SYS/host.bak' "$B" || { echo 'FAIL host backup path'; fail=1; }
grep -q 'for d in /mnt/base-us/veradroid.bak' "$B" || { echo 'FAIL legacy backup migration'; fail=1; }
grep -q 'veradroid-fullupdate.log' "$B" || { echo 'FAIL legacy log migration'; fail=1; }
grep -q '正在下载 VeraDroid' "$B" || { echo 'FAIL download progress copy'; fail=1; }
grep -q '安装失败（代码' "$B" || { echo 'FAIL failure copy'; fail=1; }
[ "$fail" = 0 ] && echo 'BOOTSTRAP LAYOUT OK' || echo 'BOOTSTRAP LAYOUT FAILURES'
exit "$fail"
