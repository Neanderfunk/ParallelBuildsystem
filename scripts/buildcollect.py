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

Schreiblast je Worker (Dateien <lauf>.io.csv und <lauf>.io-top.csv neben der
CSV): Die Platte allein sagt nicht, wer schreibt. In 26111822bro schrieb
wir-horst zweimal je eine halbe Stunde 150-160 MB/s bei 6-16 aktiven Kernen,
waehrend die ersten Key-Schritte liefen - zuordnen liess sich das nicht.
Jetzt wird jede Sekunde /proc/<pid>/io aller eigenen Prozesse gelesen und
ueber die Session summiert: jeder Worker ist per setsid eine eigene Session,
seine Statusdatei nennt die PID. Die Summe ist vollstaendig, auch fuer
kurzlebige Prozesse (cp, ld, tar): der Kernel rechnet die Zaehler eines
beendeten Kindes beim wait() dem Elternprozess zu (wait_task_zombie), sie
stecken danach in dessen /proc/<pid>/io. Geprueft am 19.11.2026: dd im
inneren sh erscheint nach dessen Ende beim aeusseren, auch ueber einen
User-Namespace hinweg. Verloren geht nur, was an init uebergeht.
read_bytes/write_bytes zaehlen, was zur Platte geht (Schreiben schon beim
Verschmutzen der Seite, also dem Verursacher), cancelled_write_bytes, was vor
dem Rueckschreiben geloescht wurde (rm -rf auf frisch Geschriebenes).
io.csv: je Sekunde und Worker MB/s. io-top.csv: alle IO_TOP_S Sekunden die
IO_TOP_N staerksten Prozessnamen je Worker. Dort landet, was ein Kind vor
seinem Ende zuletzt schrieb, beim Elternprozess (meist make oder sh); der
Rest zaehlt beim Kind selbst. Dazu Dirty und Writeback aus /proc/meminfo in
der Haupt-CSV: haelt der Kernel viel ungeschriebenes zurueck, faellt die
Plattenlast spaeter an, als die Prozesse sie verursachen.

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
IO_TOP_S       = 10    # Fenster fuer io-top.csv
IO_TOP_N       = 5     # Prozessnamen je Worker und Fenster
MB             = 1048576.0

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
    """Zaehlt, wie viele Prozesse gerade in welcher Phase stecken. Dazu die
    Statusdateien selbst: Name (Worker-Target oder main) -> Felder."""
    n = {"prepare": 0, "golden": 0, "build": 0, "finalize": 0, "download": 0}
    st = {}
    try:
        for name in os.listdir(status_dir):
            if name.endswith(".tmp"):
                continue
            try:
                with open(os.path.join(status_dir, name)) as f:
                    felder = dict(z.rstrip("\n").split("=", 1) for z in f if "=" in z)
            except OSError:
                continue   # gerade abgemeldet
            st[name] = felder
            if felder.get("phase") in n:
                n[felder["phase"]] += 1
    except FileNotFoundError:
        pass
    return n, st

def meminfo():
    """Dirty und Writeback in MB."""
    r = {"Dirty": 0.0, "Writeback": 0.0}
    try:
        with open("/proc/meminfo") as f:
            for z in f:
                k = z.split(":", 1)[0]
                if k in r:
                    r[k] = int(z.split()[1]) / 1024.0
    except OSError:
        pass
    return r

MEIN_UID = os.getuid()
EIGEN = os.getpid()

