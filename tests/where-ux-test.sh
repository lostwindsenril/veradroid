#!/bin/sh
# “东西放在哪”（2026-11-19，feat/ux-where）：用户找不到安装程序、书库入口、屏保文件夹。
#  1. 安装程序在书库里的标题说清楚是安装（在线 / 离线），书库入口叫“VeraDroid 启动”，程序目录里的备用入口标题说明可以拷进 documents。
#  2. 离线包的 README.txt 第一行“把下面 3 个文件放进 documents”，安装器仍认得出它（装完删掉、不算用户的书），也认得旧的那种。
#  3. vd_where_notes（veradroid/说明.txt、veradroid/screensaver/把屏保图片放这里.txt）在 bootstrap*.sh 和 tidy.sh 里一字不差，
#     set -eu 下跑不会失败，重复跑不改文件。
#  4. 书库入口：launcher_restore 补回入口（标题改回正式的）、launcher_ensure 改旧标题、被新书挤下去时排回前面；
#     veradroid.sh 每次启动都调 launcher_restore；KUAL 菜单有“恢复书库入口”。
#  5. Android 的 内部存储/Screensaver 开机建好（777）并有说明；桌面屏保页写着三个放图的地方和找到几张。
cd "$(dirname "$0")/.." || exit 2
fail=0
F() { echo "FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
title() { sed -n '2s/^# Name: //p' "$1"; }
# 新机型家族（bootstrap.sh + host/pw6、k49）和老机型家族（bootstrap-legacy.sh + host/legacy）各在自己的分支上发：
# 只查这个分支里已经有这次改动的家族
NEWF=; grep -q '^vd_launch_backup()' cloud/static/bootstrap.sh 2>/dev/null && NEWF=1
LEG=; grep -q '^vd_launch_backup()' cloud/static/bootstrap-legacy.sh 2>/dev/null && LEG=1

# ---- 1. titles ----
[ "$(title cloud/static/VeraDroid.sh)" = "VeraDroid 安装（在线）" ] || F "VeraDroid.sh title: $(title cloud/static/VeraDroid.sh)"
[ "$(title cloud/static/VeraDroid-Offline.sh)" = "VeraDroid 安装（离线）" ] || F "VeraDroid-Offline.sh title"
[ "$(title cloud/static/VeraDroid-Experimental.sh)" = "VeraDroid 安装（在线，实验机型）" ] || F "VeraDroid-Experimental.sh title"
[ ! -f cloud/static/VeraDroid-Legacy.sh ] || [ "$(title cloud/static/VeraDroid-Legacy.sh)" = "VeraDroid 安装（在线，老机型）" ] || F "VeraDroid-Legacy.sh title"
for f in cloud/static/VeraDroid-Launch.sh host/*/VeraDroid-Launch.sh; do
    case "$f" in host/legacy/*) [ -n "$LEG" ] || continue ;; host/*) [ -n "$NEWF" ] || continue ;; esac   # old copy in the other family's tree
    [ "$(title "$f")" = "VeraDroid 启动" ] || F "$f title: $(title "$f")"
done
# the old-model README belongs to the legacy family: checked only in a tree whose old-model installer has these changes
READMES=; [ -n "$NEWF" ] && READMES="cloud/offline/README-pw6.txt cloud/offline/README-k49.txt"; [ -n "$LEG" ] && READMES="$READMES cloud/offline/README-legacy.txt"
grep -q '在书库里点“VeraDroid 离线安装”\|再点“VeraDroid 离线安装”' cloud/static/VeraDroid-Offline.sh $READMES && F "old offline title still shown"
for B in cloud/static/bootstrap.sh cloud/static/bootstrap-legacy.sh; do
    grep -q '^vd_launch_backup()' "$B" 2>/dev/null || continue
    grep -q "Name: VeraDroid 启动（备用，可拷进 documents）" "$B" || F "$B: backup entry title"
    grep -q "sed 's/^# Name: .\*/# Name: VeraDroid 启动/' \"\$TMP/veradroid-pw6/VeraDroid-Launch.sh\" > \"\$D/VeraDroid 启动.sh\"" "$B" || F "$B: library entry not written with the VeraDroid 启动 title"
    # 函数要在增量更新（patch）用到之前定义
    [ "$(grep -n '^vd_launch_backup()' "$B" | cut -d: -f1)" -lt "$(grep -n '^    vd_launch_backup$' "$B" | head -1 | cut -d: -f1)" ] || F "$B: vd_launch_backup used before it is defined"
done

# ---- 2. offline README ----
for B in cloud/static/bootstrap.sh cloud/static/bootstrap-legacy.sh; do
    [ -f "$B" ] || continue
    fn=$(sed -n '/^is_offline_readme() {/,/^}/p' "$B"); [ -n "$fn" ] || { F "$B: no is_offline_readme"; continue; }
    eval "$fn"
    for r in $READMES; do
        case "$B:$r" in *bootstrap.sh:*README-legacy.txt) continue ;; *bootstrap-legacy.sh:*README-pw6.txt|*bootstrap-legacy.sh:*README-k49.txt) continue ;; esac
        is_offline_readme "$r" || F "$B does not recognise $r"
    done
    printf '%s\n' 'VeraDroid 离线整包（Kindle PaperWhite 6 / Colorsoft）。把这 3 个文件全部放进 Kindle 的 documents' > "$T/old.txt"
    is_offline_readme "$T/old.txt" || F "$B: old README no longer recognised"
    printf '%s\n' '把下面 3 个文件放进 documents' 'my notes' > "$T/user.txt"
    is_offline_readme "$T/user.txt" && F "$B: a user README with a similar first line counts as ours"
