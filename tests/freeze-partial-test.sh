#!/bin/sh
# A freeze that does not finish (cgroup freezer still FREEZING after 5 s, e.g. a process in uninterruptible IO) must not
# leave Android half frozen: netd frozen while system_server kept sending it commands -> 60 s timeouts -> system_server
# crashed with NativeDaemonTimeoutException (PW5 5.16 field diagnostics 2026-11-21). android_freeze (boot/lib/freeze.sh)
# thaws back and fails; the screensaver (boot/lib/sleep.sh) then treats Android as not frozen (no thaw on wake).
# No device needed: the freezer is a plain file, everything that touches the Kindle is stubbed.
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
DIRS=${FREEZE_DIRS:-"host/pw6/boot/lib host/k49/boot/lib"}
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
for L in $DIRS; do
    sh -n $L/freeze.sh || fail "syntax $L/freeze.sh"
    sh -n $L/sleep.sh || fail "syntax $L/sleep.sh"
    for case in stuck ok; do
        rm -rf $T/w; mkdir -p $T/w/fz $T/x/ctl; : > $T/log
        W=$T/w X=$T/x FZ=$T/w/fz L=$L CASE=$case LOG=$T/log sh -c '
            . $L/freeze.sh; . $L/sleep.sh
            t() { echo "$*" >> $LOG; }
            freezer_setup() { return 0; }; fz_signal() { return 1; }; usleep() { :; }; sync() { :; }
            vinput_reset() { :; }; wd_release() { :; }; wd_hold() { :; }; wd_release_later() { :; }
            cpu_gov_set() { echo gov-set >> $LOG; }; cpu_gov_restore() { echo gov-restore >> $LOG; }
            net_pause() { echo net-pause >> $LOG; }; net_resume() { :; }
            screensaver_show() { :; }; lock_request() { :; }; lock_reset_check() { :; }; trust_unlock() { :; }
            wifi_ps_restore() { :; }; epd_send() { :; }; alive() { return 1; }; saver_exit_check() { :; }
            kindle_ui_mode() { echo stop; }; tset() { :; }; android_thaw_staged() { android_thaw; }
            # stuck: the kernel keeps answering FREEZING (a task in uninterruptible IO)
            if [ $CASE = stuck ]; then freezer_state() { echo FREEZING; }
            else freezer_state() { cat $FZ/freezer.state 2>/dev/null; }; fi
            sleep_apply saver
            echo "state=$(cat $FZ/freezer.state)" >> $LOG
            ls $W >> $LOG
            sleep_apply active
            echo "after-wake=$(cat $FZ/freezer.state)" >> $LOG
        ' 2>>$T/log
        if [ $case = stuck ]; then
            grep -q '^state=THAWED$' $T/log || { cat $T/log; fail "$L: freeze stuck in FREEZING was not thawed back"; }
            grep -q 'freeze: still FREEZING after 5 s' $T/log || { cat $T/log; fail "$L: incomplete freeze not logged"; }
            grep -q '^saver_nofreeze$' $T/log || { cat $T/log; fail "$L: screensaver did not mark android as not frozen"; }
            grep -q '^saver_frozen$' $T/log && fail "$L: saver_frozen set although the freeze failed"
            grep -q 'gov-restore' $T/log || fail "$L: cpu governor not restored after the failed freeze"
            grep -q 'net-pause' $T/log && fail "$L: network paused although android was left running"
            grep -q 'android left running' $T/log || { cat $T/log; fail "$L: screensaver log still says frozen"; }
        else
            grep -q '^state=FROZEN$' $T/log || { cat $T/log; fail "$L: normal freeze did not freeze"; }
            grep -q '^saver_frozen$' $T/log || fail "$L: normal freeze: no saver_frozen"
            grep -q 'net-pause' $T/log || fail "$L: normal freeze: network not paused"
            grep -q '^after-wake=THAWED$' $T/log || { cat $T/log; fail "$L: normal freeze: not thawed on wake"; }
            grep -q 'screensaver on, android frozen' $T/log || { cat $T/log; fail "$L: normal freeze log changed"; }
        fi
    done
done
echo "PASS freeze-partial"
