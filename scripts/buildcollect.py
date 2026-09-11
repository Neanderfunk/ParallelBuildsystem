#!/usr/bin/env python3
"""buildcollect.py - Metriken eines build.sh-Laufs, fuer den naechsten.

  buildcollect.py <status-dir> <csv> <empfehlung> <pfad-im-baum> <workers> <lauf-id> [<targets>]

Wird von build.sh im Hintergrund gestartet und mit SIGTERM beendet. Sampelt
jede Sekunde CPU- und Plattenlast und versieht jede Probe mit den Phasen, die
die Prozesse des Laufs gerade in <status-dir> melden (siehe status_set in
build.sh). Bei SIGTERM wertet es aus und schreibt eine Empfehlung fuer die
Worker-Zahl des NAECHSTEN Laufs - "Feintuning mit einem Lauf Versatz".

Warum die Phasen: Systemlast allein laesst sich nicht deuten. Die erste
Lastmessung auf wir-horst traf die untaetige prepare-Phase statt eines
Imagebaus; aufgefallen ist das nur an einem Detail.

Warum nur Proben, bei denen ALLE Worker belegt sind: beim Hochfahren starten die Worker
versetzt, am Ende laeuft die Warteschlange leer. In beiden Phasen ist die
Auslastung niedrig, weil Worker fehlen - nicht weil Luft waere. Ueber den ganzen
Lauf gemittelt empfaehle der Collector jedes Mal mehr Worker und schaukelte
sich auf. Ausgewertet wird deshalb nur, wenn genau <workers> Prozesse in
"build" stecken und keiner in "golden" oder "prepare".

Nebenbei der Worker-Verkehr in Erlang (nach A. K. Erlang, Telefonvermittlung):
die mittlere Zahl gleichzeitig belegter Worker ueber die Parallelphase, also
ueber alle Proben mit mindestens einem Worker im Imagebau und niemandem in
golden/prepare. 6 Worker, im Mittel 4,6 belegt = 4,6 Erl. Die Luecke zur
Worker-Zahl ist Hochfahren (Startversatz) und Auslaufen der Warteschlange.

Steal time (Spalte "steal", Kerne): Zeit, in der der Hypervisor die vCPUs
des Gastes anderen Lasten gegeben hat. Der Gast sieht diese Lasten sonst
nicht - auf wir-horst (KVM-Gast) eine Quelle fuer Streuung zwischen Laeufen.
"aktiv" enthaelt steal weiterhin (wie iowait), die Werte bleiben mit
frueheren Laeufen vergleichbar; steal wird nur ausgewiesen, nicht in die
Empfehlung eingerechnet.

Wartende Prozesse und Druck (Spalten running, blocked, psi_*): Die Last auf
wir-horst lag bei 22 % CPU trotzdem bei 48 - Prozesse, die im Kernel warten
(Zustand D), belegen keine CPU und zeigen sich im iowait-Mittel kaum.
procs_running/procs_blocked aus /proc/stat sind die Momentwerte dazu, PSI
(/proc/pressure/{cpu,io,memory}) sagt, welcher Anteil der Zeit durch Warten
auf CPU, I/O oder Speicher verloren ging: "some" = mindestens ein Prozess
wartete, "full" = alle nicht ruhenden. Ausgewertet werden die total-Zaehler
(Mikrosekunden) zwischen zwei Proben, nicht die gleitenden avg10. Hoher
psi_cpu spricht fuer Ueberbelegung (zu viele make-Jobs), hoher psi_io und
viele blocked fuer einen I/O-Stau (overlayfs copy-up, Writeback). Wie steal
nur ausgewiesen, noch nicht in der Empfehlung - erst braucht es Laeufe, an
denen sich Schwellen festmachen lassen. Ohne PSI im Kernel bleiben die
psi-Spalten leer.

Die Empfehlung ist gedaempft und begrenzt: hoechstens ein Worker mehr oder
weniger je Lauf, nie unter 1, nie ueber die halbe Kernzahl. Ein Regler, der
auf einem einzigen Lauf um mehrere Stufen springt, schwingt sich auf.

Warum die Zahl der Targets: Ein Worker baut ein Target ueber alle Domains.
Gleichzeitig laufen also hoechstens min(<workers>, <targets>) - die
"wirksamen" Worker. Nur mit ihnen ist "alle belegt" erreichbar, auf sie
bezieht sich die Empfehlung. Liegt sie ueber der Target-Zahl, sagt die
Begruendung das: Wirkung erst in einem Lauf mit mehr Targets (Volllauf). Eine
Empfehlung ueber der wirksamen Zahl wird nicht weiter hochgezaehlt, solange
kein Lauf sie belegen konnte.
"""
import os, re, signal, statistics, subprocess, sys, time

