#!/bin/sh
# 老机型“在 Android 里点更新装不上”（2026-11-20，PW4 / KO3 用户；docs 见本分支 fix/legacy-inapp-update 的提交说明）：
#  1. 安装器内嵌的进度画面代码（vd_progress）和 host/pw6/boot/lib/progress.sh 一字不差（tools/sync-progress.sh 同步）。
#  2. bk_prune：备份前把清单里已经不在的文件去掉，累计大小（bk_progress 按行对应）一起重算；文件都在时清单不变。
#  3. 备份失败的处理：因文件在变而失败时重挑一次再备份；emulator-only 机型没备份成时，空间不够和备份出错分开说（以前一律说“空间不够”）。
#  4. 失败要让用户看得到：die 写 state/update.result 并画出错画面；停 Android 时起 vd_guard（Android 重新起来后把结果写回 ctl/update.status，
#     Kindle 界面没放出来又没有 Android 时负责恢复）；Android 在前台的手动更新停 Android 时不放出 Kindle 界面（$W/restarting）。
#  5. 宿主 cmd.sh 的 fullupdate：设 VD_FROM_HOME=1，安装器先走直链、有超时、语法检查过才跑。
#  6. busybox 风格的 tar 在清单里有不存在的文件时失败（真机 / 模拟器上的现象），bk_prune 之后同一份清单能打包。
set -eu
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $*"; exit 1; }
L=cloud/static/bootstrap-legacy.sh
sh -n $L || fail "syntax $L"
blk() { sed -n "/^# BEGIN $1\$/,/^# END $1\$/p" "$2"; }
# combined tree (docs/legacy-line.md): host/pw6 is the new-model line, the legacy installer embeds the legacy line's own
# copy of progress.sh, so only check that the block is there and complete
blk vd_progress $L | grep -q '^vp_netcheck()' || fail "vd_progress block in $L missing or incomplete"
grep -q 'cloud/static/bootstrap-legacy.sh' tools/sync-progress.sh || fail "sync-progress.sh does not update $L"

# ---- 2. bk_prune ----
W=$(mktemp -d "${TMPDIR:-/tmp}/vd-liu.XXXXXX"); trap 'rm -rf "$W"' EXIT
fn() { sed -n "/^$1() {/,/^}/p" $L; }
fn bk_prune > $W/fn.sh
[ -s $W/fn.sh ] || fail "no bk_prune()"
mkdir -p $W/us/documents/b.sdr
for f in a.azw3 b.azw3 b.sdr/b.azw3f c.txt; do echo "$f" > "$W/us/documents/$f"; done
printf '%s\n' documents/a.azw3 documents/b.azw3 documents/b.sdr/b.azw3f documents/c.txt > $W/bkl
printf '%s\n' 10 30 31 40 > $W/bkc
cat > $W/run.sh <<EOF
set -eu
vlog() { echo "LOG \$*" >> $W/log; }
BKL=$W/bkl; BKC=$W/bkc; BK_NEEDK=40; need=40
. $W/fn.sh
sed 's#/mnt/us/#$W/us/#' $W/fn.sh > $W/fn2.sh; . $W/fn2.sh
bk_prune
echo "need=\$need needk=\$BK_NEEDK"
EOF
out=$(sh $W/run.sh) || fail "bk_prune (all present) failed"
[ "$(cat $W/bkl | wc -l | tr -d ' ')" = 4 ] && [ "$(tr '\n' ' ' < $W/bkc)" = "10 30 31 40 " ] || fail "bk_prune changed a list whose files all exist: $(tr '\n' ' ' < $W/bkc)"
rm "$W/us/documents/b.sdr/b.azw3f"
out=$(sh $W/run.sh) || fail "bk_prune (one gone) failed"
[ "$(tr '\n' ' ' < $W/bkl)" = "documents/a.azw3 documents/b.azw3 documents/c.txt " ] || fail "bk_prune list: $(tr '\n' ' ' < $W/bkl)"
[ "$(tr '\n' ' ' < $W/bkc)" = "10 30 39 " ] || fail "bk_prune sizes: $(tr '\n' ' ' < $W/bkc)"
case "$out" in *"need=39 needk=39"*) ;; *) fail "bk_prune need: $out" ;; esac
grep -q "gone since the selection, left out: documents/b.sdr/b.azw3f" $W/log || fail "bk_prune did not log the missing file"

# ---- 6. tar：清单里有不存在的文件时失败（busybox：rc=1 + "error exit delayed"），去掉以后打包成功 ----
printf '%s\n' documents/a.azw3 documents/gone.kfx > $W/l2
if ( cd $W/us && tar -cf - -T $W/l2 >/dev/null 2>&1 ); then echo "note: this tar ignores missing list entries"; else :; fi
( cd $W/us && tar -cf - -T $W/bkl >/dev/null ) || fail "tar of the pruned list failed"

