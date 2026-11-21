#!/bin/sh
# In-app system update on image (loop) models, field report (KT6 5.17.1, chroot mode, 1.07 -> 1.10, 2026-11-20):
# 1. every update downloaded the whole 97 MB system image: the host's bind mounts over $SYS/rootfs files (dex2oat / cmd
#    wrappers, alarmfix libandroid_servers.so) hid the image's originals from the parts hashing -> vd_parts_under hashes them
#    through a non-recursive bind of the rootfs (only paths that are mount targets, never data/).
# 2. the system-disk space check ran only after the 20-minute download and the 5-minute backup ("need 600M free 575M",
#    code 21) -> vd_sys_room_early checks before downloading, grows the image online when it can, else stops at once.
# 3. du of the old rootfs walked /proc, data and the documents bind while Android ran -> vd_rootfs_mb (non-recursive bind, -x).
# 4. VeraHome: "更新" shows the live progress card instead of a toast saying Android would exit in a few seconds.
set -eu
cd "$(dirname "$0")/.."
B=cloud/static/bootstrap.sh; J=android/packages/VeraHome/src/com/veradroid/home/SysUpdate.java
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; ck() { if [ "$2" = "$3" ]; then :; else echo "FAIL: $1: got [$3], want [$2]"; fail=1; fi; }
sh -n $B || { echo "FAIL: bootstrap.sh syntax"; exit 1; }
for blk in vd_parts_under vd_sys_room_early; do
    sed -n "/^# BEGIN $blk\$/,/^# END $blk\$/p" $B > $T/$blk.sh
    grep -q "^$blk()" $T/$blk.sh || { echo "FAIL: no $blk block"; exit 1; }
done
vlog() { :; }; vp_step() { :; }; die() { echo "die $DIE_CODE"; return 9; }
. $T/vd_parts_under.sh; . $T/vd_sys_room_early.sh

# --- mount targets under the rootfs (as /proc/mounts shows them in chroot mode, KT6 emulator 5.17.1.0.4)
SYS=/mnt/base-us/system/veradroid
cat > $T/mounts <<EOF
/dev/loop/1 /mnt/base-us/system/veradroid ext4 rw,noatime 0 0
tmpfs /mnt/base-us/system/veradroid/rootfs/system/bin/dex2oat tmpfs rw 0 0
tmpfs /mnt/base-us/system/veradroid/rootfs/system/bin/cmd tmpfs rw 0 0
tmpfs /mnt/base-us/system/veradroid/rootfs/system/lib/libandroid_servers.so tmpfs ro 0 0
/dev/loop/1 /mnt/base-us/system/veradroid/rootfs/data ext4 rw 0 0
/dev/loop/0 /mnt/base-us/system/veradroid/rootfs/data/media/0/KindleLibrary vfat rw 0 0
proc /mnt/base-us/system/veradroid/rootfs/proc proc rw 0 0
tmpfs /mnt/base-us/system/veradroid/rootfs/system/fonts/odd\040name.ttf tmpfs rw 0 0
tmpfs /mnt/base-us/system/veradroid/rootfs.vdnew/system/bin/x tmpfs rw 0 0
EOF
ck "mount targets" "system/bin/dex2oat system/bin/cmd system/lib/libandroid_servers.so proc" "$(VD_PROC_MOUNTS=$T/mounts vd_parts_under_list | tr '\n' ' ' | sed 's/ $//')"
grep -q 'vd_parts_under >> "$PD/src.rootfs"' $B || { echo "FAIL: vd_parts_under not added to the image sources"; fail=1; }
grep -q 'rm -rf "$pu_d"\|rm -rf $pu_d' $B && { echo "FAIL: the under-mount dir must only be rmdir'ed"; fail=1; }
grep -q 'mount --bind "$SYS/rootfs" "$pu_d"' $B || { echo "FAIL: not a non-recursive bind"; fail=1; }