# --- Schwellen der Empfehlung. Heuristik, aus den Messungen vom 10.09.2026
# abgeleitet; die Begruendung steht mit in der Empfehlungsdatei, damit sie sich
# pruefen laesst.
IOWAIT_ZU_HOCH = 1.0   # Kerne im Mittel, die auf IO warten: Platte ist Engpass
UTIL_ZU_HOCH   = 50.0  # % mittlere Plattenauslastung: dito
CPU_LUFT       = 0.65  # unter 65 % CPU-Auslastung ist Platz fuer einen mehr
MIN_PROBEN     = 300   # unter 5 Minuten mit allen Workern belegt: zu duenn
INTERVALL      = 1.0

status_dir, out_csv, emp_file, pfad, workers, lauf_id = sys.argv[1:7]
workers = int(workers)
targets = int(sys.argv[7]) if len(sys.argv) > 7 else 0   # 0: unbekannt
wirksam = max(1, min(workers, targets)) if targets else workers
KERNE = os.cpu_count()

laufen = True
def beenden(sig, frame):
    global laufen
    laufen = False
signal.signal(signal.SIGTERM, beenden)
signal.signal(signal.SIGINT, beenden)

def blockgeraet(p):
    """Partition auf die Platte reduziert: io_ticks, die Grundlage fuer
    %util, fuehrt der Kernel nur dort zuverlaessig."""
    try:
        q = subprocess.run(["findmnt", "-no", "SOURCE", "--target", p],
                           capture_output=True, text=True).stdout.strip()
    except FileNotFoundError:
        q = ""
    name = os.path.basename(q) if q else ""
    with open("/proc/diskstats") as f:
        bekannt = {z.split()[2] for z in f}
    for k in (re.sub(r'p\d+$', '', name), name.rstrip('0123456789')):
        if k and k != name and k in bekannt:
            return k
    return name if name in bekannt else None

DEV = blockgeraet(pfad)

def cpu():
    """Summenzeile aus /proc/stat: user nice system idle iowait irq softirq
    steal guest guest_nice. guest ist in user schon enthalten - nur die ersten
    acht Felder zaehlen, sonst stuende Gastzeit doppelt in der Summe."""
    with open("/proc/stat") as f:
        return [int(x) for x in f.readline().split()[1:9]]

def procs():
    """Momentwerte aus /proc/stat: laufende und im Kernel wartende Prozesse."""
    r = b = 0
    with open("/proc/stat") as f:
        for z in f:
            if z.startswith("procs_running "):
                r = int(z.split()[1])
            elif z.startswith("procs_blocked "):
                b = int(z.split()[1])
    return r, b

def psi():
    """total-Zaehler (us) aus /proc/pressure, je Ressource und Art.
    None fuer eine Ressource, die der Kernel nicht meldet."""
    r = {}
    for name in ("cpu", "io", "memory"):
        try:
            with open("/proc/pressure/" + name) as f:
                r[name] = {z.split()[0]: int(z.rsplit("total=", 1)[1]) for z in f if "total=" in z}
        except (OSError, ValueError):
            r[name] = None
    return r

def psi_anteil(a, b, name, art, dt):
    """Prozent der Zeit zwischen zwei psi()-Proben, None wenn unbekannt."""
    if not a.get(name) or not b.get(name) or art not in a[name] or art not in b[name]:
        return None
    return max(0.0, min(100.0, (b[name][art] - a[name][art]) / (dt * 1e6) * 100))

def disk():
    if not DEV:
        return None
    with open("/proc/diskstats") as f:
        for z in f:
            t = z.split()
            if t[2] == DEV:
                return (int(t[3]), int(t[7]), int(t[9]), int(t[12]))
    return None

def phasen():
    """Zaehlt, wie viele Prozesse gerade in welcher Phase stecken."""
    n = {"prepare": 0, "golden": 0, "build": 0, "finalize": 0}
    try:
        for name in os.listdir(status_dir):
            if name.endswith(".tmp"):
                continue
            try:
                with open(os.path.join(status_dir, name)) as f:
                    for z in f:
                        if z.startswith("phase="):
                            ph = z.strip().split("=", 1)[1]
                            if ph in n:
                                n[ph] += 1
            except OSError:
                pass   # gerade abgemeldet
    except FileNotFoundError:
        pass
    return n

