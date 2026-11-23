#!/bin/sh
# 下载代码（vd_dl 块）和增量更新代码（vd_parts 块）：docs/download-speed.md、docs/incremental-updates.md
#  1. 两块至少在一个安装器里有；bootstrap.sh 和 bootstrap-legacy.sh 都有的话必须一字不差（新老安装器共用一份代码）。
#  2. 镜像列表：只认 https（主站是 http 的测试服务器时也认 http），"mirrors": [] = 不用，没写 = dl.wenjin.jp，VD_MIRROR 排第一。
#  3. 直链优先（站长 2026-11-19）：本机 Range 测试服务器上，好的镜像直接用、主站不测；镜像 404 / 太慢 / 不支持 Range 时用主站。
#  4. 分段下载（≥ 8 MB 4 段）结果和原文件一样；中途打断（各段只下了一部分）后接着下，结果一样。
#  5. 镜像上的文件不对：整体 sha256 不对 -> 只从主站（VD_MIRRORS=）重下，结果对。
#  6. 元数据（vd_meta）直链先、拿不到或不像元数据时主站；默认直链只在主站是 veradroid.wenjin.jp 时打开。
#  7. auto-update（有 au_meta 的各机型）：元数据和安装器都先走直链（au_meta / au_script）。
set -eu
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $*"; exit 1; }
L=cloud/static/bootstrap-legacy.sh; N=cloud/static/bootstrap.sh
blk() { sed -n "/^# BEGIN $1\$/,/^# END $1\$/p" "$2"; }
for b in vd_dl vd_parts; do
    [ -n "$(blk $b $L)" ] || [ -n "$(blk $b $N)" ] || fail "no installer has the $b block"
    if [ -n "$(blk $b $L)" ] && [ -n "$(blk $b $N)" ]; then [ "$(blk $b $L)" = "$(blk $b $N)" ] || fail "$b block differs between $L and $N"; fi
done
sh -n $L || fail "syntax $L"; sh -n $N || fail "syntax $N"
[ -n "$(blk vd_dl $L)" ] || L=$N      # 下面跑的是有这一块的那个安装器里的代码
command -v python3 >/dev/null && command -v curl >/dev/null || { echo "dl-block-test SKIP (no python3 / curl)"; exit 0; }

W=$(mktemp -d "${TMPDIR:-/tmp}/vd-dl.XXXXXX"); SRV=
trap '[ -z "$SRV" ] || { kill $SRV 2>/dev/null; wait $SRV 2>/dev/null || true; }; rm -rf "$W"' EXIT
mkdir -p "$W/root/bundles" "$W/root/static" "$W/tmp"
head -c 9437184 /dev/urandom > "$W/root/bundles/big.tar.gz"        # 9 MB: 分段
head -c 70000 /dev/urandom > "$W/root/bundles/small.tar.gz"         # 小文件（< 256 KB）
printf '{"version":"9.9","url":"http://x/bundles/big.tar.gz","sha256":"00"}' > "$W/root/static/bootstrap-legacy.json"
python3 tests/fixtures/rangesrv.py "$W/root" "$W/port" & SRV=$!
i=0; while [ ! -s "$W/port" ]; do i=$((i + 1)); [ $i -lt 50 ] || fail "test server did not start"; sleep 0.1; done
P=$(cat "$W/port"); H=http://127.0.0.1:$P
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }

# 块里的代码要的几样（和安装器里的同名函数一样）
TMP=$W/tmp; BASE=$H/main
curl_do() { curl "$@"; }
vlog() { echo "$*" >> "$W/vlog"; }
fsize() { { wc -c < "$1"; } 2>/dev/null | tr -d ' ' || true; }
vp_now() { date +%s; }
eval "$(blk vd_dl $L)"

