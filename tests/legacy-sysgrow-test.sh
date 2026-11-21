#!/bin/sh
# Legacy host (host/legacy/boot/lib/sysgrow.sh + storage.sh): start-time offline grow of the system image.
# Runs the real shell functions against a small ext4 image file (needs Linux with e2fsprogs: mke2fs, e2fsck, resize2fs,
# GNU stat / dd / truncate). Kindle storage numbers come from a stubbed df. No device, no root, nothing mounted.
#   sh tests/legacy-sysgrow-test.sh
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
L=host/legacy/boot/lib
for f in $L/sysgrow.sh $L/storage.sh; do sh -n $f || fail "syntax $f"; done
grep -q '\. "$VD/boot/lib/sysgrow.sh"' $L/storage.sh || fail "storage.sh does not source sysgrow.sh"
grep -q 'sg_hook; return 0; }' $L/storage.sh || fail "st_recover: no sysgrow hook on the no-marker path"
grep -q 'sg_low_tick' $L/storage.sh || fail "st_auto_tick: no low-space log"
grep -q 'type sg_premount >/dev/null 2>&1 && sg_premount' $L/common.sh || fail "common.sh storage_mount: no sg_premount hook"
for c in mke2fs e2fsck resize2fs; do command -v $c >/dev/null 2>&1 || [ -x /sbin/$c ] || { echo "SKIP: no $c (run on Linux with e2fsprogs)"; exit 0; }; done
stat -c %s /dev/null >/dev/null 2>&1 || { echo "SKIP: needs GNU stat"; exit 0; }
PATH=$PATH:/sbin:/usr/sbin

T=$(mktemp -d); trap 'rm -rf $T' EXIT
run() { # case-name : runs the rest in a fresh shell with the libs loaded and stubs in place
    name=$1; shift
    cat > $T/case.sh <<EOF
T=$T
VD=$PWD/host/legacy; SYS=$T/mnt; SYSTEM_IMG=$T/veradroid-sys.img; W=$T/w; X=$T/x
mkdir -p \$SYS \$W \$X/ctl $T/state $T/logs
ST_START=1
t() { echo "[t] \$*" >> $T/t.log; }
splash() { echo "\$1" >> $T/splash.log; }
vd_timeout() { s=\$1; shift; timeout "\$s" "\$@"; }
img_loops() { :; }
. $PWD/$L/storage.sh
ST_STATE=$T/state/resize.state; ST_PENDING=$T/state/resize.pending; ST_LAST=$T/state/resize.last
ST_NOTIFY=$T/state/resize.notify; ST_LOG=$T/logs/resize.log; ST_LOCK=$T/lock
SG_CONF=$T/state/sysgrow.conf; SG_AUTO=$T/state/storage.auto; SG_SKIP=$T/state/sysgrow.skip; SG_ILOCK=$T/state/install.lock
st_kfs() { echo msdos; }
# Kindle storage: KT / KF in MB (total / free)
df() { case "\$*" in *base-us*) echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "x \$((KT * 1024)) \$(((KT - KF) * 1024)) \$((KF * 1024)) 50% /mnt/base-us" ;; *) command df "\$@" ;; esac; }
mkdir() { case "\$*" in */mnt/base-us/veradroid/state*) command mkdir -p $T/state ;; *) command mkdir "\$@" ;; esac; }
EOF
    cat >> $T/case.sh
    sh $T/case.sh > $T/out.txt 2>&1 || { cat $T/out.txt; fail "$name"; }
}
mkimg() { # MB : full (non-sparse, like vfat) ext4 image with a 1 MB marker file, filled to leave little free space
    rm -f $T/veradroid-sys.img; dd if=/dev/zero of=$T/veradroid-sys.img bs=1M count=$1 2>/dev/null
    mke2fs -q -F -t ext4 -L VeraDroid $T/veradroid-sys.img || fail "mke2fs"
    head -c 1048576 /dev/urandom > $T/marker
    debugfs -w -R "write $T/marker marker" $T/veradroid-sys.img >/dev/null 2>&1 || fail "debugfs write"
}
md5img() { debugfs -R "cat marker" $T/veradroid-sys.img 2>/dev/null | md5sum | cut -c1-32; }
fsblocks() { dumpe2fs -h $T/veradroid-sys.img 2>/dev/null | sed -n 's/^Block count: *//p'; }
fsbsize() { dumpe2fs -h $T/veradroid-sys.img 2>/dev/null | sed -n 's/^Block size: *//p'; }
fsmb() { echo $(( $(fsblocks) * $(fsbsize) / 1048576 )); }

