#!/bin/sh
# perf/boot-path: the boot critical path waits on the thing it needs instead of fixed sleeps / coarse polls.
#  display_start: no fixed 0.5 s; waits (<= 0.5 s) until veradroid-epd has the FIFO open
#  container_start: init pid polled every 50 ms (max 2 s, as before); slirp4netns every 0.1 s (max 10 s); virtual input every 50 ms (max 4 s)
# Static, plus the display wait run against a stub bridge (a process that opens a FIFO named epd.fifo after 0.2 s) on Linux.
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
for m in pw6 k49; do
    c=host/$m/boot/lib/container.sh; n=host/$m/boot/lib/network.sh; i=host/$m/boot/lib/input.sh
    for f in $c $n $i; do sh -n $f || fail "syntax $f"; done
    ds=$(awk '/^display_start\(\) \{/ { p = 1 } p { print } p && /^}/ { exit }' $c)
    echo "$ds" | grep -q 'usleep 500000' && fail "$c: display_start still sleeps 0.5 s"
    echo "$ds" | grep -q "ds_i -lt 25" && echo "$ds" | grep -q 'usleep 20000' || fail "$c: display_start wait is not 25 x 20 ms"
    echo "$ds" | grep -q "grep -q 'epd\\\\.fifo'" || fail "$c: display_start does not wait for the bridge's FIFO"
    awk '/read -r P _ < \/proc\/\$UPID\/task\/\$UPID\/children/ { r = NR } r && NR == r + 2 && /usleep 50000/ { ok = 1 } END { exit !ok }' $c || fail "$c: container pid poll not 50 ms"
    grep -q 'for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do' $c || fail "$c: container pid poll is not 40 rounds (2 s)"
    grep -q "while \[ \$i -lt 100 \] && ! grep -q 'sent tapfd' \$W/slirp.log 2>/dev/null; do usleep 100000" $n || fail "$n: slirp poll not 100 x 0.1 s"
    awk '/i=0; while \[ \$i -lt 80 \]; do/ { a = 1 } a && /usleep 50000; i=\$\(\(i \+ 1\)\)/ { ok = 1; exit } END { exit !ok }' $i || fail "$i: input poll not 80 x 50 ms"
done
if [ "$(uname)" = Linux ] && command -v python3 >/dev/null 2>&1; then
    T=$(mktemp -d) || exit 2
    trap 'rm -rf "$T"' EXIT
    mkdir -p $T/x $T/w/bin $T/w
    cat > $T/w/bin/veradroid-epd <<'EOS'
#!/bin/sh
exec python3 -c '
import os, sys, time
f = sys.argv[3]; time.sleep(0.2); os.mkfifo(f) if not os.path.exists(f) else None
fd = os.open(f, os.O_RDWR | os.O_NONBLOCK); time.sleep(3)' "$@"
EOS
    chmod +x $T/w/bin/veradroid-epd
    out=$(W=$T/w X=$T/x VD=$T/w sh -c 't() { echo "$*"; }; rot_args() { :; }; rot_deg() { echo 0; }; usleep() { sleep $(awk -v u=$1 "BEGIN{print u/1000000}"); }
        eval "$(awk "/^display_start\\(\\) \\{/ { p = 1 } p { print } p && /^}/ { exit }" host/pw6/boot/lib/container.sh)"; display_start' 2>&1)
    echo "$out" | grep -q 'display: bridge pid [0-9]* (ready after [0-9]* ms)' || fail "display_start output: $out"
    ms=$(echo "$out" | sed -n 's/.*ready after \([0-9]*\) ms.*/\1/p')
    [ "$ms" -ge 150 ] && [ "$ms" -lt 500 ] || fail "display_start returned after $ms ms (bridge ready at ~200 ms)"
    kill $(cat $T/w/epd.pid) 2>/dev/null
    echo "display wait ok: $ms ms"
fi
echo "PASS boot-path"