# --- space estimate: same formula as the pre-install check
PARTS=1; PARTS_ROOTFS_GZ=139873280; ck "need, full image part" 600 "$(vd_sys_room_need)"
PARTS_ROOTFS_GZ=1048576; ck "need, image unchanged" 203 "$(vd_sys_room_need)"
PARTS=; size=300000000; ck "need, whole bundle" 629 "$(vd_sys_room_need)"
grep -q 'need_mb=$(( ${rootfs_gz:-150000000} \* 3 / 1048576 + 200 ))' $B || { echo "FAIL: pre-install formula changed: keep vd_sys_room_need in step"; fail=1; }

# --- not a loop model / system disk not mounted: nothing happens
LOOP=0; ck "pw6 (no image)" "" "$(vd_sys_room_early)"
LOOP=1; SYSTEM_IMG=$T/none.img; ck "no image file" "" "$(vd_sys_room_early)"

# --- order: the early check runs before any download, the backup and the late check
ln_early=$(grep -n '^    \[ -n "$PARTS" \] || vd_sys_room_early$' $B | cut -d: -f1)
ln_dl=$(grep -n 'vd_download "$url" "$TMP/bundle.tar.gz"' $B | head -1 | cut -d: -f1)
ln_parts=$(grep -n 'vd_parts_prepare "$json" && PARTS=1' $B | cut -d: -f1)
ln_bk=$(grep -n 'vlog "user backup: ' $B | head -1 | cut -d: -f1)
[ -n "$ln_early" ] && [ "$ln_early" -gt "$ln_parts" ] && [ "$ln_early" -lt "$ln_dl" ] && [ "$ln_early" -lt "$ln_bk" ] \
    || { echo "FAIL: vd_sys_room_early must run after the parts decision and before the download ($ln_parts < $ln_early < $ln_dl)"; fail=1; }
# parts: the program/image parts are downloaded inside vd_parts_prepare -> the early check must also be reached before those
grep -q 'vd_parts_get "$f" "$s" "$z"' $B && {
    awk '/^vd_parts_prepare\(\)/ { inp = 1 } inp && /PARTS=1; vd_sys_room_early; PARTS=/ { e = NR } inp && /vd_parts_get "\$f" "\$s" "\$z"/ { g = NR; exit } END { exit !(e && e < g) }' $B \
        || { echo "FAIL: vd_parts_prepare downloads parts before the early space check"; fail=1; }; }
# old rootfs size: never a plain du of the live rootfs
grep -n 'du -sm "$SYS/rootfs"' $B && { echo "FAIL: plain du of the rootfs (walks /proc, data, documents)"; fail=1; }
grep -q 'old_mb=$(vd_rootfs_mb)' $B || { echo "FAIL: late check does not use vd_rootfs_mb"; fail=1; }
# grow: same lock and state file as storage.sh
grep -q 'vg_lk=$W/resize.lock' $B && grep -q 'ST_LOCK=/dev/shm/veradroid/resize.lock' host/k49/boot/lib/storage.sh || { echo "FAIL: resize lock differs from storage.sh"; fail=1; }
grep -q 'vg_st=/mnt/base-us/veradroid/state/resize.state' $B && grep -q 'ST_STATE=/mnt/base-us/veradroid/state/resize.state' host/k49/boot/lib/storage.sh \
    || { echo "FAIL: resize state file differs from storage.sh"; fail=1; }

# --- VeraHome
grep -q '几秒后会退出 Android' $J && { echo "FAIL: SysUpdate still promises Android exits in a few seconds"; fail=1; }
grep -q 'progress(a, i.latest)' $J && grep -q 'new TaskCards.Update(a, false)' $J || { echo "FAIL: no progress card after 更新"; fail=1; }
grep -q 'if (running()) { progress(a, null); return; }' $J || { echo "FAIL: 检查系统更新 during an update does not show the progress"; fail=1; }

[ $fail = 0 ] && echo "update-room: ok"
exit $fail
