#!/bin/sh
# perf/ret: returning to the Kindle with the framework kept (freeze / keep) does not wait for kindle_home (library app lipc +
# appmgrd "KPP_HOME"; 9-21 s on device, 60 s on the PW6 emulator); with the framework stopped (stop / stopfail) it still waits.
# The stop-mode framework restart is waited for at most 30 s after fw_wait_ready (it used to wait forever).
# Runs framework_start's tail with stubs: kindle_home sleeps 3 s; freeze mode must return in < 1.5 s, stop mode after it.
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
for m in pw6 k49; do
    f=host/$m/boot/lib/framework.sh
    sh -n $f || fail "syntax $f"
    blk=$(awk '/perf_mark "fw: services started/ { p = 1 } p { print } p && /^    fi$/ { exit }' $f)
    [ -n "$blk" ] || fail "$f: block not found"
    echo "$blk" | grep -q '( cd /; sleep 1; kindle_home;' || fail "$f: background kindle_home must cd / first (stop.sh unmounts the system image)"
    echo "$blk" | grep -q '>>$W/fwhome.log' || fail "$f: background kindle_home must log to tmpfs, not the system image"
    T=$(mktemp -d) || exit 2
    for mode in freeze stop; do
        NOFW=; [ $mode = stop ] && NOFW=1
        s0=$(date +%s)
        W=$T NOFW=$NOFW sh -c "t() { :; }; perf_mark() { :; }; sleep() { command sleep \"\$@\"; }; kindle_home() { command sleep 3; echo home > $T/home.$mode; }
$blk" || fail "$f: block failed ($mode)"
        el=$(( $(date +%s) - s0 ))
        if [ $mode = freeze ]; then [ $el -le 1 ] || fail "$f: freeze mode waited ${el}s for kindle_home"
        else [ $el -ge 3 ] && [ -f $T/home.stop ] || fail "$f: stop mode did not wait for kindle_home (${el}s)"; fi
    done
    command sleep 4; [ -f $T/home.freeze ] || fail "$f: background kindle_home never ran"
    rm -rf "$T"
    grep -q 'wait \$fw_svp' $f && fail "$f: unbounded wait for the framework start (upstart waits for FrameworkStarted without a timeout)"
    grep -q 'while kill -0 \$fw_svp 2>/dev/null && \[ \$i -lt 150 \]' $f || fail "$f: bounded wait for the framework start missing"
done
echo "PASS ret-async"
