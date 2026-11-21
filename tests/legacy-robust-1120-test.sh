#!/bin/sh
# fix/legacy-robust-1120 (community report on 0.8.13, PW4): checks that run without a device.
#  1 progress ticker: the background subshell ends when its parent script is gone (Linux /proc; static check elsewhere)
#  2 sys_link_hit: "-> $SYS" and "-> $SYS/x" hit, "-> ${SYS}X" does not (the pattern exactly as common.sh passes it to grep)
#  3 sk_cands (one grep -l) is a superset of sk_ours (the old per-process case): never drops a process the old code killed
#  4 stop.sh --stale fast path: stale_clean says clean only for a whitelisted $W, no container mounts / processes
#  5 wd_guard restarts a dead watchdog, stops when Android is frozen or gone
#  6 bootwatch: boot-fail.log / boot-fail.count, reset on success; the second stall shows a notice after stop.sh
#  7 keepawake: installer records the original value before setting 1, removes it on a normal exit; veradroid.sh heals it
#  8 bgnice: threads that were already at BG_NICE are recorded as "tid -" and left alone (functional part in bgnice-test.sh)
cd "$(dirname "$0")/.." || exit 2
B=host/legacy/boot
T=$(mktemp -d) || exit 2
trap 'kill $GP $AP $WP 2>/dev/null; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
fn() { awk -v n="$2" '$0 ~ "^" n "\\(\\) \\{" { p = 1 } p { print } p && /^}/ { exit }' "$1"; }   # one function's source

for f in $B/lib/progress.sh $B/lib/common.sh $B/stop.sh $B/veradroid.sh $B/lib/watchdog.sh $B/lib/bootwatch.sh $B/lib/bgnice.sh cloud/static/bootstrap-legacy.sh; do
    sh -n $f || fail "syntax $f"
done

# 1 ticker
grep -q 'while \[ -d /proc/\$\$ \]; do' $B/lib/progress.sh || fail "ticker loop does not watch its parent"
grep -q 'while :; do' $B/lib/progress.sh && fail "progress.sh still has an endless while :"
if [ -d /proc/$$ ]; then
    cat > $T/tick.sh <<E