# 1. small image, room on the Kindle: grows to the target, data intact, fsck clean, notice for the home screen
mkimg 64; M=$(md5img)
run grow <<'EOF'
SG_TARGET=192; SG_LOW=16; SG_MIN_GAIN=16; KT=4000; KF=1500
st_recover
EOF
[ "$(stat -c %s $T/veradroid-sys.img)" = $((192 * 1048576)) ] || fail "grow: file is $(stat -c %s $T/veradroid-sys.img) bytes, want 192 MB"
[ "$(fsmb)" = 192 ] || fail "grow: filesystem is $(fsmb) MB"
e2fsck -f -n $T/veradroid-sys.img >/dev/null 2>&1 || fail "grow: e2fsck not clean afterwards"
[ "$(md5img)" = "$M" ] || fail "grow: marker file changed"
[ ! -f $T/state/resize.state ] || fail "grow: marker left behind"
grep -q '^result=ok' $T/state/resize.last && grep -q '^reason=sysgrow' $T/state/resize.last || fail "grow: resize.last $(cat $T/state/resize.last)"
grep -q '^grown 64 192' $T/state/resize.notify || fail "grow: no notice for VeraHome"
grep -q 'sysgrow e2fsck -f -y rc=0' $T/logs/resize.log || fail "grow: no e2fsck before / after"

# 2. already at the target with free space: nothing happens
cp $T/veradroid-sys.img $T/before.img
run nothing <<'EOF'
SG_TARGET=192; SG_LOW=16; SG_MIN_GAIN=16; KT=4000; KF=1500
st_recover
EOF
cmp -s $T/veradroid-sys.img $T/before.img || fail "nothing: image changed"

