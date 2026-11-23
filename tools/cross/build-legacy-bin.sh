#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the host programs of the legacy bundle (3.0 / 4.1 kernels) with the vdcross-legacy toolchain.
#  sh build-legacy-bin.sh <src dir with display/ input/ tools/src/ bluetooth/> <out dir>
# FBInk (with tools/cross/fbink-state-dump.patch applied, `make kindle` done) is expected in $FBINK_DIR.
set -eu
SRC=$1; OUT=$2; FB=${FBINK_DIR:-${VD_BUILD:-$HOME/veradroid-build}/legacy/build/FBInk}
mkdir -p "$OUT"
nice -n 12 docker run --rm --cpus=4 --memory=4g -v "$SRC":/s:ro -v "$OUT":/o -v "$FB":/fbink:ro vdcross-legacy:gcc5-glibc219 sh -c '
set -e; CC="arm-linux-gnueabihf-gcc -O2 -static"
$CC -pthread -I /fbink /s/display/epd.c /fbink/Release/libfbink.a -lm -o /o/veradroid-epd
$CC /s/input/vinput.c -lm -o /o/veradroid-input
for p in pivot_init vdlmk vdshutwatch slirpctl; do $CC /s/tools/src/$p.c -o /o/$p; done
$CC /s/bluetooth/vdbtkeys.c -o /o/vdbtkeys || echo "vdbtkeys: not built"
$CC -o /o/fbink /fbink/Release/fbink_cmd.o /fbink/Release/libfbink.a -lm
arm-linux-gnueabihf-strip /o/*; chmod 755 /o/*; ls -la /o'