VP_ST0=0; vp_now() { echo 1; }; vp_mmss() { echo 0:00; }; vp_progress() { :; }
$(fn $B/lib/progress.sh vp_ticker_start)
$(fn $B/lib/progress.sh vp_ticker_stop)
vp_ticker_start 60 x; echo \$VP_TICK > $T/tick.pid; exec sleep 600
E
    sed -i 's/sleep 5$/sleep 1/' $T/tick.sh 2>/dev/null
    sh $T/tick.sh >/dev/null 2>&1 & TP=$!
    i=0; while [ ! -s $T/tick.pid ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    KP=$(cat $T/tick.pid); kill -0 "$KP" 2>/dev/null || fail "ticker did not start"
    kill -9 $TP; i=0; while kill -0 "$KP" 2>/dev/null && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
    kill -0 "$KP" 2>/dev/null && { kill -9 "$KP"; fail "ticker survived its killed parent (orphan)"; }
    echo "ticker: ends within $((i / 4 + 1)) s of its parent being killed"
else
    echo "ticker: no /proc here, static check only"
fi

# 2 exact match on $SYS
SYS=/mnt/base-us/system/veradroid
eval "$(fn $B/lib/common.sh sys_link_hit)"
echo "lrwx------ 1 root root 64 Nov 20 10:00 /proc/9/cwd -> $SYS" | sys_link_hit || fail "exact \$SYS not matched"
echo "lr-x------ 1 root root 64 Nov 20 10:00 3 -> $SYS/rootfs/system/x" | sys_link_hit || fail "\$SYS/x not matched"
echo "lr-x------ 1 root root 64 Nov 20 10:00 3 -> ${SYS}X" | sys_link_hit && fail "\${SYS}X matched"
echo "lr-x------ 1 root root 64 Nov 20 10:00 3 -> ${SYS}-old/a" | sys_link_hit && fail "\${SYS}-old/a matched"

# 3 candidate prefilter is a superset of the old per-process test
VD=/mnt/base-us/veradroid
eval "$(fn $B/lib/common.sh sk_ours)"; eval "$(fn $B/lib/common.sh sk_cands)"; eval "$(fn $B/lib/common.sh sk_grep_nul)"
sk_grep_nul || echo "note: this grep stops at NUL; sys_holders_kill falls back to the per-process scan here"
i=0
for c in "sh|$VD/boot/veradroid.sh|home" "sh|$VD/boot/stop.sh" "sleep|20" "sleep|" "usleep|200000" "/bin/sleep|5" "sleepy|x" \
         "setsid|sh|$VD/boot/veradroid.sh" "sh|/dev/shm/veradroid/auto-update.sh" "/usr/bin/lipc-wait-event|x" "sh|/mnt/base-us/veradroid/bootX" \
         "timeout|3|sh|-c|echo|$VD/boot/lib/x" "cvm|-Xmx" "busybox|sleep|3"; do
    i=$((i + 1)); printf '%s\000' $(echo "$c" | tr '|' ' ') > $T/c$i; [ "${c%|}" != "$c" ] && printf '\000' >> $T/c$i
    old=no; sk_ours "$(tr '\000' ' ' < $T/c$i)" && old=yes
    new=no; [ -n "$(sk_cands $T/c$i)" ] && new=yes
    [ "$old" = yes ] && [ "$new" = no ] && sk_grep_nul && fail "prefilter drops a process the old test kept: $c"
done
grep -q 'sk_ours "$sk_c" || continue' $B/lib/common.sh && grep -q 'sys_link_hit || continue' $B/lib/common.sh || fail "sys_holders_kill no longer applies the old test"

# 4 stop.sh --stale fast path
eval "$(fn $B/stop.sh stale_clean)"; eval "$(grep "^STALE_KEEP=" $B/stop.sh)"; [ -n "$STALE_KEEP" ] || fail "no STALE_KEEP"
type stale_clean >/dev/null 2>&1 || fail "no stale_clean in stop.sh"
grep -q '\[ -n "\$STALE" \] && stale_clean' $B/stop.sh || fail "stale_clean is not used for --stale"
W=$T/w; R=$SYS/rootfs; FZ=$W/freezer/vd; VD_MOUNTS=$T/mounts
pgrep() { [ -n "${FAKE_PG:-}" ] && echo 4242; return 0; }; chroot_pids() { echo "${FAKE_CP:-}"; }
t() { :; }
mkdir -p $W/starting $W/bgnice; : > $W/shutw.log; : > $W/autoupdate.pid
printf '/dev/loop0 %s ext4 rw 0 0\n' "$SYS" > $VD_MOUNTS
stale_clean || fail "clean state not recognised"
rm -rf $W; stale_clean || fail "no \$W at all (first start after a reboot) not clean"
mkdir -p $W/starting
: > $W/pid; stale_clean && fail "\$W/pid present but called clean"; rm -f $W/pid
mkdir $W/kfb; stale_clean && fail "\$W/kfb present but called clean"; rmdir $W/kfb
: > $W/whatever.new; stale_clean && fail "unknown file in \$W called clean"; rm -f $W/whatever.new
mkdir $W/fw; stale_clean && fail "framework state dir present but called clean"; rmdir $W/fw
printf '/dev/loop0 %s ext4 rw 0 0\nnone %s/dev tmpfs rw 0 0\n' "$SYS" "$R" > $VD_MOUNTS; stale_clean && fail "mount under \$R called clean"
printf '/dev/loop0 %s ext4 rw 0 0\n/dev/x %s/data/x ext4 rw 0 0\n' "$SYS" "$SYS" > $VD_MOUNTS; stale_clean && fail "mount under \$SYS/ called clean"
printf '/dev/loop0 %s ext4 rw 0 0\n' "$SYS" > $VD_MOUNTS
mkdir -p $FZ; stale_clean && fail "freezer group present but called clean"; rm -rf $W/freezer
FAKE_PG=1; stale_clean && fail "unshare / slirp process present but called clean"; FAKE_PG=
FAKE_CP=777; stale_clean && fail "process rooted on the image present but called clean"; FAKE_CP=
sleep 30 >/dev/null 2>&1 & AP=$!; echo $AP > $T/stop.pid
VD_STOP_PIDF=$T/stop.pid stale_clean && fail "a full stop.sh is still running but called clean"; kill $AP
stale_clean || fail "clean again after the checks"
unset -f pgrep chroot_pids t

# 5 watchdog guard
grep -q 'wd_guard &' $B/veradroid.sh && grep -q 'guard.pid' $B/veradroid.sh || fail "start_helpers does not start wd_guard"
grep -q 'for f in guard watchdog sleep' $B/stop.sh && grep -q 'case "$f" in guard|watchdog' $B/stop.sh || fail "stop.sh does not stop the guard"
grep -q 'for f in sleep lipc guard watchdog; do kill' $B/lib/watchdog.sh || fail "do_exit (freeze) does not stop the guard"
W=$T/g; mkdir -p $W
cat > $T/guard.sh <<E
W=$W; P=\$1; WD_GUARD_S=1
t() { echo "\$*" >> $W/log; }
alive() { [ -f "\$1" ] && kill -0 "\$(cat "\$1" 2>/dev/null)" 2>/dev/null; }
watchdog() { echo start >> $W/wd.starts; exec sleep 600; }
$(fn $B/lib/watchdog.sh wd_guard)
wd_guard
E
sleep 600 >/dev/null 2>&1 & AP=$!                       # "android"
sleep 600 >/dev/null 2>&1 & WP=$!; echo $WP > $W/watchdog.pid
sh $T/guard.sh $AP >/dev/null 2>&1 & GP=$!
sleep 2; [ -f $W/wd.starts ] && fail "guard restarted a live watchdog"
kill $WP; i=0; while [ ! -f $W/wd.starts ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
[ -f $W/wd.starts ] || fail "guard did not restart a dead watchdog"
NW=$(cat $W/watchdog.pid); kill -0 "$NW" 2>/dev/null || fail "new watchdog.pid is not alive"
touch $W/frozen; i=0; while kill -0 $GP 2>/dev/null && [ $i -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
kill -0 $GP 2>/dev/null && fail "guard kept running while Android is frozen"
kill "$NW" 2>/dev/null; rm -f $W/frozen $W/wd.starts
sh $T/guard.sh $AP >/dev/null 2>&1 & GP=$!; kill $AP; i=0; while kill -0 $GP 2>/dev/null && [ $i -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
kill -0 $GP 2>/dev/null && fail "guard kept running after Android exited"
[ -f $W/wd.starts ] && fail "guard restarted the watchdog after Android exited"

# 6 boot failure record
eval "$(fn $B/lib/bootwatch.sh bw_fail)"; eval "$(fn $B/lib/bootwatch.sh bw_ok)"
BW_STATE=$T/state; VD=$T/vd; mkdir -p $VD; echo 0.8.14 > $VD/version; echo pw4 > $VD/model
bw_fail 27 150 boot_progress_start; bw_fail 34 150 ""
[ "$(cat $BW_STATE/boot-fail.count)" = 2 ] || fail "boot-fail.count $(cat $BW_STATE/boot-fail.count), want 2"
[ "$(wc -l < $BW_STATE/boot-fail.log)" -eq 2 ] && grep -q 'stalled at 27% .*boot_progress_start.*in a row 1; version 0.8.14 model pw4' $BW_STATE/boot-fail.log || fail "boot-fail.log: $(cat $BW_STATE/boot-fail.log)"
echo junk > $BW_STATE/boot-fail.count; bw_fail 20 150 x; [ "$(cat $BW_STATE/boot-fail.count)" = 1 ] || fail "garbage count not reset"
bw_ok; [ -f $BW_STATE/boot-fail.count ] && fail "bw_ok did not clear the count"
awk '/stalled again/ { a = 1 } a && /stop.sh/ { b = 1 } b && /bw_notice/ { ok = 1; exit } END { exit !ok }' $B/lib/bootwatch.sh || fail "second stall: no notice after stop.sh"
grep -q 'bw_fail "\$last" "\$n" "\$ev"' $B/lib/bootwatch.sh || fail "stall branch does not record"
[ "$(grep -c 'bw_ok' $B/lib/bootwatch.sh)" -ge 3 ] || fail "successful boot does not reset the count"

# 7 keepawake self-heal
BS=cloud/static/bootstrap-legacy.sh
awk '/state\/keepawake.orig/ && !w { w = NR } /preventScreenSaver 1 >/ && w && !s { s = NR } END { exit !(w && s && w < s) }' $BS || fail "installer does not record the original value before setting 1"
grep -q 'preventScreenSaver "$KEEPAWAKE" >/dev/null 2>&1 && rm -f /mnt/base-us/veradroid/state/keepawake.orig' $BS || fail "installer does not remove the record after restoring"
mkdir -p $T/bin; printf '#!/bin/sh\necho "$*" >> %s/lipc.log\n' $T > $T/bin/lipc-set-prop; chmod 755 $T/bin/lipc-set-prop
fn $B/veradroid.sh keepawake_heal | sed "s#/mnt/base-us/veradroid/state#$T/kstate#g" > $T/heal.sh
mkdir -p $T/kstate; echo 0 > $T/kstate/keepawake.orig
PATH=$T/bin:$PATH sh -c "t() { :; }; . $T/heal.sh; keepawake_heal"
grep -q 'preventScreenSaver 0' $T/lipc.log && [ ! -f $T/kstate/keepawake.orig ] || fail "keepawake_heal did not restore 0"
echo 0 > $T/kstate/keepawake.orig; mkdir $T/kstate/install.lock; rm -f $T/lipc.log
PATH=$T/bin:$PATH sh -c "t() { :; }; . $T/heal.sh; keepawake_heal"
[ -f $T/lipc.log ] && fail "keepawake_heal touched the value while an installer holds the lock"
grep -q '^keepawake_heal 2>/dev/null' $B/veradroid.sh || fail "veradroid.sh does not call keepawake_heal"

# 8 bgnice record format
grep -q 'echo "$bt -" >> $W/bgnice/$bp.tmp' $B/lib/bgnice.sh && grep -q '\[ "$bo" = - \] && continue' $B/lib/bgnice.sh || fail "bgnice does not keep pre-existing background threads"

echo "legacy-robust-1120: ok"
