#!/bin/sh
# Build bin/vdnocap (tools/vdnocap/vdnocap.c) for the pw6 / k49 / legacy bundles: one static ARMv7 binary (no FP use,
# no dynamic loader, so it runs on hard- and soft-float firmware alike). :
#   sh build-vdnocap.sh <dir with vdnocap.c> <out dir>
set -eu
SRC=$1; OUT=$2
mkdir -p "$OUT"
nice -n 12 docker run --rm --cpus=2 --memory=1g -v "$SRC":/s:ro -v "$OUT":/o vdcross-legacy:gcc5-glibc219 sh -c '
set -e
arm-linux-gnueabihf-gcc -O2 -static -Wall -Wextra -march=armv7-a /s/vdnocap.c -o /o/vdnocap
arm-linux-gnueabihf-strip /o/vdnocap; chmod 755 /o/vdnocap; md5sum /o/vdnocap'
file "$OUT/vdnocap" 2>/dev/null || true
