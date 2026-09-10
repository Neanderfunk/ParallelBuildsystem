#!/usr/bin/env python3
"""Misst CPU- und Plattenlast waehrend eines Gluon-Builds.

  python3 buildlast.py <pfad-im-buildbaum> [dauer] [schwelle]

Wartet, bis mindestens <schwelle> Kerne aktiv sind (Standard 2), misst dann
<dauer> Sekunden (Standard 900) und fasst zusammen. Strg-C beendet frueher,
die Zusammenfassung kommt trotzdem. Braucht nur python3 und /proc.

Die Wartephase hat einen Grund: die prepare-Phase eines Gluon-Laufs
(make update, feeds) laeuft mit gut einem Kern und wuerde den Schnitt
verfaelschen. Gemessen werden soll die Bauphase.
"""
import os, sys, time, subprocess, re

pfad     = sys.argv[1] if len(sys.argv) > 1 else "."
dauer    = float(sys.argv[2]) if len(sys.argv) > 2 else 900.0
schwelle = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
INTERVALL, KERNE = 1.0, os.cpu_count()

def blockgeraet(p):
    """Blockgeraet zu einem Pfad, Partitionen auf die Platte reduziert.

    io_ticks - die Grundlage fuer %util - fuehrt der Kernel nur auf dem
    Basisgeraet zuverlaessig, auf vda1 stuende dort womoeglich 0.
    vda1 -> vda, nvme0n1p2 -> nvme0n1, waehrend nvme0n1 und dm-3 bleiben.
    """
    try:
        q = subprocess.run(["findmnt", "-no", "SOURCE", "--target", p],
                           capture_output=True, text=True).stdout.strip()
    except FileNotFoundError:
        q = ""
    name = os.path.basename(q) if q else ""
    bekannt = set()
    with open("/proc/diskstats") as f:
        for z in f:
            bekannt.add(z.split()[2])
    for k in (re.sub(r'p\d+$', '', name), name.rstrip('0123456789')):
        if k and k != name and k in bekannt:
            return k
    return name if name in bekannt else None

DEV = blockgeraet(pfad)
if not DEV:
    print("Kein Blockgeraet fuer %s gefunden - bitte melden, dann fehlen die "
          "Plattenzahlen." % pfad)

def cpu():
    with open("/proc/stat") as f:
        return [int(x) for x in f.readline().split()[1:]]

def disk():
    if not DEV:
        return None
    with open("/proc/diskstats") as f:
        for z in f:
            t = z.split()
            if t[2] == DEV:
                return (int(t[3]), int(t[5]), int(t[7]), int(t[9]), int(t[12]))
    return None

def probe(c0, d0, t0):
    c1, d1, t1 = cpu(), disk(), time.time()
    dt = t1 - t0
    dc = [a - b for a, b in zip(c1, c0)]
    ges = sum(dc)
    if ges <= 0:
        return None, c1, d1, t1
    aktiv = (1 - dc[3] / ges) * KERNE
    iow   = (dc[4] / ges) * KERNE
    if d1 and d0:
        lese    = (d1[1] - d0[1]) * 512 / 1048576 / dt
        schreib = (d1[3] - d0[3]) * 512 / 1048576 / dt
        iops    = ((d1[0] - d0[0]) + (d1[2] - d0[2])) / dt
        util    = min(100.0, (d1[4] - d0[4]) / (dt * 1000) * 100)
    else:
        lese = schreib = iops = util = 0.0
    return (aktiv, iow, lese, schreib, iops, util), c1, d1, t1

print("Geraet %s, %d Kerne. Warte auf Last (>%.1f aktive Kerne) ..."
      % (DEV or "-", KERNE, schwelle))
c0, d0, t0 = cpu(), disk(), time.time()
try:
    while True:
        time.sleep(INTERVALL)
        pr, c0, d0, t0 = probe(c0, d0, t0)
        if pr and pr[0] >= schwelle:
            print("Last erkannt (%.1f Kerne aktiv), messe %.0f s ..." % (pr[0], dauer))
            break
except KeyboardInterrupt:
    print("Abgebrochen, ohne Last keine Messung.")
    sys.exit(1)

proben, ende = [], time.time() + dauer
try:
    while time.time() < ende:
        time.sleep(INTERVALL)
        pr, c0, d0, t0 = probe(c0, d0, t0)
        if pr:
            proben.append(pr)
except KeyboardInterrupt:
    pass

if not proben:
    print("Keine Proben gesammelt.")
    sys.exit(1)

def q(w, x):
    s = sorted(w)
    return s[min(len(s) - 1, int(len(s) * x))]
def mit(w):
    return sum(w) / len(w)

sp = list(zip(*proben))
namen = ["aktive Kerne", "davon iowait", "Lesen MB/s", "Schreiben MB/s",
         "IOPS", "Platte %util"]
print("\n" + "=" * 62)
print("BUILDLAST  %d Proben = %.0f s   Kerne=%d  Geraet=%s"
      % (len(proben), len(proben) * INTERVALL, KERNE, DEV or "-"))
print("=" * 62)
print("%-16s %9s %9s %9s %9s" % ("", "Mittel", "Median", "p95", "Max"))
for i, n in enumerate(namen):
    print("%-16s %9.1f %9.1f %9.1f %9.1f"
          % (n, mit(sp[i]), q(sp[i], 0.5), q(sp[i], 0.95), max(sp[i])))
ak = sp[0]
print("-" * 62)
print("CPU-Auslastung          %5.1f %%   (%.1f von %d Kernen)"
      % (mit(ak) / KERNE * 100, mit(ak), KERNE))
print("Zeit unter 4 Kernen     %5.1f %%" % (sum(1 for a in ak if a < 4) / len(ak) * 100))
print("Zeit unter 8 Kernen     %5.1f %%" % (sum(1 for a in ak if a < 8) / len(ak) * 100))
u = mit(sp[5])
if DEV and u > 0.5:
    print("Platte im Mittel        %5.1f %% ausgelastet -> rechnerisch Platz fuer "
          "%.1f solcher Lasten" % (u, 100.0 / u))
elif DEV:
    print("Platte praktisch unbelastet (%.2f %%) - I/O ist nicht der Engpass." % u)
print("=" * 62)
