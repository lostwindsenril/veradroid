#!/bin/sh
# 512 MB 换页卡死（fix/1104-lowmem，2026-11-21 用户：番茄卡住后桌面点不动、“回到 Kindle”没反应，只能强制重启）：
#  a. 512 MB 机型的大应用只编 verify-at-runtime；安装 / 后台 dexopt 也是（afterboot），系统更新后第一次开机也是（ram-512.conf）
#  b. lowmemorykiller 小内存表：缓存的应用 56 / 64 MB 就杀（前台 / 可见 / 可感知不变）
#  c. 宿主进程 oom_score_adj -800，Android 本身按 0 起
#  d. 回到 Kindle 的后备：命令监听 8 秒没接走 exit，action.sh 自己起 veradroid.sh --exit；do_exit 有锁、接到就写 exit.ack
cd "$(dirname "$0")/.." || exit 2
fail() { echo "FAIL: $*"; exit 1; }
cmp -s host/pw6/boot/lib/compile.sh host/k49/boot/lib/compile.sh || fail "host/k49 compile.sh differs from host/pw6"
C=$(pwd)/host/pw6/boot/lib/compile.sh
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
# a. compile_pkg_mode / compile_light_filter / compile_done_filter
for case in "low big none" "low big prof" "low small none" "high big prof" "high big none" "low_off big prof"; do
    set -- $case
    out=$(sh -c '
        t() { :; }; W='$T'
        . '$C'
        lowmem_ram() { [ "$1" = low ] || [ "$1" = low_off ]; }
        compile_big() { [ "'$2'" = big ]; }
        compile_has_profile() { [ "'$3'" = prof ]; }
        compile_timed_out() { return 1; }
        lowmem_ram() { case "'$1'" in low|low_off) return 0 ;; esac; return 1; }
        [ "'$1'" = low_off ] && COMPILE_BIG_LOW=off
        echo "$(compile_pkg_mode p speed) $(compile_light_filter p)"')
    case "$case" in
        "low big none"|"low big prof") want="verify-at-runtime verify-at-runtime" ;;
        "low small none") want="speed interpret-only" ;;
        "high big prof"|"low_off big prof") want="speed-profile interpret-only" ;;
        "high big none") want="interpret-only interpret-only" ;;
    esac
    [ "$out" = "$want" ] || fail "a: $case -> '$out', want '$want'"
done
sh -c ". $C; compile_done_filter verify-at-runtime verify-at-runtime && compile_done_filter interpret-only verify-at-runtime && ! compile_done_filter '' verify-at-runtime" || fail "a: compile_done_filter verify-at-runtime"
sed -n '/^compile_light()/,/^}/p' $C | grep -q 'compile_low_big "$1"' || fail "a: compile_light does not use verify-at-runtime for big apps on 512 MB"
for h in pw6 k49; do
    awk '/pm.dexopt.install verify-at-runtime/' host/$h/boot/lib/afterboot.sh | grep -q 'bg-dexopt verify-at-runtime' || fail "a: $h afterboot install filter"
done
for h in pw6 k49; do awk '/^heap_fix\(\)/,/^}/' host/$h/boot/lib/memory.sh | grep -q '_prop pm.dexopt.first-boot verify-at-runtime' || fail "a: $h heap_fix first-boot filter"; done
# b
for h in pw6 k49 legacy; do
    # combined tree: host/legacy is the legacy line's own release (docs/legacy-line.md); checked once it has the change
    [ $h = legacy ] && ! grep -qs '"2048:0 3072:100 4096:200 8192:300 14336:900 16384:906"' host/legacy/boot/lib/memkeep.sh && { echo "  note: host/legacy has no 512 MB lmkd table yet - skipped"; continue; }
    grep -q '"2048:0 3072:100 4096:200 8192:300 14336:900 16384:906"' host/$h/boot/lib/memkeep.sh || fail "b: $h lmkd table"
    grep -q 'echo 2048,3072,4096,8192,14336,16384 > "$mf"' host/$h/boot/lib/memory.sh || fail "b: $h kernel minfree"
