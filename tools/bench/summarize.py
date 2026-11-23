#!/usr/bin/env python3
"""Summarise vdbench.sh output: medians per metric -> <raw>.csv / <raw>.json, plus a host-log timeline (median time of
each host log line since the start of the sample) for boot / ret / thaw.

  summarize.py results/<label>.raw.txt [more.raw.txt ...]     writes results/<label>.csv and .json next to each raw file
  summarize.py --compare A.raw.txt B.raw.txt                   before / after table (median, delta, %)
"""
import json, re, statistics as st, sys, collections, os

def parse(path):
    info, samples, logs = {}, collections.defaultdict(list), collections.defaultdict(lambda: collections.defaultdict(list))
    for line in open(path, errors='replace'):
        p = line.rstrip('\n').split(' ', 3)
        if p[0] == 'I' and len(p) >= 2:
            info[p[1]] = line.rstrip('\n').split(' ', 2)[2] if len(p) > 2 else ''
        elif p[0] == 'M' and len(p) >= 4:
            try: samples[p[1]].append(float(p[3]))
            except ValueError: pass
        elif p[0] == 'L' and len(p) >= 4:
            q = line.rstrip('\n').split(' ', 4)
            if len(q) < 5: continue
            phase, run, ms, txt = q[1], q[2], q[3], q[4]
            key = re.sub(r'\d+', '#', txt)[:90]
            d = logs[phase][key]
            if not any(r == run for r, _ in d):
                try: d.append((run, int(ms.lstrip('+'))))
                except ValueError: pass
    return info, samples, logs

def stats(v):
    v = sorted(v)
    q = lambda f: v[min(len(v) - 1, int(round(f * (len(v) - 1))))]
    return {'n': len(v), 'median': st.median(v), 'min': v[0], 'max': v[-1], 'p25': q(.25), 'p75': q(.75)}

def summarise(path):
    info, samples, logs = parse(path)
    base = path[:-8] if path.endswith('.raw.txt') else path
    rows = {k: stats(v) for k, v in sorted(samples.items()) if v}
    timeline = {}
    for ph, d in logs.items():
        timeline[ph] = sorted(((st.median([ms for _, ms in v]), len(v), k) for k, v in d.items()), key=lambda x: x[0])
    with open(base + '.csv', 'w') as f:
        f.write('label,metric,n,median,min,p25,p75,max\n')
        for k, s in rows.items():
            f.write('%s,%s,%d,%g,%g,%g,%g,%g\n' % (info.get('label', ''), k, s['n'], s['median'], s['min'], s['p25'], s['p75'], s['max']))
    json.dump({'info': info, 'metrics': rows,
               'timeline': {ph: [{'median_ms': m, 'runs': n, 'line': k} for m, n, k in t] for ph, t in timeline.items()}},
              open(base + '.json', 'w'), ensure_ascii=False, indent=1)
    print('== %s  %s' % (info.get('label', path), ' '.join('%s=%s' % (k, info[k]) for k in ('version', 'model', 'firmware', 'memtotal_kb') if k in info)))
    for k, s in rows.items():
        print('  %-38s n=%-3d med=%9.0f  min=%9.0f  max=%9.0f' % (k, s['n'], s['median'], s['min'], s['max']))
    if os.environ.get('TIMELINE', '1') == '1':
        for ph, t in timeline.items():
            print('  -- %s host log timeline (median ms since start)' % ph)
            prev = 0
            for m, n, k in t:
                print('    +%7.0f (%+6.0f) x%d  %s' % (m, m - prev, n, k)); prev = m
    return rows

def compare(a, b):
    ra, rb = parse(a)[1], parse(b)[1]
    print('%-38s %10s %10s %9s %7s' % ('metric', 'before', 'after', 'delta', '%'))
    for k in sorted(set(ra) | set(rb)):
        if not ra.get(k) or not rb.get(k): continue
        x, y = st.median(ra[k]), st.median(rb[k])
        print('%-38s %10.0f %10.0f %+9.0f %+6.1f%%' % (k, x, y, y - x, (y - x) * 100 / x if x else 0))

if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--compare':
        compare(sys.argv[2], sys.argv[3])
    else:
        for p in sys.argv[1:]: summarise(p)
