#!/bin/sh
# compile_app_running (boot/lib/compile.sh) must still see an app's process when some other process exits between the
# /proc glob and the read. busybox awk given the files directly dies on the first one it cannot open (END never runs,
# exit 1 = "not running"), so a running app was compiled anyway and its dexopt stopped again, once a minute
# (PW5 user diagnostics 2026-11-21). No device needed: /proc is faked, a vanished process is a dangling status link.
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
FILES=${COMPILE_FILES:-"host/pw6/boot/lib/compile.sh host/k49/boot/lib/compile.sh"}
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
AWKS=awk
command -v busybox >/dev/null 2>&1 && busybox awk 'BEGIN{}' </dev/null 2>/dev/null && AWKS="awk busybox"
for C in $FILES; do
    [ -f "$C" ] || continue
    sh -n "$C" || fail "syntax $C"
    f=$(sed -n '/^compile_app_running()/,/^}/p' "$C")
    [ -n "$f" ] || fail "$C: no compile_app_running"
    printf '%s\n' "$f" | grep -v '^ *#' | grep -q "awk .*/proc/\[0-9\]\*/status" && fail "$C: awk reads /proc/*/status files directly"
    # fake /proc: 100 = vanished (dangling link, sorts first), 2000 = some process, 727 = the app (uid 10010)
    mkdir -p $T/proc/100 $T/proc/2000 $T/proc/727 $T/sys/data/system
    ln -sf $T/gone $T/proc/100/status
    printf 'Name:\tx\nUid:\t1000\t1000\t1000\t1000\n' > $T/proc/2000/status
    printf 'Name:\tweread\nUid:\t10010\t10010\t10010\t10010\n' > $T/proc/727/status
    echo "com.tencent.weread.eink 10010 0 /data/data/com.tencent.weread.eink default 3003" > $T/sys/data/system/packages.list
    echo "com.other 10020 0 /data/data/com.other default 3003" >> $T/sys/data/system/packages.list
    for a in $AWKS; do
        mkdir -p $T/bin; rm -f $T/bin/awk
        [ $a = busybox ] && { printf '#!/bin/sh\nexec busybox awk "$@"\n' > $T/bin/awk; chmod +x $T/bin/awk; }
        body=$(sed -n '/^compile_app_uid()/p; /^compile_app_running()/,/^}/p' "$C" | sed "s#/proc/#$T/proc/#g")
        PATH=$T/bin:$PATH SYS=$T/sys sh -c "$body
            compile_app_running com.tencent.weread.eink" || fail "$C ($a awk): running app not seen when another process vanished"
        PATH=$T/bin:$PATH SYS=$T/sys sh -c "$body
            compile_app_running com.other" && fail "$C ($a awk): an app with no process reported running"
        PATH=$T/bin:$PATH SYS=$T/sys sh -c "$body
            compile_app_running com.unknown" && fail "$C ($a awk): an unknown package reported running"
    done
    rm -rf $T/proc
done
echo "PASS compile-running ($AWKS)"
