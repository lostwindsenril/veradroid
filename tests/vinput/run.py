#!/usr/bin/env python3
"""Native veradroid-input test (driven by tests/vinput-test.sh, needs Linux: gcc + linux/input.h).

Feeds synthetic touch streams in three source protocols into a natively built veradroid-input through fakeevdev.so
(LD_PRELOAD: the touch device is a FIFO, uinput writes go to files) and checks:
  - every gesture fires its action / key, for protocol B (goodix-ts gtx8 framing), A (with and without
    ABS_MT_TRACKING_ID) and single touch (where a gesture needs only one finger);
  - normal one-finger taps / swipes reach the virtual touch screen with the same contacts as with a B panel, and the
    touch-down is forwarded no later than the existing two-finger decision window (+ one 10 ms poll tick + slack);
  - with --base OLD_BINARY: for protocol B the new binary's output (touch + key events + actions) is identical to the
    old one's, event for event;
  - stuck contacts (fix/vinput-stuck): whatever the panel does and whatever a gesture swallows, Android ends with no
    contact down: a slot change inside a swallowed gesture (KT5 diag: edge swipe -> panel left two contacts down), a
    tracking id that changes without a lift, a lift the kernel has but never sent (watchdog, EVIOCGMTSLOTS), the
    host's "reset", panels without BTN_TOUCH and with 32 slots (pt_mt), and random multi-finger streams;
  - panels with ABS_MT_PRESSURE (VT_PRES): every new contact reaches Android with a pressure > 0 (Android counts a
    contact with pressure 0 as hovering), also when the panel / the --inject path leaves pressure out, alternating
    between two values so a repeat is not dropped as unchanged; a panel's own pressure is forwarded untouched.
usage: run.py NEW_BINARY SHIM.so [--base OLD_BINARY]
"""
import os, struct, subprocess, sys, tempfile, time

EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
SYN_REPORT, SYN_MT_REPORT = 0, 2
BTN_TOUCH = 0x14a
ABS_X, ABS_Y = 0, 1
SLOT, MAJOR, PX, PY, TID, PRES = 0x2f, 0x30, 0x35, 0x36, 0x39, 0x3a
KEY_BACK = 158
EVFMT = 'llHHi'
EVSZ = struct.calcsize(EVFMT)
UDEV_SZ = 80 + 8 + 4 + 64 * 4 * 4          # struct uinput_user_dev
WINDOW = 40
ARGS = ['--w', '1272', '--h', '1696', '--edge', '120', '--window', str(WINDOW), '--edge-hold', '60', '--edge-swipe', '80',
        '--edge-back', '1', '--corner-ms', '2000']


class Encoder:
    """turns a list of fingers [(fid, x, y), ...] per frame into what a driver of that protocol sends"""
    def __init__(self, proto, pres=None):
        self.pres = pres                        # not None: the panel sends this ABS_MT_PRESSURE with every new contact
        self.p = proto; self.prev = {}; self.btn = 0; self.slot = -1; self.stx = self.sty = None; self.n = 0

    def frame(self, fingers):
        ev = []
        cur = {f: (x, y) for f, x, y in fingers}
        if self.p == 'B':                       # goodix_ts_report_finger after the input core's filtering
            if cur and not self.btn: ev.append((EV_KEY, BTN_TOUCH, 1))
            if not cur and self.btn: ev.append((EV_KEY, BTN_TOUCH, 0))
            for s in range(10):
                if s in self.prev and s not in cur:
                    if self.slot != s: ev.append((EV_ABS, SLOT, s)); self.slot = s
                    ev.append((EV_ABS, TID, -1))
                elif s in cur:
                    old = self.prev.get(s)
                    vals = []
                    if old is None: vals.append((TID, s))
                    if old is None or old[0] != cur[s][0]: vals.append((PX, cur[s][0]))
                    if old is None or old[1] != cur[s][1]: vals.append((PY, cur[s][1]))
                    if old is None: vals.append((MAJOR, 30))
                    if old is None and self.pres is not None: vals.append((PRES, self.pres))
                    if vals and self.slot != s: ev.append((EV_ABS, SLOT, s)); self.slot = s
                    ev += [(EV_ABS, c, v) for c, v in vals]
        elif self.p in ('A', 'AID'):
            self.n += 1                         # protocol A has no order: send the contacts reversed every other frame
            for f, (x, y) in sorted(cur.items(), reverse=self.n % 2 == 0):
                if self.p == 'AID': ev.append((EV_ABS, TID, 100 + f))
                ev += [(EV_ABS, PX, x), (EV_ABS, PY, y), (EV_ABS, MAJOR, 30), (EV_SYN, SYN_MT_REPORT, 0)]
            if not cur: ev.append((EV_SYN, SYN_MT_REPORT, 0))
            if cur and not self.btn: ev.append((EV_KEY, BTN_TOUCH, 1))
            if not cur and self.btn: ev.append((EV_KEY, BTN_TOUCH, 0))
        else:                                   # ST: one finger only
            if cur:
                x, y = list(cur.values())[0]
                if x != self.stx: ev.append((EV_ABS, ABS_X, x)); self.stx = x
                if y != self.sty: ev.append((EV_ABS, ABS_Y, y)); self.sty = y
            if cur and not self.btn: ev.append((EV_KEY, BTN_TOUCH, 1))
            if not cur and self.btn: ev.append((EV_KEY, BTN_TOUCH, 0))
        self.btn = 1 if cur else 0
        self.prev = cur
        ev.append((EV_SYN, SYN_REPORT, 0))
        return ev


