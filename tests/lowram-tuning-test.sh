#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# 512 MB Kindles (PW5 / KT5 / KT6): fixes for "very slow" and "WeChat Read (e-ink) never opens" (user report 2026-11-08,
# reproduced on the KT5 emulator). Static checks so none of them silently disappears.
set -eu
cd "$(dirname "$0")/.."
# 512 MB models (PW5 / KT5 / KT6) run the k49 host
H=host/k49/boot
fail() { echo "FAIL: $*"; exit 1; }
M=$H/lib/memory.sh
grep -q '^heap_fix()' $M || fail "memory.sh: no heap_fix (128m heap -> WeChat Read OutOfMemory)"
grep -q 'heapgrowthlimit=128m\$/dalvik.vm.heapgrowthlimit=256m/' $M || fail "heap_fix does not raise 128m to 256m"
grep -q '^zram_grow()' $M || fail "memory.sh: no zram_grow"
grep -q 'want=$((256 \* 1024 \* 1024))' $M || fail "zram_grow target is not 256 MB"
grep -q 'restored 128MB' $M || fail "zram_grow has no restore path (Kindle must never be left without swap)"
grep -q 'case "$prio" in ""|-\*) prio=100' $M || fail "zram_grow passes a negative priority to swapon -p"
awk '/^zram_on\(\)/,/^}/' $M | grep -q 'heap_fix' || fail "zram_on does not call heap_fix"
awk '/^zram_on\(\)/,/^}/' $M | grep -q 'zram_grow' || fail "zram_on does not call zram_grow"
grep -q 'FW_SERVICES="$FW_SERVICES kppmainapp"' $H/lib/framework.sh || fail "framework.sh: KPPMainApp not stopped on low-RAM models"
grep -q 'if { lowmem ||' $H/lib/framework.sh || fail "framework.sh: KPPMainApp stop not tied to low-memory mode"
grep -q '^lowmem_ram() .*-lt 700000' $H/lib/settings.sh || fail "settings.sh: low-memory mode not limited to < 700 MB"
A=$H/lib/afterboot.sh
grep -q '^lmk_tune()' $A || fail "afterboot.sh: no lmk_tune"
grep -q '^    lmk_tune\( \|$\)' $A || fail "afterboot.sh: lmk_tune never called"
grep -q '2048:0 3072:100 4096:200 8192:300 14336:900 16384:906' $A || fail "lmk thresholds changed"
[ -f tools/src/vdlmk.c ] || fail "tools/src/vdlmk.c missing"
grep -q 'SOCK_SEQPACKET' tools/src/vdlmk.c || fail "vdlmk must use a SEQPACKET socket (lmkd protocol)"
grep -q 'LMK_TARGET 0' tools/src/vdlmk.c || fail "vdlmk: wrong command id"
C=$H/lib/common.sh
grep -q 'e2fsck -p "$SYSTEM_IMG"' $C || fail "common.sh: system image not checked before mount"
n_remount=$(grep -n 'remount,exec /mnt/base-us' $C | head -1 | cut -d: -f1)
n_fbink=$(grep -n 'for f in "$VD/bin/fbink"' $C | head -1 | cut -d: -f1)
[ -n "$n_remount" ] && [ -n "$n_fbink" ] && [ "$n_remount" -lt "$n_fbink" ] || fail "common.sh: fbink is picked before /mnt/base-us is remounted exec"
awk '/^fbink_probe\(\)/,/^}/' $C | grep -q 'if "$f" -e >/dev/null 2>&1; then'  || fail "common.sh: fbink candidates are not test-run"
! grep -q 'heapgrowthlimit=128m' android/device/veradroid/kindle32/veradroid_kindle32.mk || fail "kindle32 product still forces a 128m heap"
# never mount the system image twice (two filesystem instances on one file = corruption, PW3 emulator)
grep -q '^img_loops()' $C || fail "common.sh: no img_loops"
awk '/^storage_mount\(\)/,/^}/' $C | grep -q 'img_loops' || fail "storage_mount does not check for a still-attached loop device"
n_guard=$(awk '/^storage_mount\(\)/,/^}/' $C | grep -n 'img_loops' | head -1 | cut -d: -f1)
n_fsck=$(awk '/^storage_mount\(\)/,/^}/' $C | grep -n 'e2fsck -p' | head -1 | cut -d: -f1)
[ "$n_guard" -lt "$n_fsck" ] || fail "storage_mount runs e2fsck before checking the image is free"
grep -q 'storage_mount || {' $H/veradroid.sh || fail "veradroid.sh ignores a storage_mount failure"
grep -q 'img_free || die' cloud/static/bootstrap.sh || fail "bootstrap: loop_mount can double-mount the image"
for f in $M $A $C $H/lib/framework.sh; do sh -n $f || fail "syntax $f"; done
echo "lowram-tuning-test OK"