proben = []
c0, d0, t0, s0 = cpu(), disk(), time.time(), psi()
with open(out_csv, "w") as csv:
    csv.write("epoch,aktiv,iowait,util,schreib_mb,iops,prepare,golden,build,finalize,steal,"
              "running,blocked,psi_cpu,psi_io,psi_io_full,psi_mem\n")
    while laufen:
        time.sleep(INTERVALL)
        c1, d1, t1, s1 = cpu(), disk(), time.time(), psi()
        dt = t1 - t0
        dc = [a - b for a, b in zip(c1, c0)]
        ges = sum(dc)
        if ges <= 0:
            c0, d0, t0, s0 = c1, d1, t1, s1
            continue
        aktiv = (1 - dc[3] / ges) * KERNE
        iow = (dc[4] / ges) * KERNE
        steal = (dc[7] / ges) * KERNE if len(dc) > 7 else 0.0
        if d1 and d0:
            iops = ((d1[0] - d0[0]) + (d1[1] - d0[1])) / dt
            schreib = (d1[2] - d0[2]) * 512 / 1048576 / dt
            util = min(100.0, (d1[3] - d0[3]) / (dt * 1000) * 100)
        else:
            iops = schreib = util = 0.0
        n = phasen()
        running, blocked = procs()
        x = {"running": running, "blocked": blocked,
             "psi_cpu": psi_anteil(s0, s1, "cpu", "some", dt),
             "psi_io": psi_anteil(s0, s1, "io", "some", dt),
             "psi_io_full": psi_anteil(s0, s1, "io", "full", dt),
             "psi_mem": psi_anteil(s0, s1, "memory", "some", dt)}
        proben.append((aktiv, iow, util, n, steal, x))
        fmt = lambda v: "" if v is None else "%.1f" % v
        csv.write("%.1f,%.2f,%.2f,%.1f,%.1f,%.0f,%d,%d,%d,%d,%.2f,%d,%d,%s,%s,%s,%s\n" % (
            t1, aktiv, iow, util, schreib, iops,
            n["prepare"], n["golden"], n["build"], n["finalize"], steal,
            running, blocked, fmt(x["psi_cpu"]), fmt(x["psi_io"]),
            fmt(x["psi_io_full"]), fmt(x["psi_mem"])))
        csv.flush()
        c0, d0, t0, s0 = c1, d1, t1, s1

# --- Auswertung -------------------------------------------------------------
voll = [p for p in proben
        if p[3]["build"] == wirksam and p[3]["golden"] == 0 and p[3]["prepare"] == 0]

# Erlang: mittlere Zahl belegter Worker ueber die Parallelphase
parallel = [p[3]["build"] for p in proben
            if p[3]["build"] > 0 and p[3]["golden"] == 0 and p[3]["prepare"] == 0]
erlang = statistics.mean(parallel) if parallel else 0.0

# Steal time ueber die Parallelphase (dieselben Proben wie Erlang)
steal_par = [p[4] for p in proben
             if p[3]["build"] > 0 and p[3]["golden"] == 0 and p[3]["prepare"] == 0]
steal_mittel = statistics.mean(steal_par) if steal_par else 0.0
steal_max = max(steal_par) if steal_par else 0.0

# Warten und Druck ueber die Parallelphase (dieselben Proben wie Erlang)
par_proben = [p for p in proben
              if p[3]["build"] > 0 and p[3]["golden"] == 0 and p[3]["prepare"] == 0]
def mittel(werte):
    w = [v for v in werte if v is not None]
    return statistics.mean(w) if w else None
druck = {k: mittel(p[5][k] for p in par_proben)
         for k in ("running", "blocked", "psi_cpu", "psi_io", "psi_io_full", "psi_mem")}
blocked_max = max((p[5]["blocked"] for p in par_proben), default=0)

def p95(w):
    s = sorted(w)
    return s[min(len(s) - 1, int(len(s) * 0.95))]