# ---- 2. 镜像列表 ----
BASE=https://veradroid.wenjin.jp; VD_MIRROR=
vd_mirrors_from '{"version":"1"}'; [ "$(echo $VD_MIRRORS)" = "https://dl.wenjin.jp" ] || fail "default mirror: '$VD_MIRRORS'"
vd_mirrors_from '{"mirrors": []}'; [ -z "$VD_MIRRORS" ] || fail "mirrors [] not empty: '$VD_MIRRORS'"
vd_mirrors_from '{"mirrors": ["http://a.example", "https://b.example/x"]}'; [ "$(echo $VD_MIRRORS)" = "https://b.example/x" ] || fail "https site took an http mirror: '$VD_MIRRORS'"
VD_MIRROR=https://c.example; vd_mirrors_from '{"mirrors": ["https://b.example"]}'; [ "$(echo $VD_MIRRORS)" = "https://c.example https://b.example" ] || fail "VD_MIRROR not first: '$VD_MIRRORS'"
VD_MIRROR=; BASE=$H/main
vd_mirrors_from '{"mirrors": ["http://a.example"]}'; [ "$(echo $VD_MIRRORS)" = "http://a.example" ] || fail "http test site refused an http mirror: '$VD_MIRRORS'"
# 默认直链
( BASE=https://veradroid.wenjin.jp; unset VD_DIRECT; eval "$(blk vd_dl $L)"; [ "$VD_DIRECT" = https://dl.wenjin.jp ] ) || fail "default VD_DIRECT"
( BASE=https://veradroid.wenjin.jp; VD_DIRECT=; eval "$(blk vd_dl $L)"; [ -z "$VD_DIRECT" ] ) || fail "VD_DIRECT= (network.conf) did not switch the direct link off"
( BASE=http://test:1; unset VD_DIRECT; eval "$(blk vd_dl $L)"; [ -z "$VD_DIRECT" ] ) || fail "test server got the live direct link"

U=$H/main/bundles/big.tar.gz
# ---- 3. 直链优先 ----
VD_MIRRORS="$H/m-ok "; : > "$W/root/../requests.log"
set -- $(vd_pick "$U"); [ "$1" = "$H/m-ok/main/bundles/big.tar.gz" ] && [ "$2" = 4 ] || fail "good mirror not picked: $*"
grep -q '^/main/' "$W/requests.log" && fail "main site probed although the mirror was good"
grep -q 'source: .*m-ok.*mirror first' "$W/vlog" || fail "chosen source not logged"
VD_MIRRORS="$H/m-404 "; set -- $(vd_pick "$U"); [ "$1" = "$U" ] && [ "$2" = 4 ] || fail "mirror 404: $*"
VD_MIRRORS="$H/m-norange "; set -- $(vd_pick "$U"); [ "$1" = "$U" ] || fail "mirror without Range picked: $*"
VD_MIRRORS="http://127.0.0.1:1 $H/m-ok "; set -- $(vd_pick "$U"); [ "$1" = "$H/m-ok/main/bundles/big.tar.gz" ] || fail "second mirror after a dead one: $*"
# 太慢（门槛调到 1 GB/s）：比速度，本机主站比等 1 秒的镜像快
VD_MIN_BPS=1073741824; VD_MIRRORS="$H/m-slow "; set -- $(vd_pick "$U"); [ "$1" = "$U" ] || fail "slow mirror preferred over a faster main site: $*"
# 小文件（整个文件 < 256 KB）：镜像回 206 就用，不看速度
VD_MIRRORS="$H/m-slow "; set -- $(vd_pick "$H/main/bundles/small.tar.gz"); [ "$1" = "$H/m-slow/main/bundles/small.tar.gz" ] || fail "small file not from the mirror: $*"
VD_MIN_BPS=51200

# ---- 4. 分段下载 + 续传 ----
want=$(sum "$W/root/bundles/big.tar.gz"); SZ=$(fsize "$W/root/bundles/big.tar.gz")
VD_MIRRORS="$H/m-ok "; rm -f "$W/vlog"
vd_fetch "$U" "$W/o1" "$SZ" || fail "segmented fetch rc=$?"
[ "$(sum "$W/o1")" = "$want" ] || fail "segmented fetch: content differs"
[ ! -d "$W/o1.seg" ] || fail "segments left behind"
# 打断：各段只有前 100 KB（第 2 段多一个坏尾巴也要能处理：按长度截断规则）
mkdir -p "$W/o2.seg"; echo "$SZ 4" > "$W/o2.seg/plan"; seg=$(( (SZ + 3) / 4 ))
for k in 0 1 2 3; do dd if="$W/root/bundles/big.tar.gz" of="$W/o2.seg/$k" bs=1024 skip=$((k * seg / 1024)) count=100 2>/dev/null; done
[ $((seg % 1024)) = 0 ] || fail "test assumes 1 KB aligned segments"
: > "$W/requests.log"
vd_fetch "$U" "$W/o2" "$SZ" || fail "resumed fetch rc=$?"
[ "$(sum "$W/o2")" = "$want" ] || fail "resumed fetch: content differs"
grep -q "bytes=102400-" "$W/requests.log" || fail "segment 0 did not resume at 100 KB"
# 单连接（VD_SEGS=1）
VD_SEGS=1 vd_fetch "$U" "$W/o3" "$SZ" || fail "single fetch"; [ "$(sum "$W/o3")" = "$want" ] || fail "single fetch content"

# ---- 5. 镜像文件不对 -> 只从主站重下 ----
VD_MIRRORS="$H/m-bad "; rm -f "$TMP/dl.pick"
vd_fetch "$U" "$W/o4" "$SZ" || fail "fetch from the bad mirror"
[ "$(sum "$W/o4")" != "$want" ] || fail "bad mirror served the right file (test broken)"
rm -rf "$W/o4" "$W/o4.seg" "$TMP/dl.pick"; VD_MIRRORS=      # 安装器 sha256 不对时做的
: > "$W/requests.log"; vd_fetch "$U" "$W/o4" "$SZ" || fail "main-only fetch"
[ "$(sum "$W/o4")" = "$want" ] || fail "main-only fetch content"
grep -q '^/m-' "$W/requests.log" && fail "second try touched a mirror"

# ---- 6. 元数据 ----
MU="$H/main/static/bootstrap-legacy.json?t=1"
VD_DIRECT=$H/m-ok; : > "$W/requests.log"; j=$(vd_meta "$MU" --max-time 5) || fail "meta via direct"
grep -q '"9.9"' <<EOF || fail "meta content"
$j
EOF
grep -q '^/main/' "$W/requests.log" && fail "main site asked although the direct link had the meta"
VD_DIRECT=$H/m-404; : > "$W/requests.log"; j=$(vd_meta "$MU" --max-time 5) || fail "meta fallback"
grep -q '^/main/static/bootstrap-legacy.json' "$W/requests.log" || fail "meta not taken from the main site after a 404"
printf 'not json' > "$W/root/static/junk.json"; cp "$W/root/static/bootstrap-legacy.json" "$W/root/static/ok.json"
VD_DIRECT=$H/m-ok; j=$(vd_meta "$H/main/static/junk.json" --max-time 5 || true); [ "$j" = "not json" ] || fail "junk from the direct link accepted as meta"
VD_DIRECT=; : > "$W/requests.log"; vd_meta "$MU" --max-time 5 >/dev/null || fail "meta without direct"
grep -q '^/m-' "$W/requests.log" && fail "direct link used although switched off"

# ---- 7. auto-update ----
n=0
for A in host/*/boot/lib/auto-update.sh; do
    grep -q '^au_meta() {' $A || continue; n=$((n + 1))
    grep -q 'json=$(au_meta "$meta"' $A || fail "$A: meta not via au_meta"
    grep -q 'au_script "$BASE/' $A || fail "$A: installer not via au_script"
    grep -q 'curl_do -fsSL --max-time 120 -o "$BS.part"' $A && fail "$A: installer still fetched from the main site only"
    LOG=$W/au.log; BASE=https://veradroid.wenjin.jp; unset VD_DIRECT
    eval "$(sed -n '/^case "$BASE" in https/p' $A)"; [ "$DIRECT" = https://dl.wenjin.jp ] || fail "$A: default direct link"
    eval "$(awk '/^au_meta\(\)/,/^}/' $A)"; eval "$(awk '/^au_script\(\)/,/^}/' $A)"
    DIRECT=$H/m-ok; j=$(au_meta "$MU") || fail "$A: au_meta"
    case "$j" in *'"9.9"'*) ;; *) fail "$A: au_meta via direct: $j" ;; esac
    printf '#!/bin/sh\necho ok\n' > "$W/root/static/bs.sh"
    : > "$W/requests.log"; au_script "$H/main/static/bs.sh" "$W/bs" || fail "$A: au_script"
    grep -q '^/main/' "$W/requests.log" && fail "$A: au_script used the main site although the direct link had it"
    DIRECT=$H/m-404; au_script "$H/main/static/bs.sh" "$W/bs" || fail "$A: au_script fallback"
    printf 'if then\n' > "$W/root/static/broken.sh"; DIRECT=$H/m-ok
    ! au_script "$H/main/static/broken.sh" "$W/bs" 2>/dev/null || fail "$A: au_script accepted a broken script"
done
[ $n -gt 0 ] || fail "no auto-update.sh uses au_meta"
echo "dl-block-test OK"