def path(points, ms, steps=12):
    """one finger moving from points[0] to points[1] in ms: list of (t_ms, x, y)"""
    (x1, y1), (x2, y2) = points
    return [(ms * i // steps, x1 + (x2 - x1) * i // steps, y1 + (y2 - y1) * i // steps) for i in range(steps + 1)]


def scenario(name):
    """-> list of (t_ms, fingers) frames; the last one is all-up"""
    S = {}
    S['tap'] = [(0, [(0, 500, 800)]), (60, [(0, 500, 800)]), (80, [])]
    S['tap2'] = S['tap'] + [(400, [(0, 500, 800)]), (460, [(0, 500, 800)]), (480, [])]   # same slot, same place, twice
    S['swipe'] = [(t, [(0, x, y)]) for t, x, y in path(((900, 800), (200, 820)), 300)] + [(320, [])]
    S['vswipe'] = [(t, [(0, x, y)]) for t, x, y in path(((600, 1200), (610, 400)), 300)] + [(320, [])]
    S['edge_back'] = [(t, [(0, x, y)]) for t, x, y in path(((636, 1680), (636, 1450)), 80, 4)] + [(100, [])]
    S['edge_back_slow'] = [(t, [(0, x, y)]) for t, x, y in path(((636, 1680), (636, 1450)), 150, 6)] + [(170, [])]
    S['edge_panel'] = [(t, [(0, x, y)]) for t, x, y in path(((636, 10), (636, 300)), 150, 6)] + [(170, [])]
    S['edge_tap'] = [(0, [(0, 636, 1660)]), (40, [(0, 636, 1660)]), (60, [])]
    # corner long press with frames every 200 ms, outside the top / bottom edge strips (--edge 120 < corner 160)
    S['corner'] = [(t, [(0, 50, 140)]) for t in range(0, 2400, 200)] + [(2450, [])]
    # corner long press starting INSIDE an edge strip (fix/corner-in-edge): the finger is held still, so after the
    # touch-down the driver sends nothing until the release -- only the poll tick can see the 2 s run out
    for c, (x, y) in {'tl': (50, 50), 'tr': (1222, 50), 'bl': (50, 1650), 'br': (1222, 1650)}.items():
        S['corner_strip_' + c] = [(0, [(0, x, y)]), (2450, [])]
    S['corner_strip_moving'] = [(t, [(0, 50 + (t // 200) % 2, 1650)]) for t in range(0, 2400, 200)] + [(2450, [])]
    # an edge swipe that starts in a corner is still back / panel; a tap in a corner inside the strip still reaches
    # Android; a long press in the strip outside the corners is not a gesture
    S['corner_swipe_back'] = [(t, [(0, x, y)]) for t, x, y in path(((60, 1680), (60, 1450)), 80, 4)] + [(100, [])]
    S['corner_swipe_panel'] = [(t, [(0, x, y)]) for t, x, y in path(((1212, 10), (1212, 300)), 150, 6)] + [(170, [])]
    S['corner_strip_tap'] = [(0, [(0, 50, 1650)]), (40, [(0, 50, 1650)]), (60, [])]
    S['strip_long'] = [(0, [(0, 636, 1650)]), (2450, [])]
    S['two_tap'] = [(0, [(0, 400, 800), (1, 800, 800)]), (80, [(0, 401, 800), (1, 800, 801)]), (150, [])]
    S['two_stagger'] = [(0, [(0, 400, 800)]), (20, [(0, 400, 800), (1, 800, 800)]), (150, [])]
    S['two_long'] = [(t, [(0, 400, 800), (1, 800, 800)]) for t in range(0, 2400, 200)] + [(2450, [])]
    S['two_back'] = [(t, [(0, 300 + 500 * i // 10, 800), (1, 300 + 500 * i // 10, 1000)]) for i, t in
                     enumerate(range(0, 220, 20))] + [(240, [])]
    S['two_light'] = [(t, [(0, 300, 1200 - 50 * i), (1, 400, 1200 - 50 * i)]) for i, t in
                      enumerate(range(0, 220, 20))] + [(240, [])]
    S['two_warmth'] = [(t, [(0, 900, 600 + 50 * i), (1, 1000, 600 + 50 * i)]) for i, t in
                       enumerate(range(0, 220, 20))] + [(240, [])]
    # every two-finger gesture off: two fingers go to Android (pinch); finger 0 moves left, finger 1 right
    # a fast drag (a frame every 4 ms, 6 px per frame): past PASS_PX after ~12 ms, long before the 40 ms window ends
    S['fast_drag'] = [(t, [(0, x, y)]) for t, x, y in path(((636, 1300), (636, 700)), 400, 100)] + [(420, [])]
    # a second finger 20 ms after the first, which moved a little (8 px, under PASS_PX): still the two-finger tap
    S['two_stagger_wobble'] = [(0, [(0, 400, 800)]), (10, [(0, 404, 804)]), (20, [(0, 404, 804), (1, 800, 800)]), (150, [])]
    S['pinch'] = [(t, [(0, 600 - 30 * i, 800), (1, 700 + 30 * i, 820)]) for i, t in enumerate(range(0, 220, 20))] + [(240, [])]
    # one of two fingers lifts, the other keeps moving (pinch off -> Android): the right one must keep its slot
    S['pinch_lift'] = ([(t, [(0, 400, 800), (1, 800 + 10 * i, 800)]) for i, t in enumerate(range(0, 100, 20))] +
                       [(t, [(1, 850 + 10 * i, 800)]) for i, t in enumerate(range(100, 200, 20))] + [(220, [])])
    # bottom edge in thirds (G_EDGE_THIRDS=1): swipe up from the left / middle / right third, swipe up and hold still
    up = lambda x, ms=80, st=4: [(t, [(0, xx, y)]) for t, xx, y in path(((x, 1680), (x, 1450)), ms, st)]
    S['eb_left'] = up(200) + [(100, [])]
    S['eb_mid'] = up(636) + [(100, [])]
    S['eb_right'] = up(1100) + [(100, [])]
    S['eb_left_slow'] = up(200, 150, 6) + [(170, [])]          # past the 60 ms edge hold: Android had the touch
    S['eb_hold'] = up(636) + [(200, [(0, 640, 1452)]), (900, [])]     # still (within the slop) for ~800 ms after the swipe
    S['eb_hold_left'] = up(200) + [(1000, [])]                  # no frames at all while held: only the idle tick sees it
    S['eb_hold_short'] = up(636) + [(400, [])]                  # held ~300 ms: not long enough
    S['eb_drag'] = [(t, [(0, x, y)]) for t, x, y in path(((636, 1680), (636, 700)), 1200, 40)] + [(1220, [])]   # slow, never still
    S['eb_tap'] = [(0, [(0, 200, 1660)]), (40, [(0, 200, 1660)]), (60, [])]
    return S[name]


EXPECT = {   # name -> (actions in the log, keys, touch reaches Android)
    'tap': ([], [], True), 'swipe': ([], [], True), 'vswipe': ([], [], True), 'edge_tap': ([], [], True),
    'edge_back': (['hint back'], [KEY_BACK], False), 'edge_back_slow': (['hint back'], [KEY_BACK], 'cancel'), 'edge_panel': (['panel'], [], False),
    'corner': (['tl'], [], 'cancel'),
    'corner_strip_tl': (['tl'], [], 'cancel'), 'corner_strip_tr': (['tr'], [], 'cancel'),
    'corner_strip_bl': (['bl'], [], 'cancel'), 'corner_strip_br': (['br'], [], 'cancel'),
    'corner_strip_moving': (['bl'], [], 'cancel'),
    'corner_swipe_back': (['hint back'], [KEY_BACK], False), 'corner_swipe_panel': (['panel'], [], False),
    'corner_strip_tap': ([], [], True), 'strip_long': ([], [], True),
    'two_tap': (['clear'], [], False), 'two_stagger': (['clear'], [], False), 'two_long': (['invert'], [], False),
    'two_back': (['hint back'], [KEY_BACK], False), 'fast_drag': ([], [], True), 'two_stagger_wobble': (['clear'], [], False), 'pinch': ([], [], True), 'pinch_lift': ([], [], True), 'two_light': (['light +'], [], False), 'two_warmth': (['warmth -'], [], False),
}
ONE = ['tap', 'swipe', 'vswipe', 'edge_tap', 'edge_back', 'edge_back_slow', 'edge_panel', 'corner',
       'corner_strip_tl', 'corner_strip_tr', 'corner_strip_bl', 'corner_strip_br', 'corner_strip_moving',
       'corner_swipe_back', 'corner_swipe_panel', 'corner_strip_tap', 'strip_long']
# behaviour this branch changes on purpose: the base binary fires nothing for these (corner check only in PASS)
CHANGED = {'corner_strip_tl', 'corner_strip_tr', 'corner_strip_bl', 'corner_strip_br', 'corner_strip_moving'}
PINCH = ['pinch', 'pinch_lift']
TWO = ['two_tap', 'two_stagger', 'two_stagger_wobble', 'two_long', 'two_back', 'two_light', 'two_warmth']


def held_suffix(frames, want, sent, lim_ms):
    """fix/next-input-tap: the frames held for the gesture decision reach Android as one touch-down at the latest held
    position, so Android's frames are `want` minus a prefix of frames that were all sent within lim_ms of the touch-down
    (the hold), possibly with the first frame of the rest being that latest held position"""
    if frames == want: return True
    t0 = sent[0][0] if sent else 0
    held = sum(1 for t, f in sent if f and (t - t0) * 1000 <= lim_ms)
    for k in range(1, held + 1):
        if frames == want[k:]: return True
    # ... and the tap dead zone (TAP_PX) after it: the touch-down at a held position, then the finger from where it left
    # the zone (a few more frames, also within lim_ms of the touch-down)
    if frames and frames[0] in want[:held + 1]:
        i = want.index(frames[0])
        for j in range(i + 1, held + 1):
            if frames[1:] == want[j:]: return True
    return False


def read_events(fn, skip_udev):
    if not os.path.exists(fn): return []
    b = open(fn, 'rb').read()
    if skip_udev: b = b[UDEV_SZ:]
    return [struct.unpack(EVFMT, b[i:i + EVSZ]) for i in range(0, len(b) - EVSZ + 1, EVSZ)]


def decode_mt(evs):
    """virtual protocol-B stream -> list of frames, each a sorted tuple of (x, y) of the active contacts"""
    slots, cur, frames = {}, 0, []
    for _, _, t, c, v in evs:
        if t == EV_ABS and c == SLOT: cur = v
        elif t == EV_ABS and c == TID:
            if v < 0: slots.pop(cur, None)
            else: slots[cur] = [None, None]
        elif t == EV_ABS and c in (PX, PY) and cur in slots: slots[cur][c - PX] = v
        elif t == EV_SYN and c == SYN_REPORT:
            f = tuple(sorted(tuple(p) for p in slots.values()))
            if not frames or frames[-1] != f: frames.append(f)
    return frames


class EncoderPT(Encoder):
    """pt_mt (KT5 / KT6): protocol B, 32 slots, a fresh tracking id per contact (input_mt), optionally no BTN_TOUCH"""
    def __init__(self, nobtn=True):
        Encoder.__init__(self, 'B'); self.nobtn = nobtn; self.tid = 500

    def frame(self, fingers):
        ev = []
        cur = {f: (x, y) for f, x, y in fingers}
        if not self.nobtn and cur and not self.btn: ev.append((EV_KEY, BTN_TOUCH, 1))
        if not self.nobtn and not cur and self.btn: ev.append((EV_KEY, BTN_TOUCH, 0))
        for s in range(32):
            if s in self.prev and s not in cur:
                if self.slot != s: ev.append((EV_ABS, SLOT, s)); self.slot = s
                ev.append((EV_ABS, TID, -1))
            elif s in cur:
                old = self.prev.get(s); vals = []
                if old is None: self.tid += 1; vals.append((TID, self.tid))
                if old is None or old[0] != cur[s][0]: vals.append((PX, cur[s][0]))
                if old is None or old[1] != cur[s][1]: vals.append((PY, cur[s][1]))
                if old is None: vals.append((MAJOR, 30))
                if vals and self.slot != s: ev.append((EV_ABS, SLOT, s)); self.slot = s
                ev += [(EV_ABS, c, v) for c, v in vals]
        self.btn = 1 if cur else 0; self.prev = cur
        ev.append((EV_SYN, SYN_REPORT, 0))
        return ev


def run(binary, shim, proto, name, env_extra=None, pres_send=None, inject=None, extra=None, gextra='', frames=None, enc=None):
    """frames: instead of scenario(name); a frame is a list of fingers, ('raw', [(type, code, value), ...]) sent as is,
    or ('file', path, text) written at that time (VT_MTSTATE: what the kernel says)"""
    d = tempfile.mkdtemp(prefix='vt-')
    fifo = os.path.join(d, 'touch'); os.mkfifo(fifo)
    log = os.path.join(d, 'log')
    gconf = os.path.join(d, 'gestures')
    two = 0 if name in PINCH else 1
    open(gconf, 'w').write('G_EDGE_BACK=1\nG_EDGE_PANEL=1\n' + ''.join('%s=%d\n' % (k, two) for k in ('G_TWO_TAP', 'G_TWO_LONG', 'G_TWO_BACK', 'G_TWO_SLIDE')) + gextra)
    env = dict(os.environ, LD_PRELOAD=shim, VT_SRC=fifo, VT_CAPS=proto, VT_OUT=d, **(env_extra or {}))
    ifile = os.path.join(d, 'inject')
    p = subprocess.Popen([binary, fifo, log, '', '--gconf', gconf] + ARGS + (['--inject', ifile] if inject else []) + (extra or []),
                         env=env, stderr=subprocess.PIPE)
    w = open(fifo, 'wb', buffering=0)
    time.sleep(0.3)
    enc = enc or Encoder('ST' if proto == 'ST' else proto, pres_send)
    t0 = time.monotonic(); sent = []
    for line in inject or []:
        with open(ifile, 'w') as f: f.write(line + '\n')
        time.sleep(0.4)
    for t, fingers in ([] if inject else frames if frames is not None else scenario(name)):
        dt = t0 + t / 1000 - time.monotonic()
        if dt > 0: time.sleep(dt)
        now = time.monotonic()
        sec, usec = int(now), int((now - int(now)) * 1e6)
        if fingers and fingers[0] == 'file':
            open(fingers[1], 'w').write(fingers[2]); continue
        evs = fingers[1] if fingers and fingers[0] == 'raw' else enc.frame(fingers)
        w.write(b''.join(struct.pack(EVFMT, sec, usec, a, b, c) for a, b, c in evs))
        sent.append((now, [] if fingers and fingers[0] == 'raw' else fingers))
    time.sleep(0.4)
    w.close(); p.wait(timeout=5)
    touch = read_events(os.path.join(d, 'uinput0'), True)
    keys = read_events(os.path.join(d, 'uinput1'), True)
    acts = [l.split('] action ', 1)[1].strip() for l in open(log) if '] action ' in l and 'poke' not in l]
    return dict(touch=touch, keys=[c for _, _, t, c, v in keys if t == EV_KEY and v == 1], acts=acts, sent=sent, dir=d,
                log=open(log).read())


def android_state(evs):
    """what Android's reader holds after the stream: {slot: tracking id} of the contacts down, BTN_TOUCH"""
    slots, cur, btn = {}, 0, 0
    for _, _, t, c, v in evs:
        if t == EV_ABS and c == SLOT: cur = v
        elif t == EV_ABS and c == TID:
            if v < 0: slots.pop(cur, None)
            else: slots[cur] = v
        elif t == EV_KEY and c == BTN_TOUCH: btn = v
    return slots, btn


def max_contacts(evs, since=0):
    """the most contacts Android had down at once (per SYN_REPORT written at or after `since`, monotonic seconds)"""
    slots, cur, m = set(), 0, 0
    for sec, usec, t, c, v in evs:
        if t == EV_ABS and c == SLOT: cur = v
        elif t == EV_ABS and c == TID: (slots.discard(cur) if v < 0 else slots.add(cur))
        elif t == EV_SYN and c == SYN_REPORT and sec + usec / 1e6 >= since: m = max(m, len(slots))
    return m


def new_contact_pressures(evs):
    """virtual stream -> [(slot, pressure sent in the frame of its new tracking id, or None)], plus all pressures sent"""
    cur, new, pres, out, every = 0, set(), {}, [], []
    for _, _, t, c, v in evs:
        if t == EV_ABS and c == SLOT: cur = v
        elif t == EV_ABS and c == TID and v >= 0: new.add(cur)
        elif t == EV_ABS and c == PRES: pres[cur] = v; every.append(v)
        elif t == EV_SYN and c == SYN_REPORT:
            out += [(s, pres.get(s)) for s in sorted(new)]
            new, pres = set(), {}
    return out, every


def pressure_cases(new):
    shim = sys.argv[2]
    print('== panels with ABS_MT_PRESSURE')
    for proto in ['B', 'A', 'AID']:
        for name in ['tap', 'tap2', 'swipe', 'pinch']:
            r = run(new, shim, proto, name, {'VT_PRES': '255'})
            got, every = new_contact_pressures(r['touch'])
            ok = len(got) >= (2 if name in ('tap2', 'pinch') else 1) and all(p is not None and p > 0 for _, p in got)
            check(ok, f'{proto} {name}, panel sends no pressure: every new contact got one {got}')
            if name == 'tap2':
                check(len(got) == 2 and got[0][1] != got[1][1], f'{proto} tap2: the second contact in the same slot got a different value {got}')
            if '-k' not in sys.argv: subprocess.call(['rm', '-rf', r['dir']])
    for name in ['tap', 'tap2', 'pinch']:
        r = run(new, shim, 'B', name, {'VT_PRES': '255'}, pres_send=40)
        got, every = new_contact_pressures(r['touch'])
        check(got and all(p == 40 for _, p in got) and all(v == 40 for v in every),
              f'B {name}, panel sends pressure 40: forwarded untouched {got} (all pressures sent {sorted(set(every))})')
        if '-k' not in sys.argv: subprocess.call(['rm', '-rf', r['dir']])
    r = run(new, shim, 'B', 'tap', {'VT_PRES': '255'}, inject=['tap 500 800', 'tap 500 800', 'swipe 900 800 200 820 200'])
    got, every = new_contact_pressures(r['touch'])
    check(len(got) == 3 and all(p is not None and p > 0 for _, p in got) and got[0][1] != got[1][1],
          f'--inject tap, tap, swipe: every contact got a pressure, the repeat a different one {got}')
    if '-k' not in sys.argv: subprocess.call(['rm', '-rf', r['dir']])
    r = run(new, shim, 'B', 'tap2')
    got, every = new_contact_pressures(r['touch'])
    check(not every, f'B tap2 without a pressure axis: no pressure sent ({every})')
    if '-k' not in sys.argv: subprocess.call(['rm', '-rf', r['dir']])


def early_release_cases(new):
    """PASS_PX: a single finger that moved past it inside the two-finger window goes to Android at once"""
    shim = sys.argv[2]
    print('== early release (PASS_PX)')
    def down_lat(name, gextra=''):
        r = run(new, shim, 'B', name, gextra=gextra)
        downs = [e for e in r['touch'] if e[2] == EV_ABS and e[3] in (PX, TID)]
        if '-k' not in sys.argv: subprocess.call(['rm', '-rf', r['dir']])
        return (downs[0][0] + downs[0][1] / 1e6 - r['sent'][0][0]) * 1000 if downs else None, decode_mt(r['touch']), r
    lat, frames, r = down_lat('fast_drag')
    check(lat is not None and lat < WINDOW - 10, f'fast drag: touch-down forwarded after {lat:.0f} ms (< {WINDOW - 10}, before the window ends)')
    want = []
    for _, fingers in r['sent']:
        f = tuple(sorted((x, y) for _, x, y in fingers))
        if not want or want[-1] != f: want.append(f)
    check(held_suffix(frames, want, r['sent'], WINDOW), f'fast drag: every position after the early release reached Android ({len(frames)} of {len(want)} frames)')
    lat, frames, r = down_lat('fast_drag', 'PASS_PX=0\n')
    check(lat is not None and lat >= WINDOW - 2, f'PASS_PX=0: touch-down waits for the window ({lat:.0f} ms)')
    lat, frames, r = down_lat('tap')
    check(lat is not None and lat >= WINDOW - 2, f'tap (no movement): still waits for the window ({lat:.0f} ms)')

def held_compact_cases(new):
    """fix/next-input-tap (多看 on KT6: tap-to-turn did nothing or went back a page): the frames held for the gesture
    decision used to be replayed to uinput in one burst (the kernel stamps the write time), so a tap with a few px of
    jitter reached Android as a move of thousands of px/s. Now: one touch-down at the latest held position (+ the lift
    when the finger already left); HELD_REPLAY=1 brings the replay back; a quick flick that ends inside the hold is still
    replayed as a flick."""
    shim = sys.argv[2]
    print('== held frames: one touch-down, not a burst (fix/next-input-tap)')
    jit = [(0, [(0, 800, 700)]), (10, [(0, 803, 701)]), (20, [(0, 806, 703)]), (30, [])]
    jit_long = [(0, [(0, 800, 700)]), (10, [(0, 803, 701)]), (20, [(0, 806, 703)]), (30, [(0, 807, 703)]), (60, [(0, 808, 704)]), (90, [(0, 808, 704)]), (110, [])]
    def frames_of(fr, gextra='', proto='B', enc=None):
        r = run(new, shim, proto, 'tap', frames=fr, gextra=gextra, enc=enc)
        f = decode_mt(r['touch'])
        if '-k' not in sys.argv: subprocess.call(['rm', '-rf', r['dir']])
        return f, r
    for proto in ['B', 'A', 'ST']:
        f, r = frames_of(jit, proto=proto)
        check(f == [((806, 703),), ()], f'{proto} 30 ms tap with 6 px jitter: Android gets down at the last position + up, no moves {f}')
    f, r = frames_of(jit, enc=EncoderPT())
    check(f == [((806, 703),), ()], f'pt_mt (KT6) 30 ms jittery tap: down + up {f}')
    f, r = frames_of(jit_long)
    check(f[:1] in ([((806, 703),)], [((807, 703),)]) and f[-1] == () and ((800, 700),) not in f and ((803, 701),) not in f,
          f'110 ms jittery tap (longer than the window): the held part is one touch-down, the jitter after it stays in the tap dead zone {f}')
    f, r = frames_of(jit, 'HELD_REPLAY=1\n')
    check(f == [((800, 700),), ((803, 701),), ((806, 703),), ()], f'HELD_REPLAY=1: the old replay {f}')
    # bottom edge strip (held 60 ms): a quick horizontal flick that ends inside the hold stays a flick
    flick = [(t, [(0, x, 1660)]) for t, x, y in path(((900, 1660), (700, 1660)), 40, 4)] + [(50, [])]
    f, r = frames_of(flick)
    check(len(f) >= 4 and f[0] == ((900, 1660),) and f[-1] == (), f'edge strip flick inside the hold: replayed as a flick ({len(f)} frames)')
    # a plain tap in the edge strip with jitter: down + up
    et = [(0, [(0, 600, 1660)]), (15, [(0, 603, 1661)]), (35, [])]
    f, r = frames_of(et)
    check(f == [((603, 1661),), ()], f'edge strip jittery tap: down + up {f}')
    # tap dead zone (TAP_PX, 28 px on this 1272 px panel): a tap whose contact drifts 25 px down over 120 ms (多看's flip
    # gesture: > 20 px from the touch-down = a swipe, down = previous page) reaches Android without the drift
    drift = [(0, [(0, 600, 800)])] + [(t, [(0, 600, 800 + 25 * t // 120)]) for t in range(10, 130, 10)] + [(140, [])]
    f, r = frames_of(drift)
    ys = [c[0][1] for c in f if c]
    check(f[-1] == () and len(ys) == 1 and ys[0] <= 800 + 25 * 40 // 120 + 1, f'25 px drifting tap: one position (the held touch-down), no move reaches Android {f}')
    f, r = frames_of(drift, 'TAP_PX=0\n')
    ys = [c[0][1] for c in f if c]
    check(max(ys) - min(ys) >= 15, f'TAP_PX=0: the drift is forwarded as before {ys}')
    # a slow drag leaves the zone: from then on Android follows the finger, the first frame out has both axes
    slow = [(0, [(0, 600, 800)])] + [(t, [(0, 600 + t // 10, 800 + t // 4)]) for t in range(10, 400, 10)] + [(410, [])]
    f, r = frames_of(slow)
    ys = [c[0][1] for c in f if c]
    check(f[-1] == () and len(ys) > 20 and ys[-1] == 800 + 390 // 4 and all(b > a for a, b in zip(ys[1:], ys[2:])),
          f'slow drag: out of the dead zone Android follows the finger ({len(ys)} positions, last {f[-2] if len(f) > 1 else None})')
    out = [c for c in f[1:] if c]
    if out:
        x, y = out[0][0]
        check(y - 800 > 28 and abs(x - (600 + (y - 800) * 4 // 10)) <= 1, f'slow drag: the first position out of the zone has both axes where the finger is ({x}, {y})')
    else: check(False, 'slow drag: no position out of the zone')
    # injected down / move / up (the emulator's test hook): moves are not lifted by the stuck watchdog
    r = run(new, shim, 'B', 'tap', inject=['down 500 800', 'move 520 800', 'move 560 800', 'up'])
    f = decode_mt(r['touch'])
    check(((560, 800),) in f and f[-1] == () and 'resync (watchdog)' not in r['log'], f'--inject down/move/up: the moves reach Android, no watchdog lift {f}')
    if '-k' not in sys.argv: subprocess.call(['rm', '-rf', r['dir']])


THIRDS = [   # (scenario, gconf extra, extra args, actions, keys, touch reaches Android)
    ('eb_left', '', [], ['eb appopt'], [], False),
    ('eb_mid', '', [], ['eb home'], [], False),
    ('eb_right', '', [], ['hint back'], [KEY_BACK], False),
    ('eb_left_slow', '', [], ['eb appopt'], [], 'cancel'),
    ('eb_hold', '', [], ['eb switch'], [], False),
    ('eb_hold_left', '', [], ['eb switch'], [], False),
    ('eb_hold_short', '', [], ['eb home'], [], False),
    ('eb_drag', '', [], ['eb home'], [], 'cancel'),
    ('eb_tap', '', [], [], [], True),
    # custom actions; a hold of "none" fires at once; a third and the hold both none: not a gesture there
    ('eb_mid', 'G_EB_M=panel\nG_EB_HOLD=none\n', [], ['eb panel'], [], False),
    ('eb_hold', 'G_EB_HOLD=kindle\nG_EB_HOLD_MS=600\n', [], ['eb kindle'], [], False),
    ('eb_left', 'G_EB_L=none\nG_EB_HOLD=none\n', [], [], [], True),
    ('eb_right', 'G_EB_R=none\n', [], [], [], False),          # swallowed (the hold could still come), nothing fired
    ('eb_left', 'G_EB_L=rm;x\n', [], ['eb appopt'], [], False),  # not a plain name: the default stays
    # thirds off / the bottom edge off / gestures off (--flag): as before
    ('eb_left', 'G_EDGE_THIRDS=0\n', [], ['hint back'], [KEY_BACK], False),
    ('eb_mid', 'G_EDGE_BACK=0\n', [], [], [], True),
    ('eb_hold', '', ['--flag', '/'], ['hint back'], [KEY_BACK], False),
]


def thirds_cases(new):
    shim = sys.argv[2]
    print('== bottom edge in thirds (G_EDGE_THIRDS)')
    for proto in ['B', 'A', 'ST']:
        for name, gx, extra, acts, keys, fwd in THIRDS:
            r = run(new, shim, proto, name, extra=extra, gextra='G_EDGE_THIRDS=1\n' + gx)
            label = f'{proto} {name} [{gx.strip().replace(chr(10), " ") or "defaults"}{" " + " ".join(extra) if extra else ""}]'
            check(r['acts'] == acts and r['keys'] == keys, f'{label}: actions {r["acts"]} keys {r["keys"]}')
            frames = decode_mt(r['touch'])
            if fwd is True: check(frames and frames[-1] == () and len(frames) >= 2, f'{label}: Android got the touch ({len(frames)} frames)')
            elif fwd is False: check(all(f == () for f in frames), f'{label}: nothing reached Android ({len(frames)} frames)')
            else: check(frames[-1:] == [()] and len(frames) >= 2, f'{label}: Android got the touch and then its cancel')
            if name in ('eb_hold', 'eb_hold_left') and not gx and not extra:
                lg = open(os.path.join(r['dir'], 'log')).read()
                fired = [int(l[1:l.index(']')]) for l in lg.splitlines() if 'edge thirds: hold' in l]
                check(len(fired) == 1, f'{label}: hold fired once ({len(fired)})')
                if name == 'eb_hold_left' and fired:   # vinput logs CLOCK_MONOTONIC ms, the same clock as time.monotonic()
                    stop, lift = r['sent'][-2][0] * 1000, r['sent'][-1][0] * 1000
                    check(stop + 450 <= fired[0] <= min(lift, stop + 650),
                          f'{label}: hold fired {fired[0] - stop:.0f} ms after the finger stopped, {lift - fired[0]:.0f} ms before the lift')
            if '-k' not in sys.argv: subprocess.call(['rm', '-rf', r['dir']])
    # scroll hint: an armed bottom-edge swipe never leaves the bridge in scroll mode
    d = tempfile.mkdtemp(prefix='vb-')
    ef = os.path.join(d, 'epd.fifo'); os.mkfifo(ef)
    fd = os.open(ef, os.O_RDWR); os.set_blocking(fd, False)
    r = run(new, shim, 'B', 'eb_left_slow', extra=['--epd-fifo', ef], gextra='G_EDGE_THIRDS=1\n')
    try: buf = os.read(fd, 65536).decode()
    except BlockingIOError: buf = ''
    sc = [l for l in buf.split('\n') if l.startswith('SCROLL')]
    check(sc in ([], ['SCROLL 1', 'SCROLL 0']), f'thirds slow swipe: scroll hints balanced ({sc})')
    os.close(fd)
    if '-k' not in sys.argv: subprocess.call(['rm', '-rf', r['dir'], d])


def boost_scroll_cases(new):
    """touch boost (--cpufreq, BOOST_MS) and scroll hints (SCROLL 1 / SCROLL 0 on --epd-fifo, SCROLL_PX)"""
    import threading
    shim = sys.argv[2]
    print('== touch boost and scroll hints')
    def one(name, gextra='', proto='B'):
        d = tempfile.mkdtemp(prefix='vb-')
        open(os.path.join(d, 'scaling_min_freq'), 'w').write('600000\n')
        open(os.path.join(d, 'scaling_max_freq'), 'w').write('2000000\n')
        ef = os.path.join(d, 'epd.fifo'); os.mkfifo(ef)
        lines, seen, stop = [], set(), [False]
        def reader():
            fd = os.open(ef, os.O_RDWR)            # keeps a writer so reads never see EOF
            os.set_blocking(fd, False)
            buf = b''
            while not stop[0]:
                try: buf += os.read(fd, 4096)
                except BlockingIOError: pass
                v = open(os.path.join(d, 'scaling_min_freq')).read().strip()
                seen.add(v)
                time.sleep(0.003)
            try: buf += os.read(fd, 4096)
            except BlockingIOError: pass
            lines.extend(l for l in buf.decode().split('\n') if l)
        th = threading.Thread(target=reader); th.start()
        time.sleep(0.05)
        r = run(new, shim, proto, name, extra=['--cpufreq', d, '--epd-fifo', ef], gextra=gextra)
        time.sleep(0.3)
        stop[0] = True; th.join()
        final = open(os.path.join(d, 'scaling_min_freq')).read().strip()
        if '-k' not in sys.argv: subprocess.call(['rm', '-rf', r['dir'], d])
        return seen, final, [l for l in lines if l.startswith('SCROLL')]
    seen, final, sc = one('tap')
    check('2000000' in seen and final == '600000', f'tap: min freq raised to the max while touched, back after ({sorted(seen)} -> {final})')
    check(sc == [], f'tap: no scroll hint ({sc})')
    seen, final, sc = one('swipe')
    check('2000000' in seen and final == '600000', f'swipe: boosted and restored ({sorted(seen)} -> {final})')
    check(sc == ['SCROLL 1', 'SCROLL 0'], f'swipe: SCROLL 1 then SCROLL 0 ({sc})')
    seen, final, sc = one('vswipe', proto='A')
    check(sc == ['SCROLL 1', 'SCROLL 0'], f'vertical swipe, protocol A: SCROLL 1 then SCROLL 0 ({sc})')
    seen, final, sc = one('edge_back')
    check(sc == [], f'edge back gesture: no scroll hint ({sc})')
    seen, final, sc = one('two_back')
    check(sc == [], f'two-finger gesture: no scroll hint ({sc})')
    seen, final, sc = one('swipe', 'BOOST_MS=0\nSCROLL_PX=0\n')
    check(seen == {'600000'} and final == '600000' and sc == [], f'BOOST_MS=0 SCROLL_PX=0: nothing touched ({sorted(seen)}, {sc})')
    seen, final, sc = one('tap', 'BOOST_KHZ=1000000\n')
    check('1000000' in seen and '2000000' not in seen and final == '600000', f'BOOST_KHZ=1000000: that frequency ({sorted(seen)} -> {final})')


def stuck_frames(seed):
    """random multi-finger stream: edge swipes (top / bottom), taps, drags, holds, overlapping, in any free slot 0..3"""
    import random
    rng = random.Random(seed)
    touches = []; t = 0
    for _ in range(rng.randint(2, 5)):
        kind = rng.choice(['top', 'top', 'bottom', 'tap', 'drag', 'hold'])
        start = t + rng.randint(0, 120)
        if kind == 'top': x, y = rng.randint(100, 1100), rng.randint(5, 100); dx, dy = rng.randint(-40, 40), rng.randint(60, 300); dur = rng.randint(40, 300)
        elif kind == 'bottom': x, y = rng.randint(100, 1100), rng.randint(1600, 1690); dx, dy = rng.randint(-40, 40), -rng.randint(60, 300); dur = rng.randint(40, 300)
        elif kind == 'tap': x, y = rng.randint(200, 1000), rng.randint(300, 1400); dx = dy = 0; dur = rng.randint(20, 150)
        elif kind == 'drag': x, y = rng.randint(200, 1000), rng.randint(300, 1400); dx, dy = rng.randint(-400, 400), rng.randint(-400, 400); dur = rng.randint(80, 400)
        else: x, y = rng.randint(200, 1000), rng.randint(300, 1400); dx = dy = 0; dur = rng.randint(200, 600)
        touches.append((start, start + dur, x, y, dx, dy))
        t = start + rng.choice([0, 10, 30, 50, 80, dur, dur + 50])
    end = max(e for _, e, *_ in touches)
    frames = []; slot_of = {}
    for tm in range(0, end + 25, 12):
        fingers = []
        for i, (s, e, x, y, dx, dy) in enumerate(touches):
            if s <= tm < e:
                if i not in slot_of:
                    used = {slot_of[j] for j in slot_of if touches[j][0] <= tm < touches[j][1]}
                    free = [k for k in range(4) if k not in used]
                    if not free: continue
                    slot_of[i] = rng.choice(free) if rng.random() < 0.5 else free[0]
                f = (tm - s) / max(1, e - s)
                fingers.append((slot_of[i], int(x + dx * f), int(y + dy * f)))
        frames.append((tm, fingers))
    frames.append((end + 40, []))
    return frames


def stuck_cases(new):
    shim = sys.argv[2]
    print('== stuck contacts')
    PT = {'VT_NOBTN': '1', 'VT_SLOTS': '32'}
    def done(r):
        if '-k' not in sys.argv: subprocess.call(['rm', '-rf', r['dir']])
    # the KT5 diag: a two-finger tap (slots 0 + 1, swallowed: the panel's slot pointer ends on 1, Android's stays on 0),
    # then an edge swipe from the top in slot 1 (pt_mt hands out touch ids, not always the lowest free slot) that is
    # held, handed to Android (EDGE_FWD) and then taken back for the panel, then an ordinary tap. Before the fix the
    # swipe's contact went to Android's slot 0, the cancel lifted slot 1, slot 0 stayed down for good and the tap (slot 1
    # again) became the second pointer of a gesture that never ended; input.log showed the diag's signature, "btn_touch:
    # panel left it out on a new contact" right before "action panel".
    seq = ([(0, [(0, 400, 800), (1, 800, 800)]), (60, [(0, 401, 800), (1, 800, 801)]), (100, [(1, 800, 801)]), (120, [])] +
           [(300 + t, [(1, x, y)]) for t, x, y in path(((215, 30), (215, 330)), 400, 20)] + [(720, [])] +
           [(1000, [(1, 672, 924)]), (1080, [(1, 672, 924)]), (1100, [])])
    for nobtn in (True, False):
        r = run(new, shim, 'B', 'stuck_panel', PT if nobtn else {'VT_SLOTS': '32'}, frames=seq, enc=EncoderPT(nobtn))
        before = [e for e in r['touch'] if e[0] + e[1] / 1e6 < r['sent'][0][0] + 0.95]
        st, btn = android_state(before)
        tag = 'no BTN_TOUCH' if nobtn else 'BTN_TOUCH'
        check(r['acts'] == ['clear', 'panel'], f'swallowed slot change, then edge swipe -> panel ({tag}): actions {r["acts"]}')
        check(st == {} and btn == 0, f'... Android has no contact left after the panel opened ({st}, BTN_TOUCH {btn})')
        st, btn = android_state(r['touch'])
        check(st == {} and btn == 0, f'... nor at the end ({st}, BTN_TOUCH {btn})')
        mc = max_contacts(r['touch'], r['sent'][0][0] + 0.95)
        check(mc == 1, f'... the tap after it is a one-finger tap ({mc} contact(s) down in Android)')
        done(r)
    # a tracking id that changes without a lift while Android has the contact (a lost lift, or a slot reused in one frame)
    raw = [(0, ('raw', [(EV_ABS, SLOT, 0), (EV_ABS, TID, 10), (EV_ABS, PX, 500), (EV_ABS, PY, 800), (EV_SYN, SYN_REPORT, 0)])),
           (100, ('raw', [(EV_ABS, PX, 520), (EV_SYN, SYN_REPORT, 0)])),
           (200, ('raw', [(EV_ABS, TID, 11), (EV_ABS, PX, 900), (EV_ABS, PY, 300), (EV_SYN, SYN_REPORT, 0)])),
           (300, ('raw', [(EV_ABS, PX, 905), (EV_SYN, SYN_REPORT, 0)])),
           (400, ('raw', [(EV_ABS, TID, -1), (EV_SYN, SYN_REPORT, 0)]))]
    r = run(new, shim, 'B', 'tidchg', PT, frames=raw)
    fr = decode_mt(r['touch']); st, btn = android_state(r['touch'])
    check(() in fr[1:-1] and ((900, 300),) in fr and st == {}, f'tracking id change without a lift: Android got a lift, then the new contact {fr}')
    check('without a lift' in r['log'], 'tracking id change: logged')
    done(r)
    # watchdog: the finger is down (Android has it), then the kernel has no contact in that slot but the lift never
    # arrives (no more events): after --stuck-ms the contact is lifted, here and in Android
    d = tempfile.mkdtemp(prefix='vs-'); mt = os.path.join(d, 'mtstate')
    down = [(0, [(0, 500, 800)]), (100, [(0, 540, 800)])]   # 40 px: out of the tap dead zone (TAP_PX), Android gets the move
    r = run(new, shim, 'B', 'wd', dict(PT, VT_MTSTATE=mt), frames=down + [(150, ('file', mt, '')), (900, [])],
            extra=['--stuck-ms', '300'], enc=EncoderPT())
    st, btn = android_state(r['touch'])
    lift = [e for e in r['touch'] if e[2] == EV_ABS and e[3] == TID and e[4] < 0]
    t_lift = lift[0][0] + lift[0][1] / 1e6 - r['sent'][0][0] if lift else None
    check(st == {} and t_lift is not None and 0.35 < t_lift < 0.85 and 'resync (watchdog)' in r['log'],
          f'watchdog: a lift the kernel has but never sent is done after --stuck-ms (at {t_lift and round(t_lift * 1000)} ms)')
    done(r)
    # ... but a finger resting still (no events; the kernel still has it, or there is no kernel slot state) stays down
    for env, what in ((dict(PT, VT_MTSTATE=os.path.join(d, 'none')), 'kernel has it'), (PT, 'no EVIOCGMTSLOTS')):
        r = run(new, shim, 'B', 'wd2', env, frames=down + [(1000, [])], extra=['--stuck-ms', '300'], enc=EncoderPT())
        fr = decode_mt(r['touch'])
        check(fr == [((500, 800),), ((540, 800),), ()] and 'resync (watchdog)' not in r['log'] and 'release:' not in r['log'],
              f'watchdog: a finger resting still 0.9 s stays down ({what}) {fr}')
        done(r)
    subprocess.call(['rm', '-rf', d])
    # the host's "reset" (freeze / thaw): Android gets the finger lifted, the rest of that touch goes nowhere, the next works
    r = run(new, shim, 'B', 'reset', PT, inject=['down 500 800', 'reset freeze', 'up', 'tap 600 900'])
    fr = decode_mt(r['touch']); st, btn = android_state(r['touch'])
    check(fr == [((500, 800),), (), ((600, 900),), ()] and st == {} and 'reset (freeze)' in r['log'], f'reset: lifted in Android, the next tap normal {fr}')
    done(r)
    # pt_mt has 32 slots: a contact in slot 20 is seen by the gestures (slots >= 16 used to be ignored)
    hi = [(0, [(20, 400, 800), (21, 800, 800)]), (80, [(20, 401, 800), (21, 800, 801)]), (150, [])]
    r = run(new, shim, 'B', 'hi', PT, frames=hi, enc=EncoderPT())
    check(r['acts'] == ['clear'] and all(f == () for f in decode_mt(r['touch'])), f'two-finger tap in slots 20 + 21: {r["acts"]}')
    done(r)
    # every gesture / pass-through case on a pt_mt-like panel: same actions and contacts, nothing left down
    for name in ONE + TWO + PINCH:
        r = run(new, shim, 'B', name, PT, enc=EncoderPT())
        acts, keys, fwd = EXPECT[name]
        st, btn = android_state(r['touch'])
        ok = r['acts'] == acts and r['keys'] == keys and st == {} and btn == 0
        if fwd is True:
            want = []
            for _, fingers in r['sent']:
                f = tuple(sorted((x, y) for _, x, y in fingers))
                if not want or want[-1] != f: want.append(f)
            hl = (60 if name.startswith('edge') or 'strip' in name else WINDOW) + 25
            ok = ok and held_suffix(decode_mt(r['touch']), want, r['sent'], hl)
        check(ok, f'pt_mt {name}: actions {r["acts"]}, Android left with {st} BTN_TOUCH {btn}')
        done(r)
    # random multi-finger streams (seeds 119, 1201, 1380, 5106, 5234 left a contact down before the fix)
    seeds = [119, 1201, 1380, 5106, 5234] + list(range(7000, 7020))
    bad = []
    for sd in seeds:
        for nobtn in (True, False):
            r = run(new, shim, 'B', 'rand', PT if nobtn else {'VT_SLOTS': '32'}, frames=stuck_frames(sd), enc=EncoderPT(nobtn))
            st, btn = android_state(r['touch'])
            if st or btn: bad.append((sd, nobtn, st, btn, r['acts']))
            done(r)
    check(not bad, f'{len(seeds) * 2} random multi-finger streams: Android never left with a contact down {bad}')


fails = 0
def check(cond, msg):
    global fails
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond: fails += 1


def main():
    new, shim = sys.argv[1], sys.argv[2]
    base = sys.argv[sys.argv.index('--base') + 1] if '--base' in sys.argv else None
    if os.environ.get('VT_ONLY') == 'held':          # VT_ONLY=held sh tests/vinput-test.sh: just the held-frames / dead zone cases
        held_compact_cases(new)
        print('FAILED: %d' % fails if fails else 'all passed'); sys.exit(1 if fails else 0)
    ref = {}
    for proto in ['B', 'A', 'AID', 'ST']:
        print(f'== source protocol {proto}')
        for name in ONE + (TWO + PINCH if proto != 'ST' else []):
            r = run(new, shim, proto, name)
            acts, keys, fwd = EXPECT[name]
            check(r['acts'] == acts and r['keys'] == keys, f'{name}: actions {r["acts"]} keys {r["keys"]}')
            frames = decode_mt(r['touch'])
            if fwd is True:
                # the contacts Android sees: one finger, following the same path as the source (positions per frame)
                want = []
                for _, fingers in r['sent']:
                    f = tuple(sorted((x, y) for _, x, y in fingers))
                    if not want or want[-1] != f: want.append(f)
                hl = (60 if name.startswith('edge') or 'strip' in name else WINDOW) + 25
                check(held_suffix(frames, want, r['sent'], hl), f'{name}: virtual touch screen got the same contacts, the hold as one touch-down ({len(frames)} of {len(want)} frames)')
                downs = [e for e in r['touch'] if e[2] == EV_ABS and e[3] in (PX, TID)]
                if downs:
                    lat = (downs[0][0] + downs[0][1] / 1e6 - r['sent'][0][0]) * 1000
                    lim = (60 if name.startswith('edge') or 'strip' in name else WINDOW) + 25
                    check(lat <= lim, f'{name}: touch-down forwarded after {lat:.0f} ms (limit {lim})')
                if name in PINCH:          # each finger stays in its own slot: per slot x only ever moves one way
                    xs, cur = {}, 0
                    for e in r['touch']:
                        if e[2] == EV_ABS and e[3] == SLOT: cur = e[4]
                        if e[2] == EV_ABS and e[3] == PX: xs.setdefault(cur, []).append(e[4])
                    mono = all(v == sorted(v) or v == sorted(v, reverse=True) for v in xs.values())
                    check(len(xs) == 2 and mono, f'{name}: each finger kept its slot {xs}')
                if proto == 'B': ref[name] = frames
                elif name in ref: check(frames == ref[name], f'{name}: same as protocol B')
            elif fwd is False:
                check(all(f == () for f in frames), f'{name}: nothing reached Android ({len(frames)} frames)')
            else:
                check(frames[-1:] == [()], f'{name}: Android got the touch and then its cancel')
            if proto == 'B' and base and name in CHANGED:
                o = run(base, shim, proto, name)
                check(o['acts'] == [] and o['keys'] == [], f'{name}: the old binary fired nothing here ({o["acts"]}) -- the intended change')
            elif proto == 'B' and base:
                o = run(base, shim, proto, name)
                # 'hint ...' actions (the on-screen gesture hint) came after the base binary on purpose: not compared
                nohint = lambda a: [x for x in a if not x.startswith('hint ')]
                same_ka = o['keys'] == r['keys'] and nohint(o['acts']) == nohint(r['acts'])
                raw = [e[2:] for e in o['touch']] == [e[2:] for e in r['touch']]
                # fix/vinput-stuck names the slot in every frame and lifts by what Android was told: the raw stream can carry
                # extra / fewer ABS_MT_SLOT writes than the old binary while Android sees the same contacts frame by frame
                of, nf = decode_mt(o['touch']), decode_mt(r['touch'])
                compact = fwd in (True, 'cancel') and nf[-1:] == of[-1:] and len(nf) < len(of) and all(f in of for f in nf)   # the hold as one touch-down + the tap dead zone
                check(same_ka and (raw or of == nf or compact),
                      f'{name}: same as the old binary ({"event for event" if raw else "same contacts per frame"}, {len(r["touch"])} touch events)')
            if '-k' not in sys.argv:
                subprocess.call(['rm', '-rf', r['dir']])
    stuck_cases(new)
    pressure_cases(new)
    early_release_cases(new)
    held_compact_cases(new)
    boost_scroll_cases(new)
    thirds_cases(new)
    print('FAILED: %d' % fails if fails else 'all passed')
    sys.exit(1 if fails else 0)


main()