def prozesse():
    """Eigene Prozesse: pid -> (ppid, sid, comm, read_bytes, write_bytes,
    cancelled_write_bytes). Zombies mit None statt der Zaehler: ihre Werte
    gehen erst an den Elternprozess, wenn der sie abholt - bis dahin fuehrt
    IoMessung ihre letzten Werte fort."""
    r = {}
    for e in os.listdir("/proc"):
        if not e.isdigit():
            continue
        pid = int(e)
        if pid == EIGEN:
            continue
        try:
            if os.stat("/proc/" + e).st_uid != MEIN_UID:
                continue
            with open("/proc/%s/stat" % e) as f:
                st = f.read()
        except OSError:
            continue
        # comm steht in Klammern und darf selbst Klammern und Leerzeichen enthalten
        a, b = st.find("("), st.rfind(")")
        rest = st[b + 2:].split()
        if a < 0 or b < 0 or len(rest) < 4:
            continue
        if rest[0] == "Z":
            r[pid] = None
            continue
        try:
            with open("/proc/%s/io" % e) as f:
                io = dict(z.split(": ", 1) for z in f.read().splitlines() if ": " in z)
        except (OSError, ValueError):
            continue
        try:
            r[pid] = (int(rest[1]), int(rest[3]), st[a + 1:b],
                      int(io["read_bytes"]), int(io["write_bytes"]),
                      int(io["cancelled_write_bytes"]))
        except (KeyError, ValueError):
            continue
    return r

