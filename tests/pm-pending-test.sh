#!/bin/sh
# Kindle boot hang guard (host/*/boot/lib/framework.sh pm_pending_guard): over 64 KB of
# /var/local/platform-metrics/pending-notifications makes `platformmetricsd-send-notification` in system_setup's pre-start exit 255
# on 5.18.6+ firmware, and the Kindle stops at the boot logo on every boot. The guard keeps it far below that, whole lines only,
# owner / mode kept, and it runs on every pause / resume of the Kindle UI (and every watchdog tick on pw6 / k49).
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
for h in pw6 k49 legacy; do
    # combined tree: host/legacy is the legacy line's own release (docs/legacy-line.md); checked once it has the change
    [ $h = legacy ] && ! grep -q '^pm_pending_guard()' host/legacy/boot/lib/framework.sh && { echo "  note: host/legacy has no pm_pending_guard yet - skipped"; continue; }
    f=host/$h/boot/lib/framework.sh
    sh -n $f || fail "syntax $f"
    awk '/^framework_stop\(\)/,/^}/' $f | sed -n 2,3p | grep -q '^    pm_pending_guard$' || fail "$h framework_stop does not run the guard first"
    awk '/^framework_start\(\)/,/^}/' $f | sed -n 2p | grep -q '^    pm_pending_guard$' || fail "$h framework_start does not run the guard first"
    case $h in pw6|k49) grep -q '^        var_guard; pm_pending_guard$' host/$h/boot/lib/watchdog.sh || fail "$h watchdog tick does not run the guard" ;; esac
    P=$T/pending
    # a real-looking file: 1500 lines, ~70 KB
    i=0; : > $P; while [ $i -lt 1500 ]; do echo "17941$(printf %05d $i),lipcmetrics,stats,com.lab126.powerd,2,0,NoSuchSource:1" >> $P; i=$((i + 1)); done
    chmod 664 $P; ino=$(ls -i $P | awk '{print $1}')
    [ "$(wc -c < $P)" -gt 65536 ] || fail "fixture too small"
    out=$(PM_PENDING=$P sh -c 't() { echo "LOG $*"; }; . '$f'; pm_pending_guard')
    sz=$(wc -c < $P | tr -d ' ')
    [ "$sz" -le 16384 ] && [ "$sz" -gt 8000 ] || fail "$h trimmed to $sz bytes"
    [ "$(ls -i $P | awk '{print $1}')" = "$ino" ] || fail "$h replaced the file (owner / mode of the Kindle's file would change)"
    [ "$(stat -c %a $P 2>/dev/null || stat -f %Lp $P)" = 664 ] || fail "$h mode changed"
    tail -n 1 $P | grep -q '^1794101499,lipcmetrics' || fail "$h newest line lost"
    grep -qv '^17941[0-9]*,lipcmetrics,stats,com.lab126.powerd,2,0,NoSuchSource:1$' $P && fail "$h left a cut line"
    echo "$out" | grep -q 'kept the newest' || fail "$h did not log"
    ls $T | grep -q vd && fail "$h left its temp file"
    # small file / missing file / symlink: untouched, silent
    printf '1,reboot,reboot\n' > $P
    out=$(PM_PENDING=$P sh -c 't() { echo "LOG $*"; }; . '$f'; pm_pending_guard; PM_PENDING='$T'/none pm_pending_guard')
    [ -z "$out" ] && [ "$(cat $P)" = "1,reboot,reboot" ] || fail "$h touched a small file: $out"
    i=0; : > $T/big; while [ $i -lt 1500 ]; do echo "x$i,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >> $T/big; i=$((i + 1)); done
    rm -f $P; ln -s $T/big $P; bs=$(wc -c < $T/big)
    PM_PENDING=$P sh -c 't() { :; }; . '$f'; pm_pending_guard'
    [ "$(wc -c < $T/big)" = "$bs" ] || fail "$h followed a symlink"
    rm -f $P $T/big
done
echo "pm-pending-test: OK"
