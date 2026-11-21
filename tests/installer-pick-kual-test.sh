#!/bin/sh
# 安装器两个小问题（2026-11-20）：
#  1. 离线安装：documents 里同一种离线包有好几个（旧版本没删）时，按文件名里的版本号挑最新的（以前按文件名排序拿第一个，
#     可能装回旧版本），日志里写选了哪个。VeraDroid-Offline.sh 的 ver_newer / pick_bundle。
#  2. KUAL “安装 / 更新（联网）”按内核自动选安装器：3.0 / 4.1 内核（老机型）走 static/bootstrap-legacy.sh，
#     和 VeraDroid-Legacy.sh 一样先说明、10 秒到 2 分钟内再点一次才装（VD_EMUONLY_OK=1）；其他内核 bootstrap.sh + VD_EXPERIMENTAL=1。
#     以前两项都下 bootstrap.sh，老机型上它说“请改用老机型安装脚本”就停了。
cd "$(dirname "$0")/.." || exit 2
fail=0
F() { echo "FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
O=cloud/static/VeraDroid-Offline.sh

# ---- 1. version picking ----
sed -n '/^ver_newer()/,/^}/p; /^pick_bundle()/,/^}/p' "$O" > "$T/pick.sh"
grep -q '^pick_bundle()' "$T/pick.sh" || F "pick_bundle not found in $O"
. "$T/pick.sh"
newer() { ver_newer "$1" "$2" || F "ver_newer: $1 should be newer than $2"; }
older() { ver_newer "$1" "$2" && F "ver_newer: $1 should not be newer than $2"; }
newer 0.8.13 0.8.9; newer 1.10 1.9; newer 1.02 1.01; newer 1.0.1 1.0; newer 2 1.99; newer 0.8.10 0.8.9.9
older 0.8.9 0.8.13; older 1.9 1.10; older 1.02 1.02; older 1.0 1.0.0; older 0.99 1.00
pick() { # 目录 变体 期望的文件名 [期望的版本]
    pick_bundle "$1" "$2" >/dev/null
    [ "$(basename "${B:-none}")" = "$3" ] || F "pick $2 in $(ls "$1" | tr '\n' ' '): got $(basename "${B:-none}"), want $3"
    [ "${BV:-}" = "${4:-}" ] || F "pick $2: version '$BV', want '${4:-}'"
}
d=$T/docs; mkdir -p "$d"
pick "$d" pw6 none
: > "$d/veradroid-pw6-1.02.tar.gz"; pick "$d" pw6 veradroid-pw6-1.02.tar.gz 1.02
: > "$d/veradroid-pw6-1.01.tar.gz"; : > "$d/veradroid-pw6-0.99.tar.gz"; pick "$d" pw6 veradroid-pw6-1.02.tar.gz 1.02
: > "$d/veradroid-pw6-1.10.tar.gz"; pick "$d" pw6 veradroid-pw6-1.10.tar.gz 1.10   # by name 0.99 sorts first; 1.10 > 1.02
rm -f "$d"/*; : > "$d/veradroid-legacy-0.8.9.tar.gz"; : > "$d/veradroid-legacy-0.8.13.tar.gz"; : > "$d/veradroid-legacy-0.8.10.tar.gz"
pick "$d" legacy veradroid-legacy-0.8.13.tar.gz 0.8.13
[ "$(pick_bundle "$d" legacy)" = "offline package: 3 bundles in $d: veradroid-legacy-0.8.10.tar.gz veradroid-legacy-0.8.13.tar.gz veradroid-legacy-0.8.9.tar.gz; using the newest: veradroid-legacy-0.8.13.tar.gz" ] \
    || F "pick_bundle log line: $(pick_bundle "$d" legacy)"
pick "$d" k49 none
rm -f "$d"/*; : > "$d/veradroid-k49-1.09 (1).tar.gz"; pick "$d" k49 "veradroid-k49-1.09 (1).tar.gz"   # only an odd name: still used
: > "$d/veradroid-k49-1.08.tar.gz"; pick "$d" k49 veradroid-k49-1.08.tar.gz 1.08             # a proper name wins
: > "$d/veradroid-k49-1.10.tar.gz.part"; : > "$d/veradroid-pw6-9.9.tar.gz"; pick "$d" k49 veradroid-k49-1.08.tar.gz 1.08
mkdir "$d/veradroid-k49-2.0.tar.gz"; pick "$d" k49 veradroid-k49-1.08.tar.gz 1.08            # a directory is not a bundle
grep -q '^VER=\$BV' "$O" || F "$O: VER not taken from the picked version"
grep -q 'for f in "\$HERE"/veradroid-\$WANT-\*.tar.gz; do \[ -f "\$f" \] && B=\$f && break; done' "$O" && F "$O: still takes the first bundle by name"
# 用过的离线包装完由安装器删掉（remove_offline_package：整包、bootstrap.sh、README.txt）
grep -q 'VD_OFFLINE_BUNDLE="\$B"' "$O" || F "$O: VD_OFFLINE_BUNDLE not passed (the used bundle would stay in documents)"
for b in cloud/static/bootstrap.sh cloud/static/bootstrap-legacy.sh; do
    [ -f "$b" ] || continue
    grep -q '^remove_offline_package$' "$b" || F "$b: remove_offline_package not called"
done

# 离线包和已装的同一版（“无需重装”）时也清掉离线包（新机型 bootstrap.sh；老机型 bootstrap-legacy.sh 还没有）
if [ -f host/k49/kual/restore-entry.sh ]; then
    awk '/无需重装/ { n = NR } n && NR > n && NR <= n + 4 && /^ *remove_offline_package$/ { ok = 1 } END { exit !ok }' cloud/static/bootstrap.sh \
        || F "bootstrap.sh: offline bundle of the installed version is left in documents"
fi

# ---- 2. KUAL install.sh ----
K=; for k in host/*/kual/install.sh kual/VeraDroid/install.sh; do [ -f "$k" ] || continue; [ -n "$K" ] || K=$k; cmp -s "$k" "$K" || F "$k differs from $K"; done
# 官网 static/veradroid-kual.zip（两条线共用一个）= host/k49/kual
Z=cloud/static/veradroid-kual.zip
if [ -f "$Z" ] && [ -f host/k49/kual/restore-entry.sh ]; then   # the zip is built on the new-model line (release/1.0x)
    for f in $(ls host/k49/kual); do unzip -p "$Z" "extensions/VeraDroid/$f" 2>/dev/null | cmp -s - "host/k49/kual/$f" || F "$Z: extensions/VeraDroid/$f differs from host/k49/kual/$f"; done
    [ "$(unzip -Z1 "$Z" | grep -c '^extensions/VeraDroid/.')" = "$(ls host/k49/kual | wc -l | tr -d ' ')" ] || F "$Z: file list differs from host/k49/kual"
fi
for m in host/*/kual/menu.json kual/VeraDroid/menu.json; do
    [ -f "$m" ] || continue
    python3 - "$m" <<'PY' || F "$m: menu items"
import json, sys
its = json.load(open(sys.argv[1]))["items"][0]["items"]
names = [i["name"] for i in its]; params = [i["params"] for i in its]
assert "安装 / 更新（联网）" in names, names
assert not any("老机型" in n or "实验机型" in n for n in names), names
assert not any(p.endswith(" experimental") for p in params), params
assert any(p.endswith("install.sh online") for p in params) and any(p.endswith("install.sh offline") for p in params), params
assert sorted(i["priority"] for i in its) == list(range(1, len(its) + 1))
PY
done
D=$T/k; mkdir -p "$D/bin" "$D/us/documents" "$D/bu" "$D/proc/sys/kernel/random" "$D/tmp" "$D/etc"
echo bootid-1 > "$D/proc/sys/kernel/random/boot_id"; echo "Kindle 5.12.2.2 (4053640041)" > "$D/etc/prettyversion.txt"
printf '#!/bin/sh\necho 0\n' > "$D/bin/id"
for c in eips sleep sync fbink; do printf '#!/bin/sh\nexit 0\n' > "$D/bin/$c"; done; rm -f "$D/bin/fbink"
# curl：记下地址，下回来的“安装器”把收到的环境写出来
cat > "$D/bin/curl" <<CURL
#!/bin/sh
o=; u=; while [ \$# -gt 0 ]; do case "\$1" in -o) o=\$2; shift ;; http*) u=\$1 ;; esac; shift; done
echo "\$u" >> $D/curl.log
printf '#!/bin/sh\necho "exp=\${VD_EXPERIMENTAL:-} emu=\${VD_EMUONLY_OK:-}" > $D/env\nexit 0\n' > "\$o"
CURL
chmod 755 "$D/bin/"*
sed -e "s#^PATH=.*#PATH=$D/bin:\$PATH; export PATH#" -e "s#/mnt/base-us#$D/bu#g" -e "s#/mnt/us#$D/us#g" -e "s#/proc/#$D/proc/#g" \
    -e "s#/tmp/vd-#$D/tmp/vd-#g" -e "s#/etc/prettyversion.txt#$D/etc/prettyversion.txt#g" "$K" > "$D/i.sh"
run() { # kernel uptime [mode]
    echo "$2.00 1.00" > "$D/proc/uptime"; rm -f "$D/env" "$D/curl.log"
    VD_TEST_UNAME=$1 VD_BASE=http://test.invalid sh "$D/i.sh" "${3:-online}" || F "install.sh $1 ${3:-online} exit $?"
}
got() { u=$(cat "$D/curl.log" 2>/dev/null); u=${u%%\?*}; e=$(cat "$D/env" 2>/dev/null); [ "$u $e" = "$1" ] || F "kernel $K_: got '$u $e', want '$1'"; }
K_=5.15; run 5.15.41 100; got "http://test.invalid/bootstrap.sh exp=1 emu="
K_=4.9; run 4.9.77 100; got "http://test.invalid/bootstrap.sh exp=1 emu="
K_=4.9-experimental; run 4.9.77 100 experimental; got "http://test.invalid/bootstrap.sh exp=1 emu="
for kr in 3.0.35-lab126 4.1.15-lab126; do
    K_=$kr; rm -f "$D/bu/veradroid/state/confirm"
    run $kr 1000; got " "                                                   # first tap: warning only, nothing downloaded
    [ "$(cut -d' ' -f1-3 "$D/bu/veradroid/state/confirm" 2>/dev/null)" = "install bootid-1 1000" ] || F "$kr: confirm file not written"
    run $kr 1003; got " "                                                   # too soon: warning again
    run $kr 1020; got "http://test.invalid/static/bootstrap-legacy.sh exp=1 emu=1"   # 2nd tap 17 s later: legacy installer
    run $kr 1040; got " "                                                   # confirm used up
    run $kr 1300; got " "; echo "install other-boot 1300" > "$D/bu/veradroid/state/confirm"
    run $kr 1320; got " "                                                   # other boot id: no
done
# offline item hands over to documents/VeraDroid-Offline.sh
printf 'echo "offline $0" > %s/env\n' "$D" > "$D/us/documents/VeraDroid-Offline.sh"
rm -f "$D/env"; VD_TEST_UNAME=3.0.35 sh "$D/i.sh" offline; [ "$(cat "$D/env" 2>/dev/null)" = "offline $D/us/documents/VeraDroid-Offline.sh" ] || F "offline item: $(cat "$D/env" 2>/dev/null)"
grep -q 'install.sh experimental' "$D/us/veradroid/logs/install.log" && :   # (log only)
[ "$fail" = 0 ] && echo "INSTALLER PICK / KUAL OK"
exit "$fail"
