#!/bin/sh
# perf/thaw: re-entering a frozen Android (veradroid.sh thaw path) draws Android at once.
#  1 no "正在恢复" splash and no fixed 1 s before the display is released; the release sends one FULL (flash) right after android_thaw
#  2 freeze.sh wd_hold finds system_server and its "watchdog" thread with one grep each (was one cat per process / thread);
#    checked against a real process tree when python3 and /proc are there (Linux): a fake system_server with a thread named watchdog
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
for m in pw6 k49; do
    v=host/$m/boot/veradroid.sh; f=host/$m/boot/lib/freeze.sh
    sh -n $v || fail "syntax $v"; sh -n $f || fail "syntax $f"
    blk=$(awk '/^    if \[ -f \$W\/frozen \]; then/ { p = 1 } p { print } p && /t "thawed"/ { exit }' $v)
    [ -n "$blk" ] || fail "$v: thaw block not found"
    echo "$blk" | grep -q 'splash "正在恢复"' && fail "$v: thaw still draws the 正在恢复 splash"
    echo "$blk" | grep -q 'sleep 1; rm -f \$X/ctl/sleep' && fail "$v: thaw still waits 1 s before releasing the display"
    echo "$blk" | awk '/android_thaw$/ { a = NR } /rm -f \$X\/ctl\/sleep; \( epd_send FULL/ { b = NR } END { exit !(a && b && a < b) }' \
        || fail "$v: no FULL right after android_thaw"
    echo "$blk" | awk '/touch \$X\/ctl\/sleep/ { a = NR } /^        framework_stop$/ { b = NR } END { exit !(a && b && a < b) }' \
        || fail "$v: ctl/sleep not set before the Kindle UI is paused"
    grep -q 'xargs grep -lx system_server' $f && grep -q 'grep -lx watchdog /proc/$ss/task/\*/comm' $f || fail "$f: lookup not the single-grep form"
done
if command -v python3 >/dev/null 2>&1 && [ -r /proc/self/comm ] && [ "$(uname)" = Linux ]; then
    T=$(mktemp -d) || exit 2
    trap 'kill $SP 2>/dev/null; rm -rf "$T"' EXIT
    cp "$(command -v python3)" $T/system_server
    $T/system_server -c '
import ctypes, threading, time
def w():
    ctypes.CDLL(None).prctl(15, b"watchdog", 0, 0, 0); time.sleep(30)
for n in range(3): threading.Thread(target=lambda: time.sleep(30), daemon=True).start()
threading.Thread(target=w, daemon=True).start(); time.sleep(30)' & SP=$!
    sleep 1
    mkdir -p $T/fz; { echo $$; sleep 30 & echo $!; echo $SP; } > $T/fz/cgroup.procs
    snip=$(awk '/ss=\$\(sed .s#\^#\/proc\/#/ { p = 1 } p { print } p && /wt=\$\{wt##\*\/\}/ { exit }' host/pw6/boot/lib/freeze.sh)
    out=$(FZ=$T/fz sh -c "$snip"'
echo "$ss $wt"')
    set -- $out
    [ "$1" = "$SP" ] || fail "system_server pid: got '$1', want $SP"
    [ -n "$2" ] && [ "$(cat /proc/$SP/task/$2/comm)" = watchdog ] || fail "watchdog thread not found (got '$2')"
    echo "lookup ok: system_server $1, watchdog thread $2"
fi
echo "PASS thaw-fast"