# ---- 3. 备份失败的处理 ----
grep -q 'bk_prune$' $L || fail "backup loop does not call bk_prune"
grep -q 'bk_try -lt 2' $L || fail "no second backup attempt"
grep -q 'BK_RESULT" = nospace' $L || fail "emulator-only die does not tell no-space from a failed backup"
grep -q 'DIE_CODE=22 die "安装前的书库备份没做成' $L || fail "failed backup still reported as no space"
grep -q '\[ "\$TESTED" = emulator-only \] || show "Pre-install backup failed, installing anyway' $L || fail "emulator-only still says 'installing anyway' before stopping"

# ---- 4. 失败看得到、Kindle 界面能回来 ----
fn die | grep -q 'vd_result error' || fail "die does not record the result"
fn die | grep -q 'vp_error' || fail "die does not draw the error screen"
fn die | grep -q 'Update/install failed' || fail "die has no English line for eips"
fn install_stop_android | grep -q 'vd_guard' || fail "install_stop_android does not start vd_guard"
fn install_stop_android | grep -q 'W/restarting' || fail "manual update does not keep the Kindle UI stopped"
fn install_stop_android | grep -q 'VD_AUTOUPDATE:-0}" != 1' || fail "auto updates must not keep the Kindle UI stopped"
fn vd_guard | grep -q 'stop.sh' || fail "vd_guard has no way back to the Kindle UI"
fn vd_guard | grep -q 'update.status' || fail "vd_guard does not write the result for VeraHome"
grep -q 'vd_result done 0 "已更新到' $L || fail "success not recorded"
grep -q 'vd-fullupdate-bootstrap.sh) VD_FROM_HOME=1' $L || fail "installer does not recognise the 0.8.13 host's fullupdate wrapper"
grep -q '^VP_STATUS=\$W/kfb/ctl/update.status' $L || fail "no progress status for VeraHome"
[ "$(grep -c 'state=done result=latest' $L)" -ge 2 ] || fail "up-to-date exits leave the card on 'connecting'"

# ---- 离线包和已装的是同一版（“无需重装”）：离线包也清掉；只在离线安装时 ----
sed -n '/完整性检查通过，无需重装/,/exit 0/p' $L | grep -q '^ *remove_offline_package$' || fail "the 无需重装 exit does not remove the offline bundle"
fn remove_offline_package | sed -n 2p | grep -q 'VD_OFFLINE_BUNDLE:-}" \] || return 0' || fail "remove_offline_package must do nothing without VD_OFFLINE_BUNDLE (online / auto update)"
# 函数本身：没有 VD_OFFLINE_BUNDLE 时不删；有时只删固定文件名的包
mkdir -p $W/off; : > $W/off/veradroid-legacy-0.8.13.tar.gz; : > $W/off/mybook.tar.gz
fn is_offline_readme > $W/rop.sh; fn remove_offline_package >> $W/rop.sh
( set -eu; . $W/rop.sh; VD_OFFLINE_BUNDLE=; VD_HELPER=; remove_offline_package ) || fail "remove_offline_package (online) failed"
[ -f $W/off/veradroid-legacy-0.8.13.tar.gz ] || fail "online run removed an offline bundle"
( set -eu; . $W/rop.sh; VD_OFFLINE_BUNDLE=$W/off/veradroid-legacy-0.8.13.tar.gz; VD_HELPER=; remove_offline_package ) || fail "remove_offline_package (offline) failed"
[ ! -f $W/off/veradroid-legacy-0.8.13.tar.gz ] && [ -f $W/off/mybook.tar.gz ] || fail "offline cleanup removed the wrong files"

# ---- 5. 宿主 cmd.sh ----
C=host/legacy/boot/lib/cmd.sh
sh -n $C || fail "syntax $C"
grep -q 'export VD_FROM_HOME=1' $C || fail "cmd.sh fullupdate does not set VD_FROM_HOME"
grep -q 'D/static/bootstrap-legacy.sh' $C || fail "cmd.sh fullupdate does not try the direct link"
grep 'fullupdate)' -A3 $C | grep -q 'max-time' || fail "cmd.sh fullupdate download has no time limit"

# ---- VeraHome：点了更新有进度对话框，失败回到桌面时说原因 ----
J=android/packages/VeraHome/src/com/veradroid/home/SysUpdate.java
# combined tree: VeraHome is the new-model one (the legacy line's VeraHome is checked on its own branch); check once it has the dialog
if grep -q 'static void progress(Activity a, String latest)' $J; then
    grep -q 'new TaskCards.Update(a, false)' $J || fail "progress dialog without the update card"
    grep -q 'maybeShowFailure(a)' $J || fail "failure is not shown on the home screen"
else
    echo "  note: new-model VeraHome has no in-app update progress dialog yet - VeraHome part skipped"
fi
echo "legacy-inapp-update-test OK"
