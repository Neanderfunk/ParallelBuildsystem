#!/usr/bin/env python3
"""Evaluate build.sh parallel runs from their buildinfo/ files.

Usage: auswerten.py RUNDIR [RUNDIR ...]
RUNDIR holds <id>.build-times.csv and <id>.metrics.csv[.gz] of one run.
"""
import csv, glob, gzip, os, statistics as st, sys


def load_times(d):
    f = sorted(glob.glob(os.path.join(d, '*.build-times.csv')))[-1]
    rows = list(csv.DictReader(open(f)))
    return os.path.basename(f).split('.')[0], rows


def load_metrics(d, rid):
    for f in (os.path.join(d, rid + '.metrics.csv.gz'), os.path.join(d, rid + '.metrics.csv')):
        if os.path.exists(f):
            op = gzip.open if f.endswith('.gz') else open
            with op(f, 'rt') as fh:
                return list(csv.DictReader(fh))
    return []


def q(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else float('nan')


def analyse(d):
    rid, rows = load_times(d)
    start = next(r for r in rows if r['phase'] == 'run_start')
    t0 = int(start['epoch'])
    prep = next((r for r in rows if r['phase'] == 'prepare'), None)
    t_prep_end = int(prep['epoch']) if prep else t0
    builds = [r for r in rows if r['phase'] == 'build']
    fin = [r for r in rows if r['phase'] == 'finalize']
    for r in builds:
        r['end'] = int(r['epoch']); r['sec'] = int(r['seconds']); r['beg'] = r['end'] - r['sec']
    domains = []
    for r in builds:
        if r['site_code'] not in domains:
            domains.append(r['site_code'])
    first = domains[0]
    # golden = steps of the first domain that ran before any other domain's step
    other_beg = min((r['beg'] for r in builds if r['site_code'] != first), default=None)
    golden = [r for r in builds if r['site_code'] == first and (other_beg is None or r['end'] <= other_beg + 5)]
    par = [r for r in builds if r not in golden]
    g_end = max(r['end'] for r in golden) if golden else t_prep_end
    p_beg = min(r['beg'] for r in par) if par else None
    p_end = max(r['end'] for r in par) if par else None
    end = max([int(r['epoch']) for r in fin] + [p_end or 0, g_end])
    out = {'run': rid, 'note': start['note']}
    out['total_min'] = (end - t0) / 60
    out['prepare_min'] = int(prep['seconds']) / 60 if prep else 0
    out['golden_min'] = (g_end - t_prep_end) / 60
    out['golden_steps'] = len(golden)
    out['golden_step_mean_s'] = st.mean(r['sec'] for r in golden) if golden else 0
    if par:
        wall = p_end - p_beg
        out['par_wall_min'] = wall / 60
        out['par_steps'] = len(par)
        out['par_step_mean_s'] = st.mean(r['sec'] for r in par)
        out['erlang'] = sum(r['sec'] for r in par) / wall
        # per target: first begin, last end in parallel phase
        tg = {}
        for r in par:
            a = tg.setdefault(r['target'], [r['beg'], r['end'], 0, []])
            a[0] = min(a[0], r['beg']); a[1] = max(a[1], r['end']); a[2] += 1; a[3].append(r['sec'])
        out['targets'] = {t: ((v[0] - p_beg) / 60, (v[1] - p_beg) / 60, v[2], st.mean(v[3])) for t, v in sorted(tg.items(), key=lambda kv: kv[1][0])}
        # concurrency profile: minutes with k workers busy
        prof = {}
        for s in range(p_beg, p_end, 10):
            k = sum(1 for r in par if r['beg'] <= s < r['end'])
            prof[k] = prof.get(k, 0) + 10
        out['concurrency_min'] = {k: v / 60 for k, v in sorted(prof.items())}
        out['per_domain_min'] = wall / 60 / (len(domains) - 1) if len(domains) > 1 else 0
    out['finalize_min'] = sum(int(r['seconds']) for r in fin) / 60
    m = load_metrics(d, rid)
    if m:
        def col(name, cond=None):
            return [float(x[name]) for x in m if x.get(name) not in (None, '', '?') and (cond is None or cond(x))]
        for ph in ('prepare', 'golden', 'build'):
            c = lambda x, ph=ph: x.get(ph) not in (None, '', '0')
            a = col('aktiv', c)
            if a:
                out['m_' + ph] = {
                    'n': len(a), 'cores_mean': st.mean(a), 'cores_p50': q(a, .5), 'cores_p95': q(a, .95),
                    'iowait_mean': st.mean(col('iowait', c) or [0]),
                    'util_mean': st.mean(col('util', c) or [0]), 'util_p95': q(col('util', c), .95),
                    'write_p95': q(col('schreib_mb', c), .95), 'write_max': max(col('schreib_mb', c) or [0]),
                    'psi_cpu': st.mean(col('psi_cpu', c) or [float('nan')]) if col('psi_cpu', c) else None,
                    'psi_io': st.mean(col('psi_io', c)) if col('psi_io', c) else None,
                    'steal': st.mean(col('steal', c) or [0]),
                }
    return out


def show(o):
    print(f"== {o['run']}  {o['note']}")
    print(f"   total {o['total_min']:.0f} min: prepare {o['prepare_min']:.0f}, golden {o['golden_min']:.0f} "
          f"({o['golden_steps']} steps, mean {o['golden_step_mean_s']:.0f} s), finalize {o['finalize_min']:.1f}")
    if 'par_wall_min' in o:
        print(f"   parallel phase {o['par_wall_min']:.0f} min, {o['par_steps']} steps, mean step {o['par_step_mean_s']:.0f} s, "
              f"{o['erlang']:.2f} Erl, {o['per_domain_min']:.1f} min per follow-up domain")
        print('   concurrency (workers busy: minutes): ' + ', '.join(f"{k}: {v:.1f}" for k, v in o['concurrency_min'].items()))
        for t, (b, e, n, mean) in o['targets'].items():
            print(f"     {t:18s} {b:5.1f} -> {e:5.1f} min  {n} steps, mean {mean:.0f} s")
    for ph in ('prepare', 'golden', 'build'):
        k = 'm_' + ph
        if k in o:
            v = o[k]
            psi = f", PSI cpu {v['psi_cpu']:.1f} io {v['psi_io']:.1f}" if v['psi_cpu'] is not None else ''
            print(f"   {ph:8s} n={v['n']:5d} cores mean {v['cores_mean']:.1f} p50 {v['cores_p50']:.1f} p95 {v['cores_p95']:.1f}, "
                  f"iowait {v['iowait_mean']:.2f}, disk util {v['util_mean']:.1f}/p95 {v['util_p95']:.0f} %, "
                  f"write p95 {v['write_p95']:.0f} max {v['write_max']:.0f} MB/s, steal {v['steal']:.2f}{psi}")


if __name__ == '__main__':
    for d in sys.argv[1:]:
        show(analyse(d))
        print()
