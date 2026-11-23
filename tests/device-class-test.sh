#!/bin/sh
# Hardware class detection (cloud/static/bootstrap.sh vd_device_class, the same function in host/*/boot/lib/imgclass.sh)
# against the /proc figures of every model we have (diagnostics/results/probe, the PW6 survey, emulator machines).
# docs/per-model-images.md. Run: sh tests/device-class-test.sh
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed -n '/^vd_device_class() {/,/^}/p' cloud/static/bootstrap.sh > "$T/fn.sh"
for h in pw6 k49 legacy; do
    sed -n '/^vd_device_class() {/,/^}/p' host/$h/boot/lib/imgclass.sh | cmp -s - "$T/fn.sh" || { echo "FAIL host/$h imgclass.sh vd_device_class differs from bootstrap.sh"; exit 1; }
done
. "$T/fn.sh"
A53='half thumb fastmult vfp edsp neon vfpv3 tls vfpv4 idiva idivt vfpd32 lpae evtstrm aes pmull sha1 sha2 crc32'
A7='half thumb fastmult vfp edsp neon vfpv3 tls vfpv4 idiva idivt vfpd32 lpae evtstrm'
A9_41='half thumb fastmult vfp edsp neon vfpv3 tls vfpd32'
A9_30='swp half thumb fastmult vfp edsp neon vfpv3'
fail=0
# model  kernel  MemTotal(kB)  features  expected class   (sources: diagnostics/results/probe/*.txt, survey-20261105, docs/compat-matrix.md;
# pw6-real / kt6-real / kt5 / ks2: nominal MemTotal for the RAM the sources give - 957 MB, 512 MB, 474 MB, 1 GB)
while read -r m k mt f want; do
    eval "feat=\$$f"
    mkdir -p "$T/$m"; echo "MemTotal: $mt kB" > "$T/$m/meminfo"; printf 'processor\t: 0\nFeatures\t: %s\n' "$feat" > "$T/$m/cpuinfo"
    got=$(VD_TEST_PROC="$T/$m" VD_TEST_UNAME=$k vd_device_class)
    [ "$got" = "${want#-}" ] || [ "$want" = - -a -z "$got" ] && echo "ok   $m -> ${got:-family}" || { echo "FAIL $m: got '${got}', want '${want}'"; fail=1; }
done <<'TAB'
pw6-real   5.15.41-lab126 980000 A53 pw6
cs-5192    5.15.41-lab126 977804 A53 pw6
pw5-5171   4.9.77-lab126  485604 A53 k49-512
kt5-5192   4.9.77-lab126  474000 A53 k49-512
kt6-real   4.9.77-lab126  490000 A53 k49-512
kt6-emu    4.9.77-lab126  993636 A53 k49-1g
ks2-emu    4.9.77-lab126  993636 A53 k49-1g
ko3-5182   4.1.15-lab126  493696 A7  a7-512
pw4-5181   4.1.15-lab126  502340 A9_41 a9-512
pw3-5162   3.0.35-lab126  514724 A9_30 a9-512
pw2-5122   3.0.35-lab126  254828 A9_30 a9-256
a9-on-5x   5.15.41-lab126 980000 A9_41 -
k49-noidiv 4.9.77-lab126  485604 A9_41 -
TAB
exit $fail
