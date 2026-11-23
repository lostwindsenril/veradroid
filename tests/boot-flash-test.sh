#!/bin/sh
# perf/boot-flash: after_boot sends its "safety" full refresh only when the splash's full refresh did not reach the panel.
# The snippet is cut out of afterboot.sh and run against a fake epd.log (pw6 + k49; legacy: perf/legacy-boot).
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
for f in ${FILES:-host/pw6/boot/lib/afterboot.sh host/k49/boot/lib/afterboot.sh}; do
    [ -f $f ] || continue
    sh -n $f || fail "syntax $f"
    awk 'index($0, "    if grep -q '"'"'full=1 .*-> 0 ('"'"' $W/epd.log") == 1 { p = 1 } p { print } p && /^    fi$/ { exit }' $f > $T/snip.sh
    [ -s $T/snip.sh ] || fail "$f: conditional full refresh block not found"
    grep -c '^    epd_send FULL$' $f | grep -qx 0 || fail "$f: an unconditional epd_send FULL is still there"
    run() { : > $T/sent; W=$T sh -c "t() { :; }; epd_send() { echo \"\$*\" >> $T/sent; }; sleep() { :; }; . $T/snip.sh"; cat $T/sent; }
    # splash FULL went out (new-model and legacy log formats)
    printf '%s\n' 'epd: PaperWhite 6' '[1] epd: 1272x1696+0+0 mode=1 wfm=2 full=1 flash=1 anim=0 -> 0 (7 ms) FLASH' > $T/epd.log
    [ -z "$(run)" ] || fail "$f: second FULL sent although the first one reached the panel"
    printf '%s\n' '[1] epd: 1072x1448+0+0 mode=1 wfm=2 full=1 anim=0 -> 0 (9 ms)' > $T/epd.log
    [ -z "$(run)" ] || fail "$f: second FULL sent (legacy log format)"
    # no full refresh yet / it failed / no log
    printf '%s\n' '[1] epd: 16x17+216+1350 mode=0 wfm=0 full=0 flash=0 anim=0 -> 0 (0 ms)' > $T/epd.log
    [ "$(run)" = FULL ] || fail "$f: no FULL when the splash refresh is missing"
    printf '%s\n' '[1] epd: 1272x1696+0+0 mode=1 wfm=2 full=1 flash=1 anim=0 -> -1 (7 ms) FLASH' > $T/epd.log
    [ "$(run)" = FULL ] || fail "$f: no FULL when the splash refresh failed"
    rm -f $T/epd.log
    [ "$(run)" = FULL ] || fail "$f: no FULL without a bridge log"
done
echo "PASS boot-flash"
