#!/bin/sh
# Legacy 0.8.15: the 512 MB hang fixes of fix/1104-lowmem (70b67b0c), legacy equivalents (all legacy models are 512 MB):
#  a. big apps (dex >= 120 MB) compiled verify-at-runtime only (worker, light / invalid-odex paths); install / bg / first-boot dexopt too
#  b. lowmemorykiller small table: backup 32 MB, cached 56 / 64 MB (lmkd via vdlmk + kernel minfree)
#  c. host daemons at oom_score_adj -800, Android started at 0
#  d. 回到 Kindle fallback: the command listener did not take exit in 8 s -> veradroid.sh --exit; do_exit acks and locks
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
B=host/legacy/boot
C=$(pwd)/$B/lib/compile.sh
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
for f in $B/action.sh $B/veradroid.sh $B/lib/watchdog.sh $B/lib/compile.sh $B/lib/afterboot.sh $B/lib/memory.sh $B/lib/container.sh; do sh -n $f || fail "syntax $f"; done
# a. compile_pkg_mode / compile_needed with a fake dex size
for case in "low 243 speed verify-at-runtime" "low 60 speed speed" "high 243 speed speed" "low_off 243 speed speed"; do
    set -- $case
    out=$(sh -c '
        t() { :; }; W='$T'
        . '$C'
        lowmem_ram() { case "'$1'" in low|low_off) return 0 ;; esac; return 1; }
        compile_dex_mb() { echo '$2'; }
        [ "'$1'" = low_off ] && COMPILE_BIG_LOW=off
        compile_pkg_mode p '$3)
    [ "$out" = "$4" ] || fail "a: $case -> '$out'"
done
out=$(sh -c '
    t() { :; }; W='$T'
    . '$C'
    lowmem_ram() { return 0; }; compile_dex_mb() { echo 243; }; app_dir() { echo p-1; }; odex_filter() { echo verify-at-runtime; }
    compile_needed p && echo needed || echo done')
[ "$out" = done ] || fail "a: a big app with a verify-at-runtime odex is queued again on 512 MB"
out=$(sh -c '
    t() { :; }; W='$T'
    . '$C'
    lowmem_ram() { return 0; }; compile_dex_mb() { echo 40; }; app_dir() { echo p-1; }; odex_filter() { echo verify-at-runtime; }
    CLOG=/nonexistent; compile_needed p && echo needed || echo done')
[ "$out" = needed ] || fail "a: a small app must still be compiled to speed"
awk '/^compile_light\(\)/,/^}/' $C | grep -q 'compile_low_big "$1" && rf=verify-at-runtime' || fail "a: compile_light"
awk '/^compile_fix_invalid\(\)/,/^}/' $C | grep -q 'compile_low_big "$p" && ci_f=verify-at-runtime' || fail "a: compile_fix_invalid"
awk '/^compile_worker\(\)/,/^}/' $C | grep -q 'compile_one "$pkg" "$(compile_pkg_mode "$pkg" "$mode")"' || fail "a: worker does not use compile_pkg_mode"
grep -q "setprop pm.dexopt.install verify-at-runtime; setprop pm.dexopt.bg-dexopt verify-at-runtime" $B/lib/afterboot.sh || fail "a: afterboot install filter"
awk '/^heap_fix\(\)/,/^}/' $B/lib/memory.sh | grep -q '_prop pm.dexopt.first-boot verify-at-runtime' || fail "a: heap_fix first-boot filter"
# b
grep -q '"$VD/bin/vdlmk" "$s" 2048:0 3072:100 4096:200 8192:300 14336:900 16384:906' $B/lib/afterboot.sh || fail "b: lmkd table"
grep -q 'echo 2048,3072,4096,8192,14336,16384 > "$mf"' $B/lib/memory.sh || fail "b: kernel minfree"
# c, d static
grep -q '^host_oom_protect()' $B/lib/watchdog.sh || fail "c: no host_oom_protect"
awk '/^watchdog\(\)/,/^}/' $B/lib/watchdog.sh | grep -q 'host_oom_protect' || fail "c: watchdog does not call host_oom_protect"
awk '/^start_helpers\(\)/,/^}/' $B/veradroid.sh | grep -q 'host_oom_protect' || fail "c: start_helpers does not call host_oom_protect"
awk '/^container_start\(\)/,/^}/' $B/lib/container.sh | grep -q 'echo 0 > /proc/self/oom_score_adj' || fail "c: container not started at oom 0"
grep -q 'kindle|return) hint kindle "KINDLE|回 Kindle"; exit_send ;;' $B/action.sh || fail "d: kindle gesture does not use exit_send"
grep -q 'if \[ "$1" = "--exit" \]; then' $B/veradroid.sh || fail "d: veradroid.sh has no --exit"
awk '/^do_exit\(\)/,/^}/' $B/lib/watchdog.sh | grep -q 'touch $W/exit.ack' || fail "d: do_exit does not ack"
awk '/^start_helpers\(\)/,/^}/' $B/veradroid.sh | grep -q 'rm -rf $W/exiting $W/exit.ack' || fail "d: stale exit lock not cleared on start"
# c unit
mkdir -p $T/w $T/proc/123 $T/proc/456
echo 0 > $T/proc/123/oom_score_adj; echo 0 > $T/proc/456/oom_score_adj
echo 123 > $T/w/cmd.pid; echo 456 > $T/w/epd.pid; echo "x1" > $T/w/input.pid
awk '/^host_oom_protect\(\)/,/^}/' $B/lib/watchdog.sh | sed "s#/proc/#$T/proc/#g" > $T/hop.sh
W=$T/w sh -c ". $T/hop.sh; host_oom_protect" || fail "c: host_oom_protect failed"
[ "$(cat $T/proc/123/oom_score_adj)" = -800 ] && [ "$(cat $T/proc/456/oom_score_adj)" = -800 ] || fail "c: pids not protected"
# d unit: fallback when nothing acks, none when do_exit acks
mkdir -p $T/vd/boot $T/bin
printf '#!/bin/sh\nsleep 0.5\n' > $T/bin/usleep; printf '#!/bin/sh\nexec "$@"\n' > $T/bin/setsid; chmod +x $T/bin/usleep $T/bin/setsid
command -v usleep >/dev/null 2>&1 && rm -f $T/bin/usleep; command -v setsid >/dev/null 2>&1 && rm -f $T/bin/setsid
export PATH=$T/bin:$PATH
echo 'echo "FALLBACK $*" >> $FB' > $T/vd/boot/veradroid.sh
sleep 300 & SP=$!; echo $SP > $T/w/pid
awk '/^exit_send\(\)/,/^}/' $B/action.sh > $T/es.sh
rm -f $T/fb; FB=$T/fb W=$T/w VD=$T/vd AL=$T/al sh -c "send() { :; }; . $T/es.sh; exit_send"
i=0; while [ ! -s $T/fb ] && [ $i -lt 24 ]; do sleep 1; i=$((i + 1)); done
grep -q 'FALLBACK --exit' $T/fb 2>/dev/null || { kill $SP; fail "d: no fallback when the listener did not take exit"; }
rm -f $T/fb; FB=$T/fb W=$T/w VD=$T/vd AL=$T/al sh -c "send() { touch \$W/exit.ack; }; . $T/es.sh; exit_send"
sleep 10; [ -e $T/fb ] && { kill $SP; fail "d: fallback ran although exit was taken"; }
{ kill $SP; wait $SP; } 2>/dev/null
echo "legacy-lowmem-0815: OK"
