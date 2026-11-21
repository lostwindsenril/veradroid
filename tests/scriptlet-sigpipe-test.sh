#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The library launcher runs scriptlets as `sh -l script 2>&1 | fbink -y 5 -r`. If fbink is missing or
# crashes, the pipe breaks and the first echo kills the script with SIGPIPE (exit 141): the user only
# sees a flash and the home screen (reported on PW6 5.20.1, reproduced in eink-emulator 2026-11-07).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(dirname "$HERE")
fail=0
for f in VeraDroid.sh VeraDroid-Experimental.sh VeraDroid-Offline.sh VeraDroid-Update.sh VeraDroid-Launch.sh; do
    p=$REPO/cloud/static/$f
    grep -q "^trap '' PIPE" "$p" || { echo "FAIL $f does not ignore SIGPIPE"; fail=1; continue; }
    # the header block (# Name/# Icon) must stay first
    head -3 "$p" | grep -q '^# Name:' || { echo "FAIL $f lost its # Name: header"; fail=1; }
done
grep -q "trap '\\\\''' PIPE\|trap '' PIPE" "$REPO/cloud/static/bootstrap.sh" || { echo "FAIL bootstrap does not patch the launcher"; fail=1; }
# functional: a scriptlet whose reader is gone must keep running
t=$(mktemp); printf '#!/bin/sh\ntrap %s PIPE\necho a; echo b; echo done > "$1"\n' "''" > "$t.sh"
( sh "$t.sh" "$t" 2>/dev/null ) | true
[ "$(tail -1 "$t" 2>/dev/null)" = done ] || { echo "FAIL script did not survive a broken pipe"; fail=1; }
rm -f "$t" "$t.sh"
[ "$fail" = 0 ] && echo "SCRIPTLET SIGPIPE CHECKS OK"
exit $fail
