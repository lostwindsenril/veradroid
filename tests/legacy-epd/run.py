#!/usr/bin/env python3
"""Native legacy veradroid-epd test (tests/legacy-epd-test.sh): display/legacy/epd.c built for the host with
tests/legacy-epd/fbinkstub.c (an i.MX EPDC Kindle, no panel; the stub's wait sleeps for the waveform's nominal time).
Frames are written into the shared buffer and posted on the FIFO the way hwcomposer.kindle does; the checks read the
bridge's own refresh log (ctl/timing on).
Checks: touch scroll mode (A2 without hardware dithering during the drag, one update in flight, the newest picture
drawn, one full-quality cleanup after; a drag without frames leaves the next page alone; SCROLLWFM du; SCROLLDELAY 0 is
the old behaviour; style 2), page counting only after input (FLIPINPUT / FLIPCOUNT), MONO, malformed lines ignored.
It also prints the drag numbers old / new (stub timing, not a panel) for docs/legacy-perf.md.
usage: run.py EPD_BINARY [-k]"""
import os, re, subprocess, sys, tempfile, time

W, H = 1272, 1696
PAGE = W * H * 4
REF = re.compile(r'^\[(\d+)\] epd: (\d+)x(\d+)\+(\d+)\+(\d+) mode=(\d+) wfm=(\d+) full=(\d+) flash=(\d+)')
STUB = re.compile(r'^stub: wfm=(\d+) dither=(\d+)')
WFM_DU, WFM_GC16, WFM_A2, WFM_GL16, WFM_REAGL = 1, 2, 4, 5, 6
fails = 0


def check(cond, msg):
    global fails
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond: fails += 1


class Bridge:
    def __init__(self, binary, extra=(), env=None):
        self.d = tempfile.mkdtemp(prefix='lepdt-')
        self.shm = os.path.join(self.d, 'fb'); self.fifo = os.path.join(self.d, 'epd.fifo'); self.ctl = os.path.join(self.d, 'ctl')
        os.mkdir(self.ctl); open(os.path.join(self.ctl, 'timing'), 'w').close()
        with open(self.shm, 'wb') as f: f.write(b'\xff' * PAGE * 2)
        os.mkfifo(self.fifo)
        self.log = open(os.path.join(self.d, 'log'), 'w+')
        # the legacy host's defaults (container.sh): 均衡, settle 40 (settings.sh), hold 70, no animation (i.MX has none)
        args = [binary, 'run', self.shm, self.fifo, self.ctl, '--w', str(W), '--h', str(H), '--contrast', '1.0', '--dither', '3',
                '--flash', '0', '--mode', '0', '--settle', '40', '--hold', '70', '--anim-mode', '0'] + list(extra)
        e = dict(os.environ); e.update(env or {})
        self.p = subprocess.Popen(args, stderr=self.log, stdout=self.log, env=e)
        self.w = os.open(self.fifo, os.O_WRONLY)
        self.step = 0
        time.sleep(0.4)
        self.page(); time.sleep(1.0)     # the first frame is drawn whole

    def send(self, *lines):
        os.write(self.w, ''.join(l + '\n' for l in lines).encode())

    def fill(self, y0, y1, x0=0, x1=W):
        """new content in rows y0..y1: text-like stripes that move every step (pixels change both ways)"""
        self.step += 1
        with open(self.shm, 'r+b') as f:
            buf = bytearray()
            for y in range(y0, y1):
                v = 0 if (y + self.step * 7) % 24 < 6 else 255
                buf += bytes([v, v, v, 255]) * (x1 - x0) if (x0, x1) == (0, W) else b''
            if (x0, x1) == (0, W):
                f.seek(y0 * W * 4); f.write(buf)
            else:
                for y in range(y0, y1):
                    v = 0 if (y + self.step * 7) % 24 < 6 else 255
                    f.seek(y * W * 4 + x0 * 4); f.write(bytes([v, v, v, 255]) * (x1 - x0))

    def page(self, small=False):
        if small: self.fill(800, 850, 600, 660); self.send('P 0 800 850')
        else: self.fill(120, H - 120); self.send('P 0 120 %d' % (H - 120))

    def mark(self):
        self.log.flush(); return os.path.getsize(self.log.name)

    def refreshes(self, since):
        self.log.flush()
        with open(self.log.name) as f:
            f.seek(since); txt = f.read()
        out, dith = [], None
        for l in txt.splitlines():
            s = STUB.match(l)
            if s: dith = int(s[2]); continue
            m = REF.match(l)
            if m: out.append(dict(t=int(m[1]), w=int(m[2]), h=int(m[3]), wfm=int(m[7]), full=int(m[8]), flash=int(m[9]), dither=dith))
        return out, txt

    def close(self):
        try: self.send('QUIT')
        except OSError: pass
        try: self.p.wait(timeout=3)
        except subprocess.TimeoutExpired: self.p.kill()
        if '-k' not in sys.argv: subprocess.call(['rm', '-rf', self.d])