done
for r in $READMES; do
    [ -f "$r" ] || continue
    head -1 "$r" | grep -q '^把下面 3 个文件放进 documents（VeraDroid 离线安装包' || F "$r: first line"
    grep -q 'VeraDroid-Offline.sh.*VeraDroid 安装（离线）' "$r" || F "$r: does not say which file is the installer"
    [ "$(wc -c < "$r")" -lt 4096 ] || F "$r: too big for is_offline_readme"
done

# ---- 3. vd_where_notes ----
blk() { sed -n '/^# BEGIN vd_where_notes/,/^# END vd_where_notes/p' "$1"; }
ref=; for f in cloud/static/bootstrap.sh cloud/static/bootstrap-legacy.sh host/*/boot/lib/tidy.sh; do
    [ -f "$f" ] || continue; b=$(blk "$f"); [ -n "$b" ] || continue
    [ -z "$ref" ] && { ref=$b; rf=$f; continue; }
    [ "$b" = "$ref" ] || F "vd_where_notes in $f differs from $rf"
done
[ -n "$ref" ] || F "no vd_where_notes block"
# 各家族（新机型：bootstrap.sh + host/pw6、k49；老机型：bootstrap-legacy.sh + host/legacy）有了这次的改动时，块必须都在
[ -n "$NEWF$LEG" ] || F "neither installer has these changes"
req=; [ -n "$NEWF" ] && req="host/pw6/boot/lib/tidy.sh host/k49/boot/lib/tidy.sh cloud/static/bootstrap.sh"
[ -n "$LEG" ] && req="$req host/legacy/boot/lib/tidy.sh cloud/static/bootstrap-legacy.sh"
for f in $req; do
    [ -n "$(blk "$f")" ] || F "$f: no vd_where_notes block"
done
printf '%s\n' "$ref" > "$T/where.sh"
mkdir -p "$T/top/veradroid"
VD_TOP=$T/top sh -eu -c ". '$T/where.sh'; vd_where_notes; echo done" | grep -q done || F "vd_where_notes fails under sh -eu"
[ -s "$T/top/veradroid/说明.txt" ] || F "说明.txt not written"
[ -s "$T/top/veradroid/screensaver/把屏保图片放这里.txt" ] || F "screensaver note not written"
for w in screensaver update VeraDroid-Launch.sh VeraDroid-Uninstall.sh logs backup KUAL; do grep -q "$w" "$T/top/veradroid/说明.txt" || F "说明.txt does not mention $w"; done
touch -t 202001010000 "$T/top/veradroid/说明.txt"
VD_TOP=$T/top sh -eu -c ". '$T/where.sh'; vd_where_notes"
[ -z "$(find "$T/top/veradroid/说明.txt" -newer "$T/where.sh" 2>/dev/null)" ] || F "vd_where_notes rewrites an unchanged note"
echo old > "$T/top/veradroid/说明.txt"
VD_TOP=$T/top sh -eu -c ". '$T/where.sh'; vd_where_notes"; grep -q screensaver "$T/top/veradroid/说明.txt" || F "outdated note not replaced"
ls "$T/top/veradroid" | grep -q '\.tmp$' && F "temp file left behind"
mkdir -p "$T/top2/veradroid"; : > "$T/top2/veradroid/screensaver"          # a file where the folder should be
VD_TOP=$T/top2 sh -eu -c ". '$T/where.sh'; vd_where_notes; echo done" | grep -q done || F "vd_where_notes fails when screensaver is a file"
VD_TOP=$T/none sh -eu -c ". '$T/where.sh'; vd_where_notes; echo done" | grep -q done || F "vd_where_notes fails without veradroid/"
[ -e "$T/none" ] && F "vd_where_notes created veradroid/ on a device without VeraDroid"
for B in cloud/static/bootstrap.sh cloud/static/bootstrap-legacy.sh; do
    [ -n "$(blk "$B" 2>/dev/null)" ] || continue
    grep -q '^vd_where_notes$' "$B" || F "$B: installer does not write the notes"
done

# ---- 4. library entry ----
for v in pw6 k49 legacy; do
    fw=host/$v/boot/lib/framework.sh; [ -f "$fw" ] || continue
    fam=$NEWF; [ $v = legacy ] && fam=$LEG
    grep -q '^launcher_restore()' "$fw" || { [ -z "$fam" ] && continue; F "$fw: no launcher_restore"; continue; }
    vs=host/$v/boot/veradroid.sh
    a=$(grep -n '^type launcher_restore >/dev/null 2>&1 && launcher_restore$' "$vs" | cut -d: -f1)
    b=$(grep -n '^P=$(cat $W/pid 2>/dev/null)$' "$vs" | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || F "$vs: launcher_restore not called on every start (before the running / frozen check)"
    grep -q '^type vd_where_notes >/dev/null 2>&1 && vd_where_notes$' "$vs" || F "$vs: notes not written on start"
    # functional: fake documents / program dir, stubbed lipc and sqlite3
    D=$T/$v; rm -rf "$D"; mkdir -p "$D/docs" "$D/vd" "$D/bin"
    sed 's/^# Name: .*/# Name: VeraDroid 启动（备用，可拷进 documents）/' host/$v/VeraDroid-Launch.sh > "$D/vd/VeraDroid-Launch.sh"
    printf '#!/bin/sh\necho "$*" >> %s/lipc.log\n' "$D" > "$D/bin/lipc-set-prop"
    printf '#!/bin/sh\ncase "$2" in *"count(*) from Entries where p_location"*) echo 1 ;; *"VeraDroid-%%"*) echo 50 ;; *"max(p_lastAccess)"*) echo 100 ;; *"p_lastAccess>100"*) cat %s/newer ;; esac\n' "$D" > "$D/bin/sqlite3"
    chmod 755 "$D/bin/"*; : > "$D/cc.db"; echo 0 > "$D/newer"
    fns=$(sed -n '/^LAUNCH_ENTRY=/p; /^launcher_restore() {/,/^}/p; /^launcher_ensure() {/,/^}/p' "$fw" \
        | sed -e "s#/mnt/us/documents#$D/docs#g" -e "s#/var/local/cc.db#$D/cc.db#g")
    run() { PATH=$D/bin:$PATH VD=$D/vd SYS=$D sh -c "t() { echo \"\$*\" >> $D/t.log; }; $fns
$1"; }
    run launcher_ensure
    E="$D/docs/VeraDroid 启动.sh"
    [ -f "$E" ] || F "$v: launcher_ensure did not restore the entry"
    [ "$(title "$E")" = "VeraDroid 启动" ] || F "$v: restored entry title: $(title "$E")"
    grep -q "reScanFile $E" "$D/lipc.log" 2>/dev/null || F "$v: restored entry not indexed"
    cmp -s "$E" host/$v/VeraDroid-Launch.sh || F "$v: restored entry differs from the shipped one apart from the title"
    run 'launcher_restore && echo again' | grep -q again && F "$v: launcher_restore overwrote an existing entry"
    sed -i.bak '2s/.*/# Name: VeraDroid/' "$E"; rm -f "$E.bak"; : > "$D/lipc.log"
    run launcher_ensure
    [ "$(title "$E")" = "VeraDroid 启动" ] || F "$v: old title not changed"
    [ -x "$E" ] || F "$v: entry lost its mode"
    ls "$D/docs" | grep -q '\.tmp$' && F "$v: temp file left in documents"
    # pushed back by newer books: brought forward; not when it is near the front
    : > "$D/lipc.log"; echo 2 > "$D/newer"; mkdir -p "$E.sdr"; : > "$E.sdr/icon.png"
    run launcher_ensure; grep -q reScanFile "$D/lipc.log" && F "$v: entry re-indexed although only 2 items are newer"
    echo 7 > "$D/newer"; run launcher_ensure; grep -q "reScanFile $E" "$D/lipc.log" || F "$v: entry behind 7 newer items not brought forward"
    # no backup entry in the program dir: nothing happens, no error
    rm -f "$E" "$D/vd/VeraDroid-Launch.sh"; run 'launcher_restore || echo none' | grep -q none || F "$v: launcher_restore without a backup entry"
    [ -e "$E" ] && F "$v: empty entry written"
done

# KUAL
for k in host/*/kual; do
    case "$k" in host/legacy/*) [ -n "$LEG" ] || continue ;; *) [ -n "$NEWF" ] || continue ;; esac
    [ -f "$k/restore-entry.sh" ] || { F "$k: no restore-entry.sh"; continue; }
    sh -n "$k/restore-entry.sh" || F "$k/restore-entry.sh syntax"
    python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); its=m["items"][0]["items"]; assert any("恢复书库入口" in i["name"] and i["params"].endswith("/restore-entry.sh") for i in its)' "$k/menu.json" 2>/dev/null \
        || F "$k/menu.json: no 恢复书库入口 item"
    D=$T/kual; rm -rf "$D"; mkdir -p "$D/docs" "$D/vd" "$D/bin"
    printf '#!/bin/sh\necho "$*" >> %s/lipc.log\n' "$D" > "$D/bin/lipc-set-prop"; printf '#!/bin/sh\n' > "$D/bin/eips"; printf '#!/bin/sh\n' > "$D/bin/sleep"; chmod 755 "$D/bin/"*
    sed -e "s#/mnt/base-us/veradroid#$D/vd#g" -e "s#/mnt/us/documents#$D/docs#g" -e "s#^PATH=.*#PATH=$D/bin:\$PATH#" "$k/restore-entry.sh" > "$D/r.sh"
    sh "$D/r.sh" >/dev/null 2>&1 && F "$k: restore-entry.sh succeeds without a program dir"
    sed 's/^# Name: .*/# Name: VeraDroid 启动（备用，可拷进 documents）/' cloud/static/VeraDroid-Launch.sh > "$D/vd/VeraDroid-Launch.sh"
    sh "$D/r.sh" >/dev/null 2>&1 || F "$k: restore-entry.sh failed"
    [ "$(title "$D/docs/VeraDroid 启动.sh")" = "VeraDroid 启动" ] || F "$k: restored entry title"
    grep -q reScanFile "$D/lipc.log" 2>/dev/null || F "$k: not indexed"
    echo mine > "$D/docs/VeraDroid 启动.sh"; sh "$D/r.sh" >/dev/null 2>&1
    [ "$(cat "$D/docs/VeraDroid 启动.sh")" = mine ] || F "$k: restore-entry.sh overwrote an existing entry"
done
[ -n "$NEWF" ] && [ -d host/pw6/kual ] && { diff -r host/pw6/kual host/k49/kual >/dev/null || F "host/pw6/kual differs from host/k49/kual"; }
for B in cloud/static/bootstrap.sh cloud/static/bootstrap-legacy.sh; do
    [ -n "$(blk "$B" 2>/dev/null)" ] || continue
    grep -q 'chmod 755 .*/extensions/VeraDroid/restore-entry.sh' "$B" || F "$B: KUAL restore-entry.sh not made executable"
done

# ---- 5. Android Screensaver folder + VeraHome page ----
for v in pw6 k49 legacy; do
    sv=host/$v/boot/lib/saver.sh; [ -f "$sv" ] || continue
    fam=$NEWF; [ $v = legacy ] && fam=$LEG
    grep -q '^saver_dir_fix()' "$sv" || { [ -z "$fam" ] && continue; F "$sv: no saver_dir_fix"; continue; }
    grep -q 'type saver_dir_fix >/dev/null 2>&1 && saver_dir_fix' host/$v/boot/lib/afterboot.sh || F "$v: after_boot does not create Screensaver"
    D=$T/sd-$v; mkdir -p "$D/data/media/0"
    SYS=$D sh -eu -c ". $sv; saver_dir_fix; saver_dir_fix; echo done" | grep -q done || F "$v: saver_dir_fix fails under sh -eu"
    [ "$(stat -f %Lp "$D/data/media/0/Screensaver" 2>/dev/null || stat -c %a "$D/data/media/0/Screensaver")" = 777 ] || F "$v: Screensaver not 777"
    grep -q 'veradroid/screensaver' "$D/data/media/0/Screensaver/把屏保图片放这里.txt" 2>/dev/null || F "$v: Android screensaver note missing"
    grep -q 'chown 1023:1023 "$sdd/Screensaver"' "$sv" || F "$v: Screensaver not given to media_rw"
    D=$T/sd2-$v; mkdir -p "$D/data/media/0"; echo user > "$D/data/media/0/Screensaver"
    SYS=$D sh -eu -c ". $sv; saver_dir_fix"; [ "$(cat "$D/data/media/0/Screensaver")" = user ] || F "$v: saver_dir_fix touched a user file named Screensaver"
done
J=android/packages/VeraHome/src/com/veradroid/home/ScreensaverActivity.java
grep -q 'Kindle 盘 → veradroid → screensaver' "$J" || F "screensaver page: USB place"
grep -q '内部存储 → Screensaver' "$J" || F "screensaver page: Android place"
grep -q '传书网页' "$J" || F "screensaver page: transfer page"
grep -q 'foundText.setText(found(nSd, nVd));' "$J" || F "screensaver page does not show how many images were found"
grep -q '"找到 " + (nSd + nVd) + " 张你的图片' "$J" || F "screensaver page count text"

[ $fail = 0 ] && echo "where-ux: ok"
exit $fail