obergrenze = max(1, KERNE // 2)
if len(voll) < MIN_PROBEN:
    empfohlen = workers
    grund = ("zu wenig Proben mit allen Workern belegt (%d, mindestens %d) - "
             "Empfehlung unveraendert" % (len(voll), MIN_PROBEN))
    werte = {}
else:
    A = statistics.mean(p[0] for p in voll) / KERNE
    I = statistics.mean(p[1] for p in voll)
    M = statistics.mean(p[2] for p in voll)
    U = p95([p[2] for p in voll])
    werte = {"cpu_auslastung": "%.2f" % A, "iowait_kerne": "%.2f" % I,
             "platte_util_mittel": "%.1f" % M, "platte_util_p95": "%.1f" % U,
             "steal_kerne_alle_belegt": "%.2f" % statistics.mean(p[4] for p in voll)}
    for k in ("blocked", "psi_cpu", "psi_io", "psi_io_full", "psi_mem"):
        v = mittel(p[5][k] for p in voll)
        if v is not None:
            werte[k + "_alle_belegt"] = "%.1f" % v
    if I > IOWAIT_ZU_HOCH or M > UTIL_ZU_HOCH:
        empfohlen = wirksam - 1
        grund = ("die Platte ist der Engpass (iowait %.2f Kerne, Platte im Mittel "
                 "%.0f %%) - ein Worker weniger" % (I, M))
    elif A < CPU_LUFT:
        # Von den wirksamen aus, aber eine hoehere Konfiguration nicht senken:
        # sie kann fuer Laeufe mit mehr Targets gedacht sein.
        empfohlen = max(workers, wirksam + 1)
        grund = ("CPU mit allen Workern belegt nur %.0f %% ausgelastet, iowait %.2f "
                 "Kerne, Platte %.0f %% - es ist Luft, ein Worker mehr" % (A * 100, I, M))
    else:
        empfohlen = workers
        grund = ("CPU %.0f %% ausgelastet, iowait %.2f Kerne, Platte %.0f %% - "
                 "gut ausgelastet, unveraendert" % (A * 100, I, M))

geklemmt = max(1, min(obergrenze, empfohlen))
if geklemmt != empfohlen:
    grund += " (begrenzt auf %d bis %d)" % (1, obergrenze)
if targets and geklemmt > targets:
    grund += (" - wirkt erst in Laeufen mit mehr als %d Targets, hier baut jeder "
              "Worker ein Target" % targets)

with open(emp_file + ".tmp", "w") as f:
    f.write("# Empfehlung aus Lauf %s, %s\n" % (lauf_id, time.strftime("%Y-%m-%d %H:%M")))
    f.write("# Gelesen von build.sh bei WORKERS=auto; sonst nur zur Kenntnis.\n")
    f.write("empfohlen=%d\n" % geklemmt)
    f.write("beobachtet_workers=%d\n" % workers)
    f.write("targets=%d\n" % targets)
    f.write("wirksame_workers=%d\n" % wirksam)
    f.write("kerne=%d\n" % KERNE)
    f.write("proben=%d\n" % len(proben))
    f.write("proben_alle_belegt=%d\n" % len(voll))
    f.write("worker_erlang=%.2f\n" % erlang)
    f.write("worker_erlang_proben=%d\n" % len(parallel))
    f.write("steal_kerne_mittel=%.2f\n" % steal_mittel)
    f.write("steal_kerne_max=%.2f\n" % steal_max)
    for k, v in druck.items():
        f.write("%s_mittel=%s\n" % (k, "" if v is None else "%.1f" % v))
    f.write("blocked_max=%d\n" % blocked_max)
    for k, v in werte.items():
        f.write("%s=%s\n" % (k, v))
    f.write("begruendung=%s\n" % grund)
os.replace(emp_file + ".tmp", emp_file)
pz = lambda v: "?" if v is None else "%.0f%%" % v
print("buildcollect: %d Proben, %d mit allen %d Workern belegt%s, Parallelphase %.1f Erl, "
      "steal %.2f Kerne (max %.1f), PSI cpu %s io %s/%s mem %s, blockiert %s (max %d) "
      "-> empfohlen %d (%s)" % (
          len(proben), len(voll), wirksam,
          " (%d konfiguriert, %d Targets)" % (workers, targets) if wirksam < workers else "",
          erlang, steal_mittel, steal_max,
          pz(druck["psi_cpu"]), pz(druck["psi_io"]), pz(druck["psi_io_full"]), pz(druck["psi_mem"]),
          "?" if druck["blocked"] is None else "%.1f" % druck["blocked"], blocked_max,
          geklemmt, grund))