class IoMessung:
    """Schreib- und Leselast je Worker-Session, siehe Kopf der Datei."""

    def __init__(self, io_csv, top_csv):
        self.csv = open(io_csv, "w")
        self.csv.write("epoch,worker,phase,target,domain,lesen_mb_s,schreib_mb_s,verworfen_mb_s,prozesse\n")
        self.top = open(top_csv, "w")
        self.top.write("epoch,worker,phase,target,domain,comm,schreib_mb,lesen_mb,verworfen_mb\n")
        self.sid_name = {}     # Session -> Worker-Name, bleibt nach dem Abmelden
        self.vorher = {}       # pid -> (ppid, sid, comm, r, w, c) der letzten Probe
        self.hoch = {}         # Worker -> hoechste Summe (r, w, c) bisher
        self.fenster = {}      # (worker, comm) -> [r, w, c] im laufenden Fenster
        self.fenster_start = time.time()
        self.schritt = {}      # (worker, phase, target, domain) -> [r, w, c] gesamt
        self.comm_ges = {}     # comm -> [r, w, c] gesamt
        self.zuletzt = {}      # Worker -> Statusfelder

    def probe(self, t, dt, st):
        jetzt = prozesse()
        for pid in [p_ for p_, v in jetzt.items() if v is None]:
            if pid in self.vorher:
                jetzt[pid] = self.vorher[pid]
            else:
                del jetzt[pid]   # als Zombie zum ersten Mal gesehen: Werte unbekannt
        # Session der gemeldeten PIDs -> Name; Workers sind Sessionfuehrer
        for name, felder in st.items():
            try:
                pid = int(felder.get("pid", ""))
            except ValueError:
                continue
            if pid in jetzt:
                self.sid_name[jetzt[pid][1]] = name
            self.zuletzt[name] = felder
        wer = lambda sid: self.sid_name.get(sid, "sonst")

        # Ein Prozess, der seit der letzten Probe verschwunden ist, steckt jetzt
        # beim Elternprozess. Dessen Zuwachs ist dann nicht seine eigene Last -
        # abziehen, was vom Kind schon gezaehlt war.
        # Endeten Kind und Elternprozess in derselben Sekunde, steckt das Kind
        # beim naechsten noch lebenden Vorfahren.
        geerbt = {}
        for pid, v in self.vorher.items():
            if pid in jetzt:
                continue
            ahn, schritte = v[0], 0
            while ahn not in jetzt and ahn in self.vorher and schritte < 64:
                ahn, schritte = self.vorher[ahn][0], schritte + 1
            g = geerbt.setdefault(ahn, [0, 0, 0])
            for i in range(3):
                g[i] += v[3 + i]

        summe, anzahl = {}, {}
        for pid, v in jetzt.items():
            name = wer(v[1])
            s_ = summe.setdefault(v[1], [0, 0, 0])
            for i in range(3):
                s_[i] += v[3 + i]
            anzahl[name] = anzahl.get(name, 0) + 1
            alt = self.vorher.get(pid)
            # exec behaelt die Zaehler (nur comm wechselt); eine wiederverwendete
            # PID binnen einer Sekunde ist bei pid_max 4M kein Thema
            basis = alt[3:6] if alt else (0, 0, 0)
            g = geerbt.get(pid, (0, 0, 0))
            eigen = [max(0, v[3 + i] - basis[i] - g[i]) for i in range(3)]
            # Prozessnamen nur fuer den Lauf: "sonst" sind alle anderen Prozesse
            # des Benutzers (Shell, tmux, Editor), die gehoeren nicht in die Liste
            if name != "sonst" and any(eigen):
                f = self.fenster.setdefault((name, v[2]), [0, 0, 0])
                c = self.comm_ges.setdefault(v[2], [0, 0, 0])
                for i in range(3):
                    f[i] += eigen[i]
                    c[i] += eigen[i]
        self.vorher = jetzt

        # Summen je Session, Zuwachs je Session, dann je Name zusammengefasst.
        # Faellt eine Summe (ein Prozess ging an init, ein Zombie fehlt kurz),
        # nicht neu aufsetzen: sonst zaehlte die Rueckkehr doppelt. Die erste
        # Probe einer Session setzt nur die Marke.
        zuwachs = {}
        for sid, s_ in summe.items():
            h = self.hoch.get(sid)
            self.hoch[sid] = [max(h[i], s_[i]) for i in range(3)] if h else list(s_)
            if h is None:
                continue
            z = zuwachs.setdefault(wer(sid), [0, 0, 0])
            for i in range(3):
                z[i] += max(0, s_[i] - h[i])
        for sid in [k for k in self.hoch if k not in summe]:
            del self.hoch[sid]

        for name, d in sorted(zuwachs.items()):
            felder = self.zuletzt.get(name, {})
            ph, tg, dm = felder.get("phase", "-"), felder.get("target", "-"), felder.get("domain", "-")
            k = self.schritt.setdefault((name, ph, tg, dm), [0, 0, 0])
            for i in range(3):
                k[i] += d[i]
            self.csv.write("%.1f,%s,%s,%s,%s,%.2f,%.2f,%.2f,%d\n" % (
                t, name, ph, tg, dm, d[0] / MB / dt, d[1] / MB / dt, d[2] / MB / dt, anzahl[name]))
        self.csv.flush()

        if t - self.fenster_start >= IO_TOP_S:
            je = {}
            for (name, comm), v in self.fenster.items():
                je.setdefault(name, []).append((v[1], v[0], v[2], comm))
            for name, liste in sorted(je.items()):
                felder = self.zuletzt.get(name, {})
                for w, r, c, comm in sorted(liste, reverse=True)[:IO_TOP_N]:
                    if w + r + c == 0:
                        continue
                    self.top.write("%.1f,%s,%s,%s,%s,%s,%.1f,%.1f,%.1f\n" % (
                        t, name, felder.get("phase", "-"), felder.get("target", "-"),
                        felder.get("domain", "-"), comm.replace(",", ";"),
                        w / MB, r / MB, c / MB))
            self.top.flush()
            self.fenster = {}
            self.fenster_start = t

    def bericht(self, platte_mb):
        """Zwei Zeilen fuers Collector-Log."""
        gb = lambda b: b / MB / 1024
        schritte_alle = [kv for kv in self.schritt.items() if kv[0][0] != "sonst"]
        schritte = sorted(schritte_alle, key=lambda kv: -kv[1][1])[:5]
        comms = sorted(self.comm_ges.items(), key=lambda kv: -kv[1][1])[:8]
        lauf = [sum(v[i] for _, v in schritte_alle) for i in range(3)]
        z1 = ("io: Prozesse des Laufs schrieben %.1f GB (Platte gesamt %.1f GB), lasen %.1f GB, "
              "verworfen %.1f GB; meiste Schreiblast: %s" % (
                  gb(lauf[1]), platte_mb / 1024, gb(lauf[0]), gb(lauf[2]),
                  ", ".join("%s %s/%s %.1f GB" % (k[1], k[2], k[3], gb(v[1])) for k, v in schritte)))
        z2 = "io: nach Prozessname: " + ", ".join("%s %.1f GB" % (c, gb(v[1])) for c, v in comms)
        return z1 + "\n" + z2

    def schliessen(self):
        self.csv.close()
        self.top.close()

