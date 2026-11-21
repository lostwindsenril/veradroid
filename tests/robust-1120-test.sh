#!/bin/sh
# fix/robust-1120 (community report on legacy 0.8.13; the same code is in host/pw6 and host/k49): checks without a device.
#  1 progress ticker ends when its parent script is gone (Linux /proc; static check elsewhere); bootstrap.sh carries the same copy
#  2 stop.sh --stale fast path: stale_clean says clean only for a whitelisted $W, no container mounts / processes / adb keys
#  3 wd_guard restarts a dead watchdog, stops when Android is frozen or gone; stop.sh and do_exit stop it
#  4 bootwatch: boot-fail.log / boot-fail.count, reset on success; the second stall shows a notice after stop.sh
#  5 keepawake: bootstrap.sh records the original value before setting 1 and removes it on restore; veradroid.sh heals it
cd "$(dirname "$0")/.." || exit 2
T=$(mktemp -d) || exit 2
trap 'kill $GP $AP $WP 2>/dev/null; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
fn() { awk -v n="$2" '$0 ~ "^" n "\\(\\) \\{" { p = 1 } p { print } p && /^}/ { exit }' "$1"; }

grep -q 'while \[ -d /proc/\$\$ \]; do' cloud/static/bootstrap.sh || fail "bootstrap.sh ticker does not watch its parent"
for m in pw6 k49; do
B=host/$m/boot
for f in $B/lib/progress.sh $B/stop.sh $B/veradroid.sh $B/lib/watchdog.sh $B/lib/bootwatch.sh cloud/static/bootstrap.sh; do sh -n $f || fail "syntax $f"; done

# 1 ticker
grep -q 'while \[ -d /proc/\$\$ \]; do' $B/lib/progress.sh || fail "$m: ticker loop does not watch its parent"
if [ -d /proc/$$ ]; then
    cat > $T/tick.sh <<E