# 3. Kindle too full (keep = max(500 MB, 10 %)): no grow, logged once
mkimg 64; cp $T/veradroid-sys.img $T/before.img; rm -f $T/state/*
run nospace <<'EOF'
SG_TARGET=192; SG_LOW=16; SG_MIN_GAIN=16; KT=4000; KF=600
st_recover; st_recover
EOF
cmp -s $T/veradroid-sys.img $T/before.img || fail "nospace: image changed"
[ "$(grep -c 'wants to grow, but kindle has only' $T/logs/resize.log)" = 1 ] || fail "nospace: not logged exactly once"
# keep is 10 % of a big Kindle: 30000 MB total, 3000 MB free -> keep 3000 -> no room
mkimg 64; cp $T/veradroid-sys.img $T/before.img; rm -f $T/state/*
run keep10 <<'EOF'
SG_TARGET=192; SG_LOW=16; SG_MIN_GAIN=16; KT=30000; KF=3000
st_recover
EOF
cmp -s $T/veradroid-sys.img $T/before.img || fail "keep10: grew into the 10 % reserve"

# 4. switched off: sysgrow.conf SYSGROW=0, or the home screen's auto grow off (state/storage.auto = 0)
for off in conf auto; do
    mkimg 64; cp $T/veradroid-sys.img $T/before.img; rm -f $T/state/*
    [ $off = conf ] && echo SYSGROW=0 > $T/state/sysgrow.conf || echo 0 > $T/state/storage.auto
    run off-$off <<'EOF'
SG_TARGET=192; SG_LOW=16; SG_MIN_GAIN=16; KT=4000; KF=1500
st_recover
EOF
    cmp -s $T/veradroid-sys.img $T/before.img || fail "off-$off: image changed"
done
rm -f $T/state/*

# 5. not started by veradroid.sh (stop.sh etc. also source common.sh): never grows
mkimg 64; cp $T/veradroid-sys.img $T/before.img
run nostart <<'EOF'
SG_TARGET=192; SG_LOW=16; SG_MIN_GAIN=16; KT=4000; KF=1500; ST_START=
st_recover
EOF
cmp -s $T/veradroid-sys.img $T/before.img || fail "nostart: image changed"

# 6. resize2fs fails (or is killed by its timeout): file goes back to the old size, filesystem clean, data intact
mkimg 64; M=$(md5img); rm -f $T/state/*
printf '#!/bin/sh\nexit 1\n' > $T/badresize; chmod 755 $T/badresize
run resizefail <<EOF
SG_TARGET=192; SG_LOW=16; SG_MIN_GAIN=16; KT=4000; KF=1500
st_tool() { case "\$1" in resize2fs) echo $T/badresize ;; *) command -v "\$1" ;; esac; }
st_recover
EOF
[ "$(stat -c %s $T/veradroid-sys.img)" = $((64 * 1048576)) ] || fail "resizefail: file not cut back ($(stat -c %s $T/veradroid-sys.img))"
e2fsck -f -n $T/veradroid-sys.img >/dev/null 2>&1 || fail "resizefail: e2fsck not clean"
[ "$(md5img)" = "$M" ] || fail "resizefail: marker changed"
grep -q '^result=failed' $T/state/resize.last || fail "resizefail: not recorded"
[ ! -f $T/state/resize.state ] || fail "resizefail: marker left"

# 7. power cut half-way through the extend (marker phase=extend, file partly longer): next start finishes it
mkimg 64; M=$(md5img); rm -f $T/state/*
dd if=/dev/zero of=$T/veradroid-sys.img bs=1M seek=64 count=40 conv=notrunc 2>/dev/null
printf 'op=grow\nfrom=64\nto=192\nphase=extend\n' > $T/state/resize.state
run cut-extend <<'EOF'
SG_TARGET=192; SG_LOW=16; SG_MIN_GAIN=16; KT=4000; KF=1500
st_recover
EOF
[ "$(fsmb)" = 192 ] || fail "cut-extend: filesystem $(fsmb) MB after recovery"
e2fsck -f -n $T/veradroid-sys.img >/dev/null 2>&1 || fail "cut-extend: e2fsck not clean"
[ "$(md5img)" = "$M" ] || fail "cut-extend: marker changed"
[ ! -f $T/state/resize.state ] || fail "cut-extend: marker left"

# 8. power cut after the extend, before / during resize2fs (phase=resize): next start resizes and checks
mkimg 64; M=$(md5img); rm -f $T/state/*
dd if=/dev/zero of=$T/veradroid-sys.img bs=1M seek=64 count=128 conv=notrunc 2>/dev/null
printf 'op=grow\nfrom=64\nto=192\nphase=resize\n' > $T/state/resize.state
run cut-resize <<'EOF'
SG_TARGET=192; SG_LOW=16; SG_MIN_GAIN=16; KT=4000; KF=1500
st_recover
EOF
[ "$(fsmb)" = 192 ] || fail "cut-resize: filesystem $(fsmb) MB after recovery"
e2fsck -f -n $T/veradroid-sys.img >/dev/null 2>&1 || fail "cut-resize: e2fsck not clean"
[ "$(md5img)" = "$M" ] || fail "cut-resize: marker changed"

# 9. a file that is not a whole number of MB: the last partial MB (filesystem blocks) is not overwritten
rm -f $T/veradroid-sys.img; dd if=/dev/zero of=$T/veradroid-sys.img bs=1k count=$((64 * 1024 + 512)) 2>/dev/null
mke2fs -q -F -t ext4 -b 1024 -L VeraDroid $T/veradroid-sys.img || fail "mke2fs odd"
head -c 1048576 /dev/urandom > $T/marker; debugfs -w -R "write $T/marker marker" $T/veradroid-sys.img >/dev/null 2>&1
M=$(md5img); rm -f $T/state/*
run odd <<'EOF'
SG_TARGET=192; SG_LOW=16; SG_MIN_GAIN=16; KT=4000; KF=1500
st_recover
EOF
e2fsck -f -n $T/veradroid-sys.img >/dev/null 2>&1 || fail "odd: e2fsck not clean"
[ "$(md5img)" = "$M" ] || fail "odd: marker changed"
[ "$(stat -c %s $T/veradroid-sys.img)" = $((192 * 1048576)) ] || fail "odd: file $(stat -c %s $T/veradroid-sys.img)"

# 10. plan: image at the target but almost full -> +512; FAT caps at 4095
run plan <<'EOF'
st_isfat() { return 0; }
ST_IMG=1536 ST_FS_FREE=40 ST_ALLOC=1536 ST_KTOTAL=27000 ST_KFREE=12000
sg_plan; [ "$SG_PLAN" = 2048 ] || { echo "full at target: $SG_PLAN"; exit 1; }
ST_IMG=768 ST_FS_FREE=500 ST_ALLOC=768 ST_KTOTAL=6000 ST_KFREE=3000
sg_plan; [ "$SG_PLAN" = 1536 ] || { echo "small: $SG_PLAN"; exit 1; }
ST_IMG=760 ST_FS_FREE=32 ST_ALLOC=760 ST_KTOTAL=1144 ST_KFREE=177
sg_plan; [ -z "$SG_PLAN" ] && [ "$SG_WHY" = nospace ] || { echo "emulator-sized store must not grow: $SG_PLAN"; exit 1; }
ST_IMG=4000 ST_FS_FREE=20 ST_ALLOC=4000 ST_KTOTAL=27000 ST_KFREE=12000
sg_plan; [ -z "$SG_PLAN" ] || { echo "FAT 4 GB cap: $SG_PLAN"; exit 1; }
ST_IMG=1536 ST_FS_FREE=900 ST_ALLOC=1536 ST_KTOTAL=27000 ST_KFREE=12000
sg_plan; [ -z "$SG_PLAN" ] && [ "$SG_WHY" = enough ] || { echo "big enough: $SG_PLAN"; exit 1; }
EOF

# 11. low-space log from the watchdog: once, then again only after recovering
run low <<'EOF'
df() { echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "x 760000 700000 $((FREE * 1024)) 90% /x"; }
FREE=40; sg_low_tick; sg_low_tick; FREE=120; sg_low_tick; FREE=200; sg_low_tick; FREE=30; sg_low_tick
[ "$(grep -c 'low: system disk has only' $ST_LOG)" = 2 ] || { cat $ST_LOG; exit 1; }
EOF
# 12. install lock: a live installer holds it -> no grow; during our grow we hold it (phase sysgrow); released afterwards
mkimg 64; cp $T/veradroid-sys.img $T/before.img; rm -rf $T/state/*
sleep 300 & SP=$!
mkdir -p $T/state/install.lock; echo $SP > $T/state/install.lock/pid; cat /proc/sys/kernel/random/boot_id > $T/state/install.lock/boot; echo download > $T/state/install.lock/phase
run ilock-busy <<'EOF2'
SG_TARGET=192; SG_LOW=16; SG_MIN_GAIN=16; KT=4000; KF=1500
st_recover
EOF2
kill $SP 2>/dev/null
cmp -s $T/veradroid-sys.img $T/before.img || fail "ilock-busy: grew while an installer runs"
grep -q 'an installer is running' $T/logs/resize.log || fail "ilock-busy: not logged"
[ "$(cat $T/state/install.lock/pid)" = $SP ] || fail "ilock-busy: touched the installer's lock"
rm -rf $T/state/*
printf '#!/bin/sh\ncat %s/state/install.lock/phase > %s/phase.seen\nexec resize2fs "$@"\n' $T $T > $T/spyresize; chmod 755 $T/spyresize
mkdir -p $T/state/install.lock; echo 99999999 > $T/state/install.lock/pid; echo stale > $T/state/install.lock/boot
run ilock-held <<EOF2
SG_TARGET=192; SG_LOW=16; SG_MIN_GAIN=16; KT=4000; KF=1500
st_tool() { case "\$1" in resize2fs) echo $T/spyresize ;; *) command -v "\$1" ;; esac; }
st_recover
EOF2
[ "$(cat $T/phase.seen 2>/dev/null)" = sysgrow ] || fail "ilock-held: install lock not held during resize2fs ($(cat $T/phase.seen 2>/dev/null))"
[ ! -d $T/state/install.lock ] || fail "ilock-held: install lock left behind"
[ "$(fsmb)" = 192 ] || fail "ilock-held: not grown over a stale lock"

# 13. premount: image left mounted by the installer -> unmounted only when nothing runs; never while starting / running / nested mounts
for c in free starting running nested off; do
    rm -rf $T/state/* $T/w/*; rm -f $T/umounted
    run premount-$c <<EOF2
KT=4000; KF=1500; SG_TARGET=1536
st_mounted() { [ ! -f $T/umounted ]; }
umount() { echo "\$*" >> $T/umount.log; touch $T/umounted; }
df() { case "\$*" in *base-us*) echo h; echo "x \$((KT * 1024)) 0 \$((KF * 1024)) 0% /mnt/base-us" ;; *) echo h; echo "x 778240 737280 40960 95% /m" ;; esac; }
st_img_mb() { echo 760; }; st_alloc_mb() { echo 760; }
case $c in starting) mkdir -p \$W/starting ;; running) sleep 60 & echo \$! > \$W/pid ;; off) echo SYSGROW=0 > \$SG_CONF ;;
  nested) awk() { if [ "\$1" = -v ]; then echo "/dev/x \$SYS/rootfs/proc proc rw 0 0"; else command awk "\$@"; fi; } ;; esac
sg_premount
case $c in free) [ -f $T/umounted ] || { echo "free: not unmounted"; cat \$ST_LOG; exit 1; } ;; *) [ ! -f $T/umounted ] || { echo "$c: unmounted"; exit 1; } ;; esac
EOF2
done
echo "legacy-sysgrow: ok"