done
# c, d
for h in pw6 k49; do
    b=host/$h/boot
    grep -q '^host_oom_protect()' $b/lib/watchdog.sh || fail "c: $h no host_oom_protect"
    awk '/^watchdog\(\)/,/^}/' $b/lib/watchdog.sh | grep -q 'host_oom_protect' || fail "c: $h watchdog does not call host_oom_protect"
    awk '/^start_helpers\(\)/,/^}/' $b/veradroid.sh | grep -q 'host_oom_protect' || fail "c: $h start_helpers does not call host_oom_protect"
    awk '/^container_start\(\)/,/^}/' $b/lib/container.sh | grep -q 'echo 0 > /proc/self/oom_score_adj' || fail "c: $h container not started at oom 0"
    grep -q 'kindle|return) hint kindle "KINDLE|回 Kindle"; exit_send ;;' $b/action.sh || fail "d: $h kindle gesture does not use exit_send"
    grep -q 'exec setsid sh $VD/boot/veradroid.sh --exit' $b/action.sh || fail "d: $h exit_send has no fallback"
    grep -q 'if \[ "$1" = "--exit" \]; then' $b/veradroid.sh || fail "d: $h veradroid.sh has no --exit"
    awk '/^do_exit\(\)/,/^}/' $b/lib/watchdog.sh | grep -q 'touch $W/exit.ack' || fail "d: $h do_exit does not ack"
    sh -n $b/action.sh && sh -n $b/veradroid.sh && sh -n $b/lib/watchdog.sh || fail "syntax $h"
done
# c unit: host_oom_protect writes -800 only for live numeric pids from the pid files
mkdir -p $T/w $T/proc/123 $T/proc/456
echo 0 > $T/proc/123/oom_score_adj; echo 0 > $T/proc/456/oom_score_adj
echo 123 > $T/w/cmd.pid; echo 456 > $T/w/input.pid; echo "x1" > $T/w/epd.pid
awk '/^host_oom_protect\(\)/,/^}/' host/k49/boot/lib/watchdog.sh | sed "s#/proc/#$T/proc/#g" > $T/hop.sh
W=$T/w sh -c ". $T/hop.sh; host_oom_protect" || fail "c: host_oom_protect failed"
[ "$(cat $T/proc/123/oom_score_adj)" = -800 ] && [ "$(cat $T/proc/456/oom_score_adj)" = -800 ] || fail "c: pids not protected"
echo 0 > $T/proc/123/oom_score_adj
W=$T/w HOST_OOM_ADJ= sh -c ". $T/hop.sh; host_oom_protect"
[ "$(cat $T/proc/123/oom_score_adj)" = 0 ] || fail "c: HOST_OOM_ADJ= must turn it off"
# d unit: exit_send falls back when nothing acks, and not when do_exit acks
mkdir -p $T/vd/boot $T/x/ctl $T/bin
# busybox 的 usleep / setsid 在 Mac 上没有：垫一下
printf '#!/bin/sh\nsleep 0.5\n' > $T/bin/usleep; printf '#!/bin/sh\nexec "$@"\n' > $T/bin/setsid; chmod +x $T/bin/usleep $T/bin/setsid
command -v usleep >/dev/null 2>&1 && rm -f $T/bin/usleep; command -v setsid >/dev/null 2>&1 && rm -f $T/bin/setsid
export PATH=$T/bin:$PATH
cat > $T/vd/boot/veradroid.sh <<'E'
echo "FALLBACK $*" >> $FB
E
sleep 300 & SP=$!; echo $SP > $T/w/pid
awk '/^exit_send\(\)/,/^}/' host/k49/boot/action.sh > $T/es.sh
rm -f $T/fb; FB=$T/fb W=$T/w VD=$T/vd AL=$T/al sh -c "send() { :; }; . $T/es.sh; exit_send"
i=0; while [ ! -s $T/fb ] && [ $i -lt 24 ]; do sleep 1; i=$((i + 1)); done
grep -q 'FALLBACK --exit' $T/fb 2>/dev/null || { kill $SP; fail "d: no fallback when the listener did not take exit"; }
rm -f $T/fb; FB=$T/fb W=$T/w VD=$T/vd AL=$T/al sh -c "send() { touch \$W/exit.ack; }; . $T/es.sh; exit_send"
sleep 10; [ -e $T/fb ] && { kill $SP; fail "d: fallback ran although exit was taken"; }
{ kill $SP; wait $SP; } 2>/dev/null
echo "lowmem-hang-1104-test: OK"
