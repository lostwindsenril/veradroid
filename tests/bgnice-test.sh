#!/bin/sh
# host/legacy/boot/lib/bgnice.sh with real processes (Linux, root: lowering oom_score_adj needs CAP_SYS_RESOURCE; skipped
# elsewhere): a fake "zygote" with two children; the one at adj 900 gets nice BG_NICE on every thread, the one at adj 0 is
# left alone; back to adj 0 restores the recorded nice; BG_NICE=0 / bgnice_restore puts everything back; processes that
# are not zygote's children are never touched.
cd "$(dirname "$0")/.." || exit 2
[ "$(uname -s)" = Linux ] && [ "$(id -u)" = 0 ] && command -v renice >/dev/null 2>&1 || { echo "bgnice-test: needs Linux root - skipped"; exit 0; }
sh -n host/legacy/boot/lib/bgnice.sh || { echo "FAIL: syntax"; exit 1; }
T=$(mktemp -d) || exit 2
cleanup() { kill $ZP $C1 $C2 $C3 $O 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
nice_of() { awk '{ s = $0; sub(/.*\) /, "", s); split(s, f, " "); print f[17] }' /proc/$1/stat; }
# zygote: a copy of the shell named "zygote" (pidof matches the program name) that starts the two "apps"
cat > $T/z.sh <<'Z'
sleep 600 & echo $! > "$1/c1"
sleep 600 & echo $! > "$1/c2"
sleep 600 & echo $! > "$1/c3"
wait
Z
cp "$(command -v sh)" $T/zygote; $T/zygote $T/z.sh $T & ZP=$!
sleep 1; C1=$(cat $T/c1); C2=$(cat $T/c2); C3=$(cat $T/c3)
renice 10 -p $C3 >/dev/null; echo 900 > /proc/$C3/oom_score_adj   # an app thread that set THREAD_PRIORITY_BACKGROUND itself
sleep 600 & O=$!                       # not zygote's child
echo 900 > /proc/$C1/oom_score_adj; echo 0 > /proc/$C2/oom_score_adj; echo 900 > /proc/$O/oom_score_adj
pidof zygote | grep -qw $ZP || fail "pidof does not see the fake zygote"
run() { W=$T sh -c '. host/legacy/boot/lib/bgnice.sh; '"$*"; }
run "BG_NICE=10 bgnice_tick"
[ "$(nice_of $C1)" = 10 ] || fail "adj 900 app: nice $(nice_of $C1), want 10"
[ "$(nice_of $C2)" = 0 ] || fail "adj 0 app touched: nice $(nice_of $C2)"
[ "$(nice_of $O)" = 0 ] || fail "a process that is not zygote's child was touched"
[ -s $T/bgnice/$C1 ] || fail "no record for $C1"
run "BG_NICE=10 bgnice_tick"; [ "$(wc -l < $T/bgnice/$C1)" = 1 ] || fail "second tick changed the record"
grep -qx "$C3 -" $T/bgnice/$C3 || fail "a thread already at BG_NICE is not recorded as kept: $(cat $T/bgnice/$C3)"
echo 0 > /proc/$C3/oom_score_adj; run "BG_NICE=10 bgnice_tick"
[ "$(nice_of $C3)" = 10 ] || fail "back in front: the app's own background thread was raised to nice $(nice_of $C3)"
echo 0 > /proc/$C1/oom_score_adj
run "BG_NICE=10 bgnice_tick"
[ "$(nice_of $C1)" = 0 ] && [ ! -f $T/bgnice/$C1 ] || fail "back in front: nice $(nice_of $C1), record $(ls $T/bgnice)"
echo 900 > /proc/$C1/oom_score_adj; run "BG_NICE=10 bgnice_tick"; [ "$(nice_of $C1)" = 10 ] || fail "second time in the background"
run "bgnice_restore"
[ "$(nice_of $C1)" = 0 ] && [ ! -d $T/bgnice ] || fail "bgnice_restore: nice $(nice_of $C1)"
run "BG_NICE=0 bgnice_tick"; [ "$(nice_of $C1)" = 0 ] || fail "BG_NICE=0 lowered something"
grep -q 'bgnice' host/legacy/boot/veradroid.sh && grep -q 'bgnice_tick' host/legacy/boot/lib/watchdog.sh && grep -q 'bgnice_tick' host/legacy/boot/lib/cmd.sh \
    || fail "bgnice.sh is not loaded / called (veradroid.sh, watchdog.sh, cmd.sh fg)"
echo "bgnice: ok"