def drag(b, frames=10, gap=0.04, after=0.0, hint=True):
    """a finger drag: the app posts a frame every <gap> s (faster than the panel); returns (t_first_frame_ms, t_last_frame_ms)"""
    if hint: b.send('SCROLL 1')
    time.sleep(0.02)
    t0 = time.monotonic()
    for _ in range(frames): b.page(); time.sleep(gap)
    t1 = time.monotonic()
    if hint: b.send('SCROLL 0')
    time.sleep(after)
    return t0, t1


def summary(r, t_first_post):
    """refreshes, first refresh after the first frame (ms), the gaps between drag refreshes"""
    if not r: return 0, None, []
    return len(r), r[0]['t'], [r[i + 1]['t'] - r[i]['t'] for i in range(len(r) - 1)]


def main():
    binary = sys.argv[1]
    print('== touch scroll mode (A2, one update in flight)')
    b = Bridge(binary, ['--scroll-delay', '800'])
    m = b.mark(); drag(b, 10, 0.04); time.sleep(1.8)
    r, txt = b.refreshes(m)
    a2 = [x for x in r if x['wfm'] == WFM_A2]
    clean = [x for x in r if x['full'] and x['wfm'] in (WFM_REAGL, WFM_GL16)]
    check(len(a2) >= 2 and r[:len(a2)] == a2, f'drag frames go out as A2 ({[x["wfm"] for x in r]})')
    check(all(x['dither'] == 0 for x in a2), f'A2 without hardware dithering (FORCE_MONOCHROME path) ({[x["dither"] for x in a2]})')
    gaps = [a2[i + 1]['t'] - a2[i]['t'] for i in range(len(a2) - 1)]
    check(gaps and min(gaps) >= 110, f'one update in flight: A2 refreshes at least the A2 time apart ({gaps} ms)')
    check(len(a2) < 10 and 'scroll frame' in txt, f'frames that came while the panel was busy were merged into the next one ({len(a2)} of 10)')
    check(len(clean) == 1 and r[-1] is clean[0] and 'scroll cleanup' in txt, 'one full-quality cleanup (REAGL FULL) after the drag, last')
    check(clean and a2 and clean[0]['t'] - a2[-1]['t'] >= 800, f'cleanup about SCROLLDELAY (800 ms) after the last A2 frame ({clean[0]["t"] - a2[-1]["t"] if clean and a2 else "-"} ms)')
    check('flip new' not in txt and not any(x['flash'] for x in r), 'scroll frames are not page flips, no flash')
    # the stub's fd is /dev/null: MXCFB_GET_PWRDOWN_DELAY fails there, so only the attempt (once per drag, not per frame) shows
    pw = len(re.findall(r'GET_PWRDOWN_DELAY|power-down delay', txt))
    check(1 <= pw <= 2, f'panel power-down delay set once for the drag and put back after the cleanup ({pw} attempts)')
    b.send('VERIFY'); time.sleep(0.3)
    _, txt = b.refreshes(m)
    check('panel picture matches' in txt, 'after the drag the panel holds the newest picture')
    # a drag during which the app drew nothing: the next page keeps its normal waveform
    m = b.mark(); b.send('SCROLL 1'); time.sleep(0.05); b.send('SCROLL 0'); time.sleep(0.1); b.page(); time.sleep(1.4)
    r, txt = b.refreshes(m)
    check(r and r[0]['wfm'] != WFM_A2 and 'scroll cleanup' not in txt, f'drag without frames: the page after it is not A2 ({[x["wfm"] for x in r]})')
    # SCROLLWFM du
    b.send('SCROLLWFM du'); time.sleep(0.05)
    m = b.mark(); drag(b, 4, 0.1); time.sleep(1.6)
    r, txt = b.refreshes(m)
    check(r and r[0]['wfm'] == WFM_DU and not any(x['wfm'] == WFM_A2 for x in r), f'SCROLLWFM du: DU frames ({[x["wfm"] for x in r]})')
    b.send('SCROLLWFM a2')
    # style 2: nothing during the drag, one REAGL after
    b.send('SCROLLSTYLE 2'); time.sleep(0.05)
    m = b.mark(); b.send('SCROLL 1'); time.sleep(0.02)
    for _ in range(5): b.page(); time.sleep(0.08)
    time.sleep(0.3); r1, _ = b.refreshes(m)
    b.send('SCROLL 0'); time.sleep(1.0)
    r, txt = b.refreshes(m)
    check(not r1, f'style 2: nothing drawn while the finger drags ({len(r1)} refreshes)')
    check(len(r) == 1 and r[0]['wfm'] == WFM_REAGL, f'style 2: one REAGL after the lift ({[x["wfm"] for x in r]})')
    b.send('SCROLLSTYLE 1')
    b.close()

    print('== the same drag, old behaviour (SCROLLDELAY 0) vs scroll mode (stub timing, not a panel)')
    res = {}
    for name, extra in (('old', ['--scroll-delay', '0']), ('new', ['--scroll-delay', '500'])):
        b = Bridge(binary, extra)
        m = b.mark()
        t_post = int(time.monotonic() * 1000)
        drag(b, 15, 0.033)          # 0.5 s of a 30 Hz drag (KFB_HZ=30)
        time.sleep(2.0)
        r, txt = b.refreshes(m)
        drag_r = [x for x in r if not x['full'] or x['wfm'] not in (WFM_REAGL, WFM_GL16) or name == 'old']
        n, first, gaps = summary(r, t_post)
        res[name] = dict(n=n, wfm=[x['wfm'] for x in r], first=(r[0]['t'] - t_post) if r else None,
                         last=(r[-1]['t'] - t_post) if r else None, gaps=gaps)
        b.close()
    for k, v in res.items():
        print(f'  {k}: {v["n"]} refreshes {v["wfm"]}, first {v["first"]} ms, last {v["last"]} ms after the first frame, gaps {v["gaps"]}')
    o, n = res['old'], res['new']
    check(n['n'] > o['n'], f'scroll mode puts more frames of the drag on the panel ({o["n"]} -> {n["n"]})')
    check(n['first'] is not None and o['first'] is not None and n['first'] <= o['first'] + 20, f'first refresh no later ({o["first"]} -> {n["first"]} ms)')

    print('== page counting only after input (KFB_FLASH 2)')
    b = Bridge(binary, ['--flash', '2'])
    m = b.mark()
    for _ in range(4): b.page(); time.sleep(1.2)
    r, txt = b.refreshes(m)
    check(not any(x['flash'] for x in r) and txt.count('flip not counted (no input') >= 3, 'large changes with no input before them: not counted, no flash')
    m = b.mark()
    for _ in range(4): b.send('TOUCH'); time.sleep(0.1); b.page(); time.sleep(1.2)
    r, txt = b.refreshes(m)
    check(sum(x['flash'] for x in r) >= 1, f'page turns after TOUCH: counted, flash on the 2nd ({sum(x["flash"] for x in r)} flashes)')
    b.send('FLIPCOUNT 0'); m = b.mark()
    for _ in range(4): b.send('DIR 2'); time.sleep(0.1); b.page(); time.sleep(1.2)
    r, txt = b.refreshes(m)
    check(not any(x['flash'] for x in r), 'FLIPCOUNT 0 (home screen): no flash')
    b.send('FLIPCOUNT 1', 'FLIPINPUT 0'); m = b.mark()
    for _ in range(4): b.page(); time.sleep(1.2)
    r, txt = b.refreshes(m)
    check(sum(x['flash'] for x in r) >= 1, 'FLIPINPUT 0: every large change counts again')
    b.close()

    print('== MONO / malformed lines / Zelda')
    b = Bridge(binary)
    b.send('SET 1.0 3 0 0 2 40', 'MONO 128'); time.sleep(0.6)
    m = b.mark(); b.page(small=True); time.sleep(0.8)
    r, _ = b.refreshes(m)
    check(r and r[0]['wfm'] == WFM_DU and r[0]['dither'] == 0, f'MONO 128 in 最快: DU without hardware dithering ({[(x["wfm"], x["dither"]) for x in r]})')
    b.send('SET 1.0 3 0 0 0 40', 'MONO 0'); time.sleep(0.6)
    m = b.mark(); b.send('NEWWIN'); time.sleep(0.05); b.page(); time.sleep(1.0)
    r, _ = b.refreshes(m)
    check(r and r[0]['flash'] == 1, 'NEWWIN: the next large frame is a full flash')
    b.send('GCN 3'); m = b.mark()
    for _ in range(4): b.fill(300, 600); b.send('P 0 300 600'); time.sleep(1.0)
    r, txt = b.refreshes(m)
    check(sum(x['flash'] for x in r) == 1 and 'GCN 3 reached' in txt, f'GCN 3: one flash after 3 non-page refreshes ({sum(x["flash"] for x in r)})')
    b.send('GCN 0')
    m = b.mark(); b.send('NOSUCHCOMMAND 1', 'SCROLL', 'SCROLLWFM', 'MAXDEFER x', 'STATS'); b.page(); time.sleep(0.8)
    r, txt = b.refreshes(m)
    check(r and b.p.poll() is None and 'epd: stats sent=' in txt, 'unknown / malformed lines are ignored, frames still drawn, STATS logs')
    b.close()
    print('== no hardware dithering on text (docs/text-sharpness.md)')
    b = Bridge(binary)
    m = b.mark(); b.page(); time.sleep(1.0)
    r, _ = b.refreshes(m)
    check(r and all(x['dither'] == 0 for x in r), f'a text page goes out without hardware dithering ({[x["dither"] for x in r]})')
    with open(b.shm, 'r+b') as f:      # a 320x320 mid-gray block: a picture
        for y in range(400, 720):
            f.seek(y * W * 4 + 400 * 4); f.write(bytes([128, 128, 128, 255]) * 320)
    m = b.mark(); b.send('P 0 400 720'); time.sleep(1.0)
    r, _ = b.refreshes(m)
    check(r and all(x['dither'] != 0 for x in r), f'a picture keeps the hardware dithering ({[x["dither"] for x in r]})')
    b.close()
    b = Bridge(binary, env={'STUB_PLATFORM': 'Zelda'})
    m = b.mark(); drag(b, 4, 0.1); time.sleep(1.4)
    r, txt = b.refreshes(m)
    check(r and all(x['dither'] == 0 for x in r), f'Zelda (Oasis 2 / 3): no hardware dithering anywhere ({[x["dither"] for x in r]})')
    b.close()
    print('FAILED: %d' % fails if fails else 'all passed')
    sys.exit(1 if fails else 0)


main()
