#!/bin/sh
# Kernel LMK table (host/*/boot/lib/memory.sh lmk_kernel_tune / lmk_kernel_restore): the 512 MB tune saves the Kindle's own
# minfree / adj once (watchdog re-applies every tick), and stop.sh puts them back (full stop via zram_restore, stale stop too).
# Before: the Kindle kept running with an 8 MB LMK floor after Android stopped, until the next reboot.
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
for h in pw6 k49 legacy; do
    b=host/$h/boot
    sh -n $b/lib/memory.sh || fail "syntax $b/lib/memory.sh"
    sh -n $b/stop.sh || fail "syntax $b/stop.sh"
    awk '/^zram_restore\(\)/,/^}/' $b/lib/memory.sh | grep -q '^    lmk_kernel_restore$' || fail "$h zram_restore does not restore the LMK table"
    grep '\[ -n "\$STALE" \] &&' $b/stop.sh | grep -q 'lmk_kernel_restore' || fail "$h stale stop does not restore the LMK table"
    case $h in pw6|k49) grep -q '^STALE_KEEP="[^"]* lmk.state ' $b/stop.sh || fail "$h: stale cleanup would delete lmk.state before the restore" ;; esac
    rm -rf $T/*; mkdir -p $T/w $T/sys
    echo 18432,23040,27648,32256,55296,80640 > $T/sys/minfree; echo 0,1,2,4,9,15 > $T/sys/adj
    printf 'MemTotal:         485000 kB\n' > $T/meminfo
    out=$(W=$T/w LMK_SYS=$T/sys LMK_MEMINFO=$T/meminfo sh -c '
        t() { echo "LOG $*"; }
        . '$b'/lib/memory.sh
        lmk_kernel_tune; lmk_kernel_tune; lmk_kernel_tune      # watchdog ticks
        echo "TUNED $(cat $LMK_SYS/minfree) $(cat $LMK_SYS/adj)"
        lmk_kernel_restore
        echo "BACK $(cat $LMK_SYS/minfree) $(cat $LMK_SYS/adj)"
        lmk_kernel_restore                                     # second stop: nothing saved, nothing changes
        echo "AGAIN $(cat $LMK_SYS/minfree) $(ls $W)"')
    echo "$out" | grep -q '^TUNED 2048,3072,4096,8192,14336,16384 0,100,200,300,900,906$' || fail "$h tune: $out"
    echo "$out" | grep -q '^BACK 18432,23040,27648,32256,55296,80640 0,1,2,4,9,15$' || fail "$h restore: $out"
    echo "$out" | grep -q '^AGAIN 18432,23040,27648,32256,55296,80640 *$' || fail "$h second restore / state left: $out"
    [ "$(echo "$out" | grep -c 'saved, restored on stop')" = 1 ] || fail "$h: tune should log once, not every watchdog tick"
    # 1 GB models: not touched at all
    printf 'MemTotal:         993636 kB\n' > $T/meminfo
    out=$(W=$T/w LMK_SYS=$T/sys LMK_MEMINFO=$T/meminfo sh -c 't() { :; }; . '$b'/lib/memory.sh; lmk_kernel_tune; lmk_kernel_restore; cat $LMK_SYS/minfree; ls $W')
    [ "$out" = 18432,23040,27648,32256,55296,80640 ] || fail "$h 1 GB model changed: $out"
done
echo "lmk-restore-test: OK"
