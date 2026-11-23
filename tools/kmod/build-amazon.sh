#!/bin/sh
# binder.ko + uinput.ko built against Amazon's own kernel source (Kindle_src_<fw>_<id>.tar.gz ->
# gplrelease/linux-4.1.15.tar.gz).. Unlike build-imx41.sh nothing is guessed or patched:
# the tree is Amazon's, the config is the device's /proc/config.gz, and the module __versions are left as
# modpost wrote them. The script fails unless every imported symbol's CRC equals the device kernel's.
#
#   build-amazon.sh <name> <amazon-linux-tree> <device-config> <device-kallsyms> <device-crcs> <out-dir>
#
# device-crcs: tools/kmod/kcrc.py output for the same kernel (build-imx41.sh leaves it as <name>.crcs).
# The Amazon archives are untrusted input: they are only unpacked and compiled inside docker.
set -eu
: "${AOSP_WORK:?set AOSP_WORK to the build work directory (src/ = AOSP android-7.1.1_r61 tree, out/, kmod/)}"
export LC_ALL=C
NAME=$1; T=$2; CFG=$3; KSYMS=$4; CRCS=$5; OUT=$6
HERE=$(cd "$(dirname "$0")" && pwd)
W=${W:-$AOSP_WORK/kmod/imx41}
TC=$AOSP_WORK/src/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/bin/arm-linux-androideabi-
LIMITS=${LIMITS:---cpus=4 --memory=6g}
cd "$W"
T=$(readlink -f "$T"); CFG=$(readlink -f "$CFG"); KSYMS=$(readlink -f "$KSYMS"); CRCS=$(readlink -f "$CRCS")
mkdir -p "$OUT"; OUT=$(readlink -f "$OUT")
case "$T" in "$W"/*) ;; *) echo "the tree must be under $W (docker mount)" >&2; exit 1 ;; esac

# The Oasis configs have CONFIG_LOCALVERSION="" + LOCALVERSION_AUTO, yet the devices report 4.1.15-lab126:
# Amazon's build passes the suffix on the command line. It only changes the release string, not the CRCs.
LV=; grep -q '^CONFIG_LOCALVERSION="-lab126"' "$CFG" || LV=LOCALVERSION=-lab126
if [ ! -f "$T/vmlinux" ] || ! cmp -s "$CFG" "$T/.vd-config"; then
    cp "$CFG" "$T/.config"
    docker run --rm $LIMITS -v "$AOSP_WORK":"$AOSP_WORK" -w "$T" vdaosp:7.1 sh -c "
        set -e; export ARCH=arm CROSS_COMPILE=$TC
        (nice -n 12 make olddefconfig || yes '' | nice -n 12 make oldconfig) > $W/amz-$NAME.olddefconfig.log 2>&1
        nice -n 12 make -j4 $LV KBUILD_SYMTYPES=1 KBUILD_MODPOST_WARN=1 vmlinux modules > $W/amz-$NAME.kbuild.log 2>&1 || { tail -30 $W/amz-$NAME.kbuild.log; exit 1; }
        chmod -R a+rwX ."
    cp "$CFG" "$T/.vd-config"
fi
# olddefconfig must not have changed anything that exists in the device config
grep '^CONFIG' "$CFG" | sort > "$W/amz-$NAME.cfg.dev"; grep '^CONFIG' "$T/.config" | sort > "$W/amz-$NAME.cfg.built"
d=$(diff "$W/amz-$NAME.cfg.dev" "$W/amz-$NAME.cfg.built" | grep '^[<>]' || true)
[ -z "$d" ] && echo "$NAME: config identical to the device's" || { echo "config after olddefconfig differs from the device:"; echo "$d"; }
rel=$(cat "$T/include/config/kernel.release")
echo "$NAME: kernel.release $rel"
[ "$rel" = 4.1.15-lab126 ] || { echo "release is not 4.1.15-lab126" >&2; exit 1; }
# every exported symbol, not just the ones the modules use: how close is this build to the device kernel?
awk '{print $2, $1}' "$T/Module.symvers" | sort > "$W/amz-$NAME.ours"; awk '{print $2, $1}' "$CRCS" | sort > "$W/amz-$NAME.dev"
join "$W/amz-$NAME.ours" "$W/amz-$NAME.dev" | awk '{a = tolower($2); b = tolower($3); sub(/^0x0*/, "", a); sub(/^0x0*/, "", b); if (a == b) s++; else { d++; print "DIFF", $1 } } END { print "exported CRCs: same", s + 0, "differ", d + 0 }' \
    > "$W/amz-$NAME.crcmatch.txt"
tail -1 "$W/amz-$NAME.crcmatch.txt"

PREPARED=1 W=$W LIMITS="$LIMITS" sh "$HERE/build-binder.sh" "${T#$W/}" "$CFG" "${T#$W/}/drivers/android" "$KSYMS" "amz-binder-$NAME"
rm -rf "amz-uinput-$NAME"; mkdir -p "amz-uinput-$NAME"
cp "$T/drivers/input/misc/uinput.c" "$T/drivers/input/input-compat.h" "amz-uinput-$NAME/"
sed -i 's|"../input-compat.h"|"input-compat.h"|' "amz-uinput-$NAME/uinput.c"
printf 'obj-m := uinput.o\nccflags-y := -fno-pic -I$(src)\n' > "amz-uinput-$NAME/Makefile"
docker run --rm $LIMITS -v "$AOSP_WORK":"$AOSP_WORK" -w "$T" vdaosp:7.1 sh -c "
    export ARCH=arm CROSS_COMPILE=$TC; nice -n 12 make M=$W/amz-uinput-$NAME modules >/dev/null; chmod -R a+rwX $W/amz-uinput-$NAME"
for m in "amz-binder-$NAME/binder.ko" "amz-uinput-$NAME/uinput.ko"; do
    python3 "$HERE/modcrc.py" check "$m" "$CRCS" > "$m.crccheck" || { grep -v '^OK' "$m.crccheck"; echo "$m: CRCs differ from the device" >&2; exit 1; }
    cp "$m" "$OUT/"; ${TC}strip --strip-debug "$OUT/$(basename "$m")"
done
sed -n 's/^Linux version .*) \(#.*\)$/\1/p' "$NAME.banner" > "$OUT/uname-v"
[ -s "$OUT/uname-v" ] || { echo "no $NAME.banner (run build-imx41.sh / kimage.py first)" >&2; exit 1; }
printf 'built from Amazon %s, device config, unmodified __versions (all CRCs equal the device kernel)\n' "$(basename "$(dirname "$T")")/$(basename "$T")" > "$OUT/BUILD-NOTES"
strings "$OUT/binder.ko" | grep '^vermagic='
ls -la "$OUT"
