#!/bin/sh
# 书库点“VeraDroid 启动”后不启动的每一条路，屏幕上都要有说明、日志里都要有一行（k49 1.09 PW5 用户：“点了只显示正在打开，什么都没有”）。
# 1. veradroid.sh 主流程里每个 exit 1 都要先 vd_notice（--in-ns / --in-chroot 两行和“等安装器”那段除外，后者在 if 里已经 vd_notice）；
#    不能再有 splash + sleep 5 + exit 的老写法（提示 5 秒后被书库重画盖掉）。
# 2. vd_notice：写进系统盘外面的 start.log；fbink 不可用时退回 eips 英文。
# 3. vd_lock_alive：锁里的 pid 活着但不是 veradroid.sh（pid 号被别的进程复用）= 残留锁。
# 4. storage_mount 摘不掉 loop 时先 img_release；img_holders 的设备号换算和内核 new_encode_dev 一致。
# host/k49 和 host/pw6 是同一套启动代码（fix/launch-silent-k49 移植到 pw6）：两份都查。
set -eu
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
cd "$(dirname "$0")/.."
if [ -z "${VD_LN_MODEL:-}" ]; then
    for m in k49 pw6; do VD_LN_MODEL=$m sh "$SELF" || exit 1; done
    echo "launch-notice: ok (k49, pw6)"; exit 0
fi
fail() { echo "FAIL (${VD_LN_MODEL:-}): $*"; exit 1; }
M=$VD_LN_MODEL; V=host/$M/boot/veradroid.sh; C=host/$M/boot/lib/common.sh; L=host/$M/VeraDroid-Launch.sh

# 1
awk 'NR > 40 && /exit 1/ && !/vd_notice/ && prev !~ /vd_notice/ {print NR": "$0} {prev=$0}' $V | grep . && fail "exit 1 without vd_notice in $V"
grep -n 'splash .*; sleep 5; exit' $V && fail "old splash+sleep+exit left in $V"
for w in 'already starting' 'already thawing'; do
    grep "$w" $V | grep -q 'vd_lock_alive' || fail "$w does not use vd_lock_alive"
    grep "$w" $V | grep -q 'framework_paused || vd_notice' || fail "$w notice may draw over the boot splash"
done

T=${TMPDIR:-/tmp}/vd-notice.$$; rm -rf "$T"; mkdir -p "$T/bin" "$T/boot"
trap 'rm -rf "$T"' EXIT
fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{" {p=1} p {print} p && /^}/ {exit}' $C; }
# 2
printf '#!/bin/sh\necho "eips $*" >> %s/eips.out\n' "$T" > "$T/bin/eips"; chmod 755 "$T/bin/eips"
cat > "$T/run.sh" <<EOF
PATH=$T/bin:\$PATH
t() { echo "t: \$*"; }
sleep() { :; }
FBINK=; KFONT=
VD_START_LOG=$T/logs/start.log
$(fn vd_slog)
$(fn vd_notice)
vd_notice "中文原因" "English reason" 10
EOF
sh "$T/run.sh" > "$T/out" 2>&1 || fail "vd_notice failed: $(cat "$T/out")"
grep -q 'English reason | 中文原因' "$T/logs/start.log" || fail "start.log has no line"
grep -q 'eips 1 3 VeraDroid: English reason' "$T/eips.out" || fail "no eips fallback"
[ "$(grep -c 'eips 1 3' "$T/eips.out")" = 3 ] || fail "notice not redrawn every 5 s for 10 s ($(grep -c 'eips 1 3' "$T/eips.out"))"
# 2b：日志写不进去 / 没有 setsid 时不能让 exec 把脚本悄悄弄死；书库入口每点一次记一行，屏幕上的话是 ASCII
grep -q 'if : >>"\$LOG" 2>/dev/null; then exec >>\$LOG 2>&1' $V || fail "exec >>\$LOG not guarded"
grep -q 'command -v setsid >/dev/null 2>&1 && command -v env' $V || fail "setsid detach not guarded"
grep -q 'library entry tapped' $L || fail "launcher does not log the tap"
grep '^ *eips ' $L | LC_ALL=C grep -q '[^ -~]' && fail "launcher eips text is not ASCII (eips cannot draw it)"
# 3（需要 Linux 的 /proc；macOS 上跳过）
if [ -r /proc/self/cmdline ]; then
    eval "$(grep '^vd_lock_alive()' $C)"
    sleep 30 & other=$!
    printf '#!/bin/sh\nsleep 30\n' > "$T/boot/veradroid.sh"; sh "$T/boot/veradroid.sh" & mine=$!
    vd_lock_alive "$mine" || fail "live veradroid.sh not seen as the lock holder"
    vd_lock_alive "$other" && fail "unrelated pid (reused number) seen as the lock holder"
    kill $other $mine 2>/dev/null; wait 2>/dev/null || true
    vd_lock_alive "$mine" && fail "dead pid seen as the lock holder"
    vd_lock_alive "" && fail "empty pid seen as the lock holder"
else echo "  (no /proc: vd_lock_alive runtime check skipped)"; fi
# 4
awk '/^storage_mount\(\)/ {p=1} p && /img_release \$\(img_loops\)/ {ok=1} p && /^}/ {exit} END {exit !ok}' $C || fail "storage_mount does not call img_release"
awk '/^img_release\(\)/ {p=1} p && /kill -0 "\$rp"/ {ok=1} p && /^}/ {exit} END {exit !ok}' $C || fail "img_release does not check for a running android"
for mm in 7:1 7:0 7:255 7:256 7:300 259:3; do
    ma=${mm%%:*}; mi=${mm##*:}
    got=$(printf '%x' $(( (ma << 8) | (mi & 255) | ((mi & ~255) << 12) )))
    want=$(python3 -c "print('%x' % ((($ma & 0xfff) << 8) | ($mi & 0xff) | (($mi & ~0xff) << 12)))")
    [ "$got" = "$want" ] || fail "dev $mm: $got != $want"
done
grep -q "printf '%x' \$(( (ma << 8) | (mi & 255) | ((mi & ~255) << 12) ))" $C || fail "img_holders encoding changed"
echo "  launch-notice $M: ok"
