#!/bin/sh
# 1 GB models: ART must not reserve a backup heap space (heapsize 512m x 2 = 1 GB of a 32-bit app's 3 GB address space).
# 番茄 on a KT6 1 GB (user diagnostic): "thread constructor failed: Try again" SIGABRT and CursorWindow
# error -12 with physical memory to spare. heap_va_fix adds dalvik.vm.backgroundgctype=CMS + -XX:DisableHSpaceCompactForOOM
# to build.prop (on a test device: dalvik-main 1024 -> 512 MB, VmSize 1.94 -> 1.46 GB), ART_HSPACE=1 takes them out again.
set -eu
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $*"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for H in host/pw6/boot host/k49/boot; do
    M=$H/lib/memory.sh
    grep -q '^heap_va_fix()' $M || fail "$H: no heap_va_fix"
    # only on the >= 700 MB branch of heap_fix (512 MB keeps background compaction)
    awk '/^heap_fix\(\)/,/^}/' $M | awk '/-lt 700000/{low=1} /^    else/{low=0; hi=1} /heap_va_fix/{ if (low) bad=1; if (hi) ok=1 } END{ exit !(ok && !bad) }' \
        || fail "$H: heap_va_fix not (only) in the >= 700 MB branch of heap_fix"
    t() { echo "$*" >> "$T/log"; }
    eval "$(awk '/^heap_va_fix\(\)/,/^}/' $M)"
    f=$T/build.prop
    printf 'dalvik.vm.heapsize=512m\nro.x=1\n' > $f
    ART_HSPACE=; heap_va_fix $f; heap_va_fix $f
    [ "$(grep -c '^dalvik.vm.backgroundgctype=CMS$' $f)" = 1 ] || fail "$H: backgroundgctype not added exactly once"
    [ "$(grep -c '^dalvik.vm.extra-opts=-XX:DisableHSpaceCompactForOOM$' $f)" = 1 ] || fail "$H: extra-opts not added exactly once"
    [ "$(grep -c 'art: no backup heap space' $T/log)" = 1 ] || fail "$H: log line not written once"
    ART_HSPACE=1; heap_va_fix $f
    grep -q 'backgroundgctype\|extra-opts' $f && fail "$H: ART_HSPACE=1 did not remove the lines"
    [ "$(cat $f)" = "$(printf 'dalvik.vm.heapsize=512m\nro.x=1')" ] || fail "$H: ART_HSPACE=1 changed other lines"
    # someone else's extra-opts / gc type in the image: leave the file alone
    printf 'dalvik.vm.extra-opts=-Xfoo\n' > $f; ART_HSPACE=; heap_va_fix $f
    [ "$(cat $f)" = "dalvik.vm.extra-opts=-Xfoo" ] || fail "$H: foreign extra-opts overwritten"
    printf 'dalvik.vm.backgroundgctype=SS\n' > $f; heap_va_fix $f
    [ "$(cat $f)" = "dalvik.vm.backgroundgctype=SS" ] || fail "$H: foreign backgroundgctype overwritten"
    rm -f $T/log
done
# heap_fix runs before Android starts (zram_on), after settings_load (ART_HSPACE comes from settings.conf)
for H in host/pw6/boot host/k49/boot; do
    awk '/^zram_on\(\)/,/^}/' $H/lib/memory.sh | grep -q heap_fix || fail "$H: zram_on no longer calls heap_fix"
done
echo "art-va: ok"