proben = []
basis = out_csv[:-4] if out_csv.endswith(".csv") else out_csv
iom = IoMessung(basis + ".io.csv", basis + ".io-top.csv")
platte_mb = 0.0
c0, d0, t0, s0 = cpu(), disk(), time.time(), psi()
with open(out_csv, "w") as csv:
    csv.write("epoch,aktiv,iowait,util,schreib_mb,iops,prepare,golden,build,finalize,steal,"
              "running,blocked,psi_cpu,psi_io,psi_io_full,psi_mem,download,dirty_mb,writeback_mb\n")
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
        n, st = phasen()
        try:
            iom.probe(t1, dt, st)
        except Exception as e:   # die Zusatzmessung darf den Collector nicht beenden
            print("io-Messung: %s" % e, file=sys.stderr)
        mi = meminfo()
        platte_mb += schreib * dt
        running, blocked = procs()
        x = {"running": running, "blocked": blocked,
             "psi_cpu": psi_anteil(s0, s1, "cpu", "some", dt),
             "psi_io": psi_anteil(s0, s1, "io", "some", dt),
             "psi_io_full": psi_anteil(s0, s1, "io", "full", dt),
             "psi_mem": psi_anteil(s0, s1, "memory", "some", dt)}
        proben.append((aktiv, iow, util, n, steal, x))
        fmt = lambda v: "" if v is None else "%.1f" % v
        csv.write("%.1f,%.2f,%.2f,%.1f,%.1f,%.0f,%d,%d,%d,%d,%.2f,%d,%d,%s,%s,%s,%s,%d,%.0f,%.0f\n" % (
            t1, aktiv, iow, util, schreib, iops,
            n["prepare"], n["golden"], n["build"], n["finalize"], steal,
            running, blocked, fmt(x["psi_cpu"]), fmt(x["psi_io"]),
            fmt(x["psi_io_full"]), fmt(x["psi_mem"]),
            n["download"], mi["Dirty"], mi["Writeback"]))
        csv.flush()
        c0, d0, t0, s0 = c1, d1, t1, s1

iom.schliessen()

# --- Auswertung -------------------------------------------------------------
voll = [p for p in proben
        if p[3]["build"] == wirksam and p[3]["golden"] == 0 and p[3]["prepare"] == 0]

# Erlang: mittlere Zahl belegter Worker ueber die Parallelphase
# Ein Worker im Download (GOLDEN_COMPILE=false) ist belegt, auch wenn er
# kaum CPU braucht. In "alle belegt" (voll) zaehlt er dagegen nicht: diese
# Proben sollen zeigen, was die Maschine im Imagebau hergibt.
parallel = [p[3]["build"] + p[3]["download"] for p in proben
            if p[3]["build"] + p[3]["download"] > 0 and p[3]["golden"] == 0 and p[3]["prepare"] == 0]
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
        # Wellen: Ein Worker baut ein Target ueber alle Domains, T Targets auf
        # W Worker ergeben ceil(T/W) Wellen. Ein Worker mehr, der keine Welle
        # spart, verlaengert nur den Leerlauf am Ende (Lauf 3 auf wir-horst:
        # 8 Targets, 6 -> 7 Worker waeren weiter 2 Wellen gewesen, mit einem
        # Target allein in der zweiten). Also gleich die kleinste Zahl, die
        # eine Welle spart - hier ausnahmsweise mehr als +1, weil sich die
        # Wellen aus der Target-Zahl ergeben und nicht aus der Messung
        # schwingen koennen.
        if targets and wirksam < targets:
            wellen = -(-targets // wirksam)
            for w in range(wirksam + 1, targets + 1):
                if -(-targets // w) < wellen:
                    if w <= obergrenze:
                        empfohlen = max(workers, w)
                        grund = ("CPU mit allen Workern belegt nur %.0f %% ausgelastet, iowait "
                                 "%.2f Kerne, Platte %.0f %% - es ist Luft; %d Worker sparen eine "
                                 "Welle (%d Targets: %d statt %d Wellen)"
                                 % (A * 100, I, M, w, targets, -(-targets // w), wellen))
                    break
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
print(iom.bericht(platte_mb))