VP_ST0=0; vp_now() { echo 1; }; vp_mmss() { echo 0:00; }; vp_progress() { :; }
$(fn $B/lib/progress.sh vp_ticker_start | sed 's/sleep 5$/sleep 1/')
$(fn $B/lib/progress.sh vp_ticker_stop)
vp_ticker_start 60 x; echo \$VP_TICK > $T/tick.pid; exec sleep 600
E
    rm -f $T/tick.pid; sh $T/tick.sh >/dev/null 2>&1 & TP=$!
    i=0; while [ ! -s $T/tick.pid ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    KP=$(cat $T/tick.pid); kill -0 "$KP" 2>/dev/null || fail "$m: ticker did not start"
    kill -9 $TP; i=0; while kill -0 "$KP" 2>/dev/null && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
    kill -0 "$KP" 2>/dev/null && { kill -9 "$KP"; fail "$m: ticker survived its killed parent (orphan)"; }
fi

# 2 stale fast path
eval "$(fn $B/stop.sh stale_clean)"; eval "$(grep "^STALE_KEEP=" $B/stop.sh)"; [ -n "$STALE_KEEP" ] || fail "$m: no STALE_KEEP"
grep -q '\[ -n "\$STALE" \] && stale_clean' $B/stop.sh || fail "$m: stale_clean is not used for --stale"
SYS=/mnt/base-us/system/veradroid; W=$T/w; R=$SYS/rootfs; FZ=$W/freezer/vd; VD_MOUNTS=$T/mounts; VD_ADBKEYS=$T/adb_keys
pgrep() { [ -n "${FAKE_PG:-}" ] && echo 4242; return 0; }; chroot_pids() { echo "${FAKE_CP:-}"; }; hostns() { [ -n "${FAKE_HOSTNS:-}" ]; }
mkdir -p $W/starting; for k in $STALE_KEEP; do : > $W/$k; done
printf '/dev/loop0 %s ext4 rw 0 0\n' "$SYS" > $VD_MOUNTS
stale_clean || fail "$m: clean state not recognised"
rm -rf $W; stale_clean || fail "$m: no \$W at all not clean"; mkdir -p $W/starting
for f in pid kfb mode fw unshare.pid watchdog.pid frozen loopdio.base adbfwd.ipt whatever.new; do
    : > $W/$f; stale_clean && fail "$m: \$W/$f present but called clean"; rm -f $W/$f
done
printf '/dev/loop0 %s ext4 rw 0 0\nnone %s/dev tmpfs rw 0 0\n' "$SYS" "$R" > $VD_MOUNTS; stale_clean && fail "$m: mount under \$R called clean"
printf '/dev/loop0 %s ext4 rw 0 0\n/dev/x %s/data/x ext4 rw 0 0\n' "$SYS" "$SYS" > $VD_MOUNTS; stale_clean && fail "$m: mount under \$SYS/ called clean"
printf '/dev/loop0 %s ext4 rw 0 0\n' "$SYS" > $VD_MOUNTS
mkdir -p $FZ; stale_clean && fail "$m: freezer group called clean"; rm -rf $W/freezer
FAKE_PG=1; stale_clean && fail "$m: unshare / slirp process called clean"; FAKE_PG=
FAKE_HOSTNS=1 FAKE_CP=777; stale_clean && fail "$m: chroot process called clean"; FAKE_HOSTNS=; FAKE_CP=
: > $VD_ADBKEYS; stale_clean && fail "$m: wireless-debugging keys left but called clean"; rm -f $VD_ADBKEYS
sleep 30 >/dev/null 2>&1 & AP=$!; echo $AP > $T/stop.pid
VD_STOP_PIDF=$T/stop.pid stale_clean && fail "$m: a full stop.sh is running but called clean"; kill $AP
stale_clean || fail "$m: clean again after the checks"
unset -f pgrep chroot_pids hostns

# 3 watchdog guard
grep -q 'wd_guard &' $B/veradroid.sh && grep -q 'guard.pid' $B/veradroid.sh || fail "$m: start_helpers does not start wd_guard"
[ "$(grep -c 'for f in guard watchdog sleep' $B/stop.sh)" = 2 ] && grep -q 'case "$f" in guard|watchdog' $B/stop.sh || fail "$m: stop.sh does not stop the guard"
grep -q 'for f in sleep lipc guard watchdog; do kill' $B/lib/watchdog.sh || fail "$m: do_exit (freeze) does not stop the guard"
W=$T/g; rm -rf $W; mkdir -p $W
cat > $T/guard.sh <<E
W=$W; P=\$1; WD_GUARD_S=1
t() { echo "\$*" >> $W/log; }
alive() { [ -f "\$1" ] && kill -0 "\$(cat "\$1" 2>/dev/null)" 2>/dev/null; }
watchdog() { echo start >> $W/wd.starts; exec sleep 600; }
$(fn $B/lib/watchdog.sh wd_guard)
wd_guard
E
sleep 600 >/dev/null 2>&1 & AP=$!
sleep 600 >/dev/null 2>&1 & WP=$!; echo $WP > $W/watchdog.pid
sh $T/guard.sh $AP >/dev/null 2>&1 & GP=$!
sleep 2; [ -f $W/wd.starts ] && fail "$m: guard restarted a live watchdog"
kill $WP; i=0; while [ ! -f $W/wd.starts ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
[ -f $W/wd.starts ] || fail "$m: guard did not restart a dead watchdog"
NW=$(cat $W/watchdog.pid); kill -0 "$NW" 2>/dev/null || fail "$m: new watchdog.pid is not alive"
touch $W/frozen; i=0; while kill -0 $GP 2>/dev/null && [ $i -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
kill -0 $GP 2>/dev/null && fail "$m: guard kept running while Android is frozen"
kill "$NW" 2>/dev/null; rm -f $W/frozen $W/wd.starts
sh $T/guard.sh $AP >/dev/null 2>&1 & GP=$!; kill $AP; i=0; while kill -0 $GP 2>/dev/null && [ $i -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
kill -0 $GP 2>/dev/null && fail "$m: guard kept running after Android exited"
[ -f $W/wd.starts ] && fail "$m: guard restarted the watchdog after Android exited"

# 4 boot failure record
eval "$(fn $B/lib/bootwatch.sh bw_fail)"; eval "$(fn $B/lib/bootwatch.sh bw_ok)"
BW_STATE=$T/state-$m; VD=$T/vd; mkdir -p $VD; echo 1.03 > $VD/version; echo pw6 > $VD/model
bw_fail 27 150 boot_progress_start; bw_fail 34 150 ""
[ "$(cat $BW_STATE/boot-fail.count)" = 2 ] || fail "$m: boot-fail.count $(cat $BW_STATE/boot-fail.count), want 2"
grep -q 'stalled at 27% .*boot_progress_start.*in a row 1; version 1.03' $BW_STATE/boot-fail.log || fail "$m: boot-fail.log: $(cat $BW_STATE/boot-fail.log)"
bw_ok; [ -f $BW_STATE/boot-fail.count ] && fail "$m: bw_ok did not clear the count"
awk '/stalled again/ { a = 1 } a && /stop.sh/ { b = 1 } b && /vd_notice/ { ok = 1; exit } END { exit !ok }' $B/lib/bootwatch.sh || fail "$m: second stall: no notice after stop.sh"
grep -q 'bw_fail "\$last" "\$n" "\$ev"' $B/lib/bootwatch.sh && grep -q 'rm -f $W/boot.retry; bw_ok;' $B/lib/bootwatch.sh || fail "$m: stall not recorded / success does not reset"

# 5 keepawake heal
mkdir -p $T/bin; printf '#!/bin/sh\necho "$*" >> %s/lipc.log\n' $T > $T/bin/lipc-set-prop; chmod 755 $T/bin/lipc-set-prop
fn $B/veradroid.sh keepawake_heal | sed "s#/mnt/base-us/veradroid/state#$T/kstate#g" > $T/heal.sh
rm -rf $T/kstate $T/lipc.log; mkdir -p $T/kstate; echo 0 > $T/kstate/keepawake.orig
PATH=$T/bin:$PATH sh -c "t() { :; }; . $T/heal.sh; keepawake_heal"
grep -q 'preventScreenSaver 0' $T/lipc.log && [ ! -f $T/kstate/keepawake.orig ] || fail "$m: keepawake_heal did not restore 0"
echo 0 > $T/kstate/keepawake.orig; mkdir $T/kstate/install.lock; echo $$ > $T/kstate/install.lock/pid; cat /proc/sys/kernel/random/boot_id > $T/kstate/install.lock/boot 2>/dev/null; rm -f $T/lipc.log
if [ -f /proc/sys/kernel/random/boot_id ]; then
    PATH=$T/bin:$PATH sh -c "t() { :; }; . $T/heal.sh; keepawake_heal"
    [ -f $T/lipc.log ] && fail "$m: keepawake_heal touched the value while a live installer holds the lock"
fi
grep -q '^keepawake_heal 2>/dev/null' $B/veradroid.sh || fail "$m: veradroid.sh does not call keepawake_heal"
done

BS=cloud/static/bootstrap.sh
awk '/state\/keepawake.orig/ && !w { w = NR } /preventScreenSaver 1 2>/ && !s { s = NR } END { exit !(w && s && w < s) }' $BS || fail "bootstrap.sh: marker / set order"
grep -q 'preventScreenSaver 0 2>/dev/null && rm -f /mnt/base-us/veradroid/state/keepawake.orig' $BS || fail "bootstrap.sh does not remove the record after restoring"
echo "robust-1120: ok"
