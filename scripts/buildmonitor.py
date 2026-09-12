#!/usr/bin/env python3
"""buildmonitor.py - Live-Ansicht eines build.sh-Laufs, im Stil von btop.

  scripts/buildmonitor.py                  lokal, im Buildverzeichnis (Standard:
                                           das Verzeichnis ueber scripts/)
  scripts/buildmonitor.py --url URL        aus der Ferne ueber imageslive, z. B.
                                           https://imageslive.ffdus.de/images2023.2ad
  scripts/buildmonitor.py --once           ein Bild auf stdout, ohne Vollbild

Tasten: q beenden, + / - Intervall, Leertaste sofort neu zeichnen.

Nur Standardbibliothek. Liest, was build.sh ohnehin schreibt:
  images/running/.build-state        Kopf, erledigte Schritte
  images/running/.build-fingerprint  Liste der Targets und Domains
  images/running/.status/*           Phase, Target, Domain, Beginn je Prozess
  images/running/buildinfo/*.metrics.csv   Proben des Collectors (1/s)
  build-times.csv                    Schrittzeiten, auch frueherer Laeufe (lokal)
  .overlays/<target>.log             letzte Zeile je Worker (lokal)
Lokal kommen CPU, Druck, Speicher und Platte direkt aus /proc; aus der
Ferne aus dem Collector-CSV (per HTTP Range, nur das Ende).
"""
import argparse
import collections
import concurrent.futures
import math
import os
import re
import select
import shutil
import signal
import statistics
import sys
import time
import urllib.error
import urllib.request

# --------------------------------------------------------------------------
# Farben (256er-Palette) und Zeichen

GRAD = [28, 34, 40, 46, 82, 118, 154, 190, 226, 220, 214, 208, 202, 196]
C = {
    "text": 252, "dim": 242, "faint": 238, "hi": 231, "title": 231,
    "hdr": 51, "cpu": 39, "psi": 213, "disk": 208, "busy": 141,
    "wrk": 45, "mat": 118, "log": 220, "ok": 46, "warn": 214, "bad": 196,
    "run": 226, "todo": 238, "key": 81, "val": 229,
}
BRAILLE_L = (0x40, 0x04, 0x02, 0x01)   # linke Punktspalte, von unten
BRAILLE_R = (0x80, 0x20, 0x10, 0x08)   # rechte Punktspalte, von unten
SPARK = " ▁▂▃▄▅▆▇█"


def grad(f):
    f = 0.0 if f != f else max(0.0, min(1.0, f))
    return GRAD[min(len(GRAD) - 1, int(f * len(GRAD)))]


def fmt_dur(s):
    if s is None:
        return "–"
    s = int(max(0, s))
    if s >= 3600:
        return "%dh%02dm" % (s // 3600, s % 3600 // 60)
    if s >= 60:
        return "%dm%02ds" % (s // 60, s % 60)
    return "%ds" % s


def nice_ceil(v):
    """Naechster Skalenwert aus 1, 2, 5 x 10^k, mindestens v."""
    if v <= 0:
        return 1.0
    e = 10 ** math.floor(math.log10(v))
    for m in (1, 2, 5, 10):
        if m * e >= v:
            return m * e
    return 10 * e


def fmt_clock(s):
    s = int(max(0, s))
    return "%d:%02d:%02d" % (s // 3600, s % 3600 // 60, s % 60)


# --------------------------------------------------------------------------
# Leinwand: Zeichen und Farbe je Zelle, am Ende ein ANSI-Bild

class Canvas:
    def __init__(self, w, h, color=True):
        self.w, self.h, self.color = w, h, color
        self.ch = [[" "] * w for _ in range(h)]
        self.st = [[(C["text"], False)] * w for _ in range(h)]

    def put(self, x, y, s, fg=None, bold=False, limit=None):
        """limit: erste Spalte, die nicht mehr beschrieben wird (Kastenrand)."""
        if y < 0 or y >= self.h:
            return
        fg = C["text"] if fg is None else fg
        end = self.w if limit is None else min(self.w, limit)
        for i, c in enumerate(s):
            if 0 <= x + i < end:
                self.ch[y][x + i] = c
                self.st[y][x + i] = (fg, bold)

    def box(self, x, y, w, h, title, fg, info=""):
        if w < 4 or h < 2:
            return
        self.put(x, y, "╭" + "─" * (w - 2) + "╮", fg)
        for r in range(1, h - 1):
            self.put(x, y + r, "│", fg)
            self.put(x + w - 1, y + r, "│", fg)
        self.put(x, y + h - 1, "╰" + "─" * (w - 2) + "╯", fg)
        t = " %s " % title
        self.put(x + 2, y, "┤", fg)
        self.put(x + 3, y, t[:w - 8], C["title"], True)
        self.put(x + 3 + min(len(t), w - 8), y, "├", fg)
        if info and len(t) + len(info) + 10 < w:
            self.put(x + w - len(info) - 5, y, "┤", fg)
            self.put(x + w - len(info) - 4, y, " " + info + " ", C["dim"])
            self.put(x + w - 2, y, "├", fg)

    def render(self):
        out = []
        for y in range(self.h):
            if self.color:
                out.append("\x1b[%d;1H" % (y + 1))
            last = None
            for x in range(self.w):
                st = self.st[y][x]
                if self.color and st != last:
                    out.append("\x1b[0;%s38;5;%dm" % ("1;" if st[1] else "", st[0]))
                    last = st
                out.append(self.ch[y][x])
            if not self.color:
                out.append("\n")
        if self.color:
            out.append("\x1b[0m")
        return "".join(out)


def meter(cv, x, y, w, frac, label="", fg_label=None, limit=None):
    """Balken aus ■ wie in btop, jede Stelle in der Farbe ihres Anteils."""
    if limit is not None:
        w = min(w, limit - x)
    if w <= 0:
        return
    n = int(round(max(0.0, min(1.0, frac)) * w)) if frac == frac else 0
    for i in range(w):
        if i < n:
            cv.put(x + i, y, "■", grad((i + 1) / w))
        else:
            cv.put(x + i, y, "■", C["faint"])
    if label:
        cv.put(x + max(0, w - len(label)), y, label, fg_label or C["hi"], True)


def braille(cv, x, y, w, h, values, vmax, colorfn=None):
    """Scrollender Graph, zwei Werte je Spalte, vier Punkte je Zeile."""
    if w <= 0 or h <= 0:
        return
    vals = list(values)[-(w * 2):]
    vals = [None] * (w * 2 - len(vals)) + vals
    levels = h * 4
    for col in range(w):
        a, b = vals[2 * col], vals[2 * col + 1]
        la = 0 if a is None or vmax <= 0 else int(round(min(1.0, a / vmax) * levels))
        lb = 0 if b is None or vmax <= 0 else int(round(min(1.0, b / vmax) * levels))
        if a is not None and a > 0 and la == 0:
            la = 1
        if b is not None and b > 0 and lb == 0:
            lb = 1
        for row in range(h):
            base = (h - 1 - row) * 4
            bits = 0
            for k in range(4):
                if la > base + k:
                    bits |= BRAILLE_L[k]
                if lb > base + k:
                    bits |= BRAILLE_R[k]
            if bits:
                fg = colorfn((h - row) / h) if colorfn else grad((h - row) / h)
                cv.put(x + col, y + row, chr(0x2800 + bits), fg)


# --------------------------------------------------------------------------
# Quellen: lokal (Dateien) oder imageslive (HTTP)

class LocalSource:
    remote = False

    def __init__(self, root):
        self.root = root
        self.running = os.path.join(root, "images", "running")

    def text(self, rel):
        try:
            with open(os.path.join(self.running, rel), encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return None

    def tail(self, rel, nbytes):
        p = rel if os.path.isabs(rel) else os.path.join(self.running, rel)
        try:
            with open(p, "rb") as f:
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - nbytes))
                return f.read().decode("utf-8", "replace")
        except OSError:
            return None

    def listdir(self, rel):
        try:
            return sorted(os.listdir(os.path.join(self.running, rel)))
        except OSError:
            return []


class HttpSource:
    remote = True

    def __init__(self, base):
        self.base = base.rstrip("/")
        self.running = self.base + "/running"

    def _get(self, url, rng=None):
        req = urllib.request.Request(url, headers={"User-Agent": "buildmonitor"})
        if rng:
            req.add_header("Range", "bytes=-%d" % rng)
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                ctype = r.headers.get("Content-Type", "")
                data = r.read().decode("utf-8", "replace")
                return data, ctype
        except (urllib.error.URLError, OSError, ValueError):
            return None, ""

    def text(self, rel):
        data, ctype = self._get(self.running + "/" + rel)
        # imageslive liefert fuer jeden Pfad 200, fehlende Dateien als HTML
        if data is None or "html" in ctype or data.lstrip().startswith("<!doctype"):
            return None
        return data

    def tail(self, rel, nbytes):
        data, ctype = self._get(self.running + "/" + rel, rng=nbytes)
        if data is None or "html" in ctype:
            return None
        return data

    def listdir(self, rel, base=None):
        base = base or self.running
        data, _ = self._get(base + "/" + rel + "/" if rel else base + "/")
        if not data:
            return []
        path = base.split("://", 1)[-1].split("/", 1)[-1]
        pre = re.escape(path + "/" + rel + "/" if rel else path + "/")
        names = re.findall(r'href="/%s([^"/]+)"' % pre, data)
        return sorted(set(names))

    def prior_build_times(self):
        """build-times.csv des juengsten fertigen Laufs mit buildinfo/."""
        runs = [d for d in self.listdir("", self.base) if re.fullmatch(r"images-\d+", d)]
        for d in sorted(runs, key=lambda n: int(n.split("-")[1]), reverse=True)[:3]:
            for f in self.listdir("buildinfo", self.base + "/" + d):
                if f.endswith(".build-times.csv"):
                    data, ctype = self._get(self.base + "/" + d + "/buildinfo/" + f)
                    if data and "html" not in ctype:
                        return data
        return None


# --------------------------------------------------------------------------
# Systemproben

class ProcSampler:
    """CPU, Prozesse, PSI, Speicher und Platte direkt aus /proc."""

    def __init__(self, path):
        self.prev = None
        self.dev = self._device(path)
        self.path = path

    @staticmethod
    def _device(path):
        try:
            st = os.stat(path)
            p = os.path.realpath("/sys/dev/block/%d:%d" % (os.major(st.st_dev), os.minor(st.st_dev)))
            if os.path.exists(os.path.join(p, "partition")):
                p = os.path.dirname(p)
            name = os.path.basename(p)
            with open("/proc/diskstats") as f:
                if any(z.split()[2] == name for z in f):
                    return name
        except (OSError, IndexError):
            pass
        return None

    def _raw(self):
        cores = []
        total = None
        r = b = 0
        with open("/proc/stat") as f:
            for z in f:
                if z.startswith("cpu"):
                    v = [int(x) for x in z.split()[1:9]]
                    if z.startswith("cpu "):
                        total = v
                    else:
                        cores.append(v)
                elif z.startswith("procs_running "):
                    r = int(z.split()[1])
                elif z.startswith("procs_blocked "):
                    b = int(z.split()[1])
        disk = None
        if self.dev:
            with open("/proc/diskstats") as f:
                for z in f:
                    t = z.split()
                    if t[2] == self.dev:
                        disk = (int(t[5]), int(t[9]), int(t[12]))
        return time.time(), total, cores, r, b, disk

    @staticmethod
    def _psi():
        out = {}
        for name in ("cpu", "io", "memory"):
            try:
                with open("/proc/pressure/" + name) as f:
                    z = f.readline()
                out[name] = float(re.search(r"avg10=([\d.]+)", z).group(1))
            except (OSError, AttributeError, ValueError):
                out[name] = None
        return out

    @staticmethod
    def _mem():
        m = {}
        try:
            with open("/proc/meminfo") as f:
                for z in f:
                    k, v = z.split(":", 1)
                    m[k] = int(v.split()[0]) * 1024
        except (OSError, ValueError):
            pass
        return m

    def sample(self):
        cur = self._raw()
        prev, self.prev = self.prev, cur
        if prev is None:
            return None
        dt = max(1e-3, cur[0] - prev[0])

        def busy(a, b):
            d = [y - x for x, y in zip(a, b)]
            tot = sum(d) or 1
            return (tot - d[3] - d[4]) / tot, d[4] / tot, d[7] / tot

        n = len(cur[2]) or 1
        bf, iof, stf = busy(prev[1], cur[1])
        per = [busy(a, b)[0] for a, b in zip(prev[2], cur[2])]
        s = {
            "t": cur[0], "cores": n, "busy": bf * n, "iowait": iof * n, "steal": stf * n,
            "per": per, "running": cur[3], "blocked": cur[4],
        }
        p = self._psi()
        s["psi_cpu"], s["psi_io"], s["psi_mem"] = p["cpu"], p["io"], p["memory"]
        if cur[5] and prev[5]:
            s["write_mb"] = (cur[5][0] - prev[5][0]) * 512 / dt / 1e6
            s["util"] = min(100.0, (cur[5][2] - prev[5][2]) / (dt * 10))
        m = self._mem()
        s["mem"] = m
        try:
            du = shutil.disk_usage(self.path)
            s["free_gb"], s["size_gb"] = du.free / 1e9, du.total / 1e9
        except OSError:
            pass
        try:
            with open("/proc/loadavg") as f:
                s["load"] = float(f.read().split()[0])
        except (OSError, ValueError):
            pass
        return s


CSV_COLS = ("epoch,aktiv,iowait,util,schreib_mb,iops,prepare,golden,build,finalize,"
            "steal,running,blocked,psi_cpu,psi_io,psi_io_full,psi_mem").split(",")


def csv_rows(text):
    """Zeilen des Collector-CSV als Dicts; unvollstaendige am Rand fallen weg."""
    rows = []
    for z in (text or "").splitlines():
        t = z.split(",")
        if len(t) != len(CSV_COLS) or not t[0][:1].isdigit():
            continue
        r = {}
        for k, v in zip(CSV_COLS, t):
            try:
                r[k] = float(v)
            except ValueError:
                r[k] = None
        rows.append(r)
    return rows


def rows_to_sample(rows, cores):
    """Mittel ueber Collector-Proben, im Format von ProcSampler.sample."""
    def avg(k):
        v = [r[k] for r in rows if r.get(k) is not None]
        return sum(v) / len(v) if v else None
    aktiv, iow = avg("aktiv"), avg("iowait")
    return {
        "t": rows[-1]["epoch"], "cores": cores,
        "busy": None if aktiv is None else max(0.0, aktiv - (iow or 0)),
        "iowait": iow, "steal": avg("steal"), "running": avg("running"),
        "blocked": avg("blocked"), "psi_cpu": avg("psi_cpu"), "psi_io": avg("psi_io"),
        "psi_mem": avg("psi_mem"), "write_mb": avg("schreib_mb"), "util": avg("util"),
        "workers_busy": avg("build"),
    }


# --------------------------------------------------------------------------
# Zustand des Laufs

class Run:
    def __init__(self):
        self.active = False
        self.head = {}
        self.targets, self.domains = [], []
        self.done = set()          # (template, target)
        self.finalized = 0
        self.status = {}           # name -> dict
        self.metrics_rel = None


def kv(text):
    d = {}
    for z in (text or "").splitlines():
        if "=" in z and not z.startswith("#") and "\t" not in z:
            k, v = z.split("=", 1)
            d[k.strip()] = v.strip()
    return d


def read_run(src, cache):
    """cache: je Lauf gleichbleibende Teile (Target-/Domainliste, CSV-Name),
    damit aus der Ferne nicht jedes Mal alles neu geholt wird."""
    r = Run()
    st = src.text(".build-state")
    if not st or "sbranch=" not in st:
        return r
    r.active = True
    r.head = kv(st)
    for z in st.splitlines():
        t = z.split("\t")
        if len(t) == 4 and t[0] == "build":
            r.done.add((t[1], t[3]))
        elif len(t) == 4 and t[0] == "finalize":
            r.finalized += 1
    if cache.get("sbranch") != r.head.get("sbranch"):
        cache.clear()
        cache["sbranch"] = r.head.get("sbranch")
    if "fp" not in cache:
        fp = kv(src.text(".build-fingerprint"))
        if fp.get("targets"):
            cache["fp"] = fp
    fp = cache.get("fp", {})
    r.targets = fp.get("targets", "").split()
    r.domains = fp.get("domains", "").split()
    names = [n for n in src.listdir(".status") if not n.endswith(".tmp")]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        texts = list(ex.map(lambda n: src.text(".status/" + n), names))
    for name, text in zip(names, texts):
        d = kv(text)
        if "phase" in d:
            r.status[name] = d
    if "metrics" not in cache:
        for name in src.listdir("buildinfo"):
            if name.endswith(".metrics.csv"):
                cache["metrics"] = "buildinfo/" + name
    r.metrics_rel = cache.get("metrics")
    if not r.targets:
        r.targets = sorted({t for _, t in r.done} | {d.get("target") for d in r.status.values()} - {"-", None})
    if not r.domains:
        r.domains = sorted({d for d, _ in r.done})
    return r


def bt_rows(text):
    rows = []
    for z in (text or "").splitlines():
        t = z.split(",")
        if len(t) >= 9 and t[0] != "run_id":
            rows.append(t)
    return rows


def prior_means(rows, rid=None):
    """Mittlere Schrittzeit je Target im juengsten Lauf ausser rid."""
    runs = collections.OrderedDict()
    for t in rows:
        if t[4] == "build" and t[0] != rid:
            runs.setdefault(t[0], []).append(t)
    for r in reversed(list(runs.values())):
        by = collections.defaultdict(list)
        for t in r:
            try:
                by[t[7]].append(int(t[8]))
            except ValueError:
                pass
        if by:
            return {k: statistics.mean(v) for k, v in by.items()}
    return {}


class BuildTimes:
    """build-times.csv, inkrementell gelesen: Schrittzeiten dieses und
    frueherer Laeufe."""

    def __init__(self, path):
        self.path, self.pos, self.rows = path, 0, []

    def update(self):
        try:
            with open(self.path, encoding="utf-8", errors="replace") as f:
                f.seek(0, 2)
                if f.tell() < self.pos:
                    self.pos, self.rows = 0, []
                f.seek(self.pos)
                data = f.read()
                self.pos = f.tell()
        except OSError:
            return
        cut = data.rfind("\n") + 1
        self.pos -= len(data[cut:].encode("utf-8"))
        self.rows.extend(bt_rows(data[:cut]))

    def run_id(self, sbranch):
        rid = None
        for t in self.rows:
            if t[4] == "run_start" and ("sbranch=%s" % sbranch) in ",".join(t[9:]):
                rid = t[0]
        return rid

    def steps(self, rid):
        out = []
        for t in self.rows:
            if t[0] == rid and t[4] == "build":
                try:
                    out.append({"end": int(t[2]), "sec": int(t[8]), "template": t[5],
                                "code": t[6], "target": t[7]})
                except ValueError:
                    pass
        return out

    def prior_means(self, rid):
        return prior_means(self.rows, rid)


# --------------------------------------------------------------------------
# Monitor: sammelt je Takt und zeichnet

class Monitor:
    def __init__(self, src, root, interval):
        self.src, self.root, self.interval = src, root, interval
        self.hist = collections.deque(maxlen=2000)
        self.proc = None if src.remote else ProcSampler(root)
        self.bt = None if src.remote else BuildTimes(os.path.join(root, "build-times.csv"))
        self.csv_seen = 0.0
        self.prefilled = False
        self.run = Run()
        self.sbranch = None
        self.obs_steps = []                 # aus der Ferne beobachtete Schritte
        self.obs_seit = {}                  # target -> (domain, seit)
        self.cores = 1 if src.remote else (os.cpu_count() or 1)
        self.last_sample = None
        self.max_workers_seen = 0
        self.remote_prior = None
        self.cache = {}

    # -- Sammeln --------------------------------------------------------

    def _infer_cores(self, rows):
        """Aus der Ferne ist die Kernzahl unbekannt. Der golden tree und die
        Vollastspitzen erreichen sie; das Maximum von "aktiv" taugt also."""
        if self.src.remote:
            v = [r["aktiv"] for r in rows if r.get("aktiv") is not None]
            if v:
                self.cores = max(self.cores, int(math.ceil(max(v) - 0.05)))

    def _prefill(self):
        if self.src.remote and self.remote_prior is None:
            self.remote_prior = prior_means(bt_rows(self.src.prior_build_times()))
        if not self.run.metrics_rel:
            return
        text = self.src.tail(self.run.metrics_rel, 400000)
        rows = csv_rows(text)
        if not rows:
            return
        self._infer_cores(rows)
        step = max(1, int(round(self.interval)))
        for i in range(0, len(rows) - step + 1, step):
            chunk = rows[i:i + step]
            self.hist.append(rows_to_sample(chunk, self.cores))
        self.csv_seen = rows[-1]["epoch"]
        if self.hist and self.src.remote:
            self.last_sample = self.hist[-1]

    def collect(self):
        self.run = read_run(self.src, self.cache)
        if self.run.active and self.run.head.get("sbranch") != self.sbranch:
            self.sbranch = self.run.head.get("sbranch")
            self.hist.clear()
            self.prefilled = False
            self.obs_steps, self.obs_seit = [], {}
            self.max_workers_seen = 0
        if self.run.active and not self.prefilled:
            self._prefill()
            self.prefilled = True
        if self.bt:
            self.bt.update()

        s = None
        new_rows = []
        if self.run.metrics_rel:
            rows = csv_rows(self.src.tail(self.run.metrics_rel, 16000))
            new_rows = [r for r in rows if r["epoch"] > self.csv_seen]
            if new_rows:
                self.csv_seen = new_rows[-1]["epoch"]
                self._infer_cores(new_rows)
        if self.proc:
            s = self.proc.sample()
            if s is not None:
                self.cores = s["cores"]
                if new_rows:
                    s["workers_busy"] = rows_to_sample(new_rows, self.cores)["workers_busy"]
        elif new_rows:
            s = rows_to_sample(new_rows, self.cores)
        if s is not None:
            if s.get("workers_busy") is None and self.run.active:
                s["workers_busy"] = sum(1 for d in self.run.status.values() if d.get("phase") == "build")
            self.hist.append(s)
            self.last_sample = s
        self._observe()

    def _observe(self):
        """Aus der Ferne gibt es keine build-times.csv: Schrittzeiten aus dem
        Wechsel von Domain/Beginn in den Statusdateien ableiten."""
        for name, d in self.run.status.items():
            if name == "main":
                continue
            tgt, dom = d.get("target"), d.get("domain")
            try:
                seit = int(d.get("seit", "0"))
            except ValueError:
                continue
            old = self.obs_seit.get(tgt)
            if old and old[1] != seit and old[1] > 0:
                self.obs_steps.append({"end": seit, "sec": seit - old[1], "code": old[0],
                                       "template": old[0], "target": tgt})
            self.obs_seit[tgt] = (dom, seit)
        self.max_workers_seen = max(self.max_workers_seen,
                                    sum(1 for n in self.run.status if n != "main"))

    # -- Auswerten ------------------------------------------------------

    def steps(self):
        if self.bt and self.sbranch:
            rid = self.bt.run_id(self.sbranch)
            if rid:
                return self.bt.steps(rid), self.bt.prior_means(rid)
        return list(self.obs_steps), (self.remote_prior or {})

    def workers(self):
        """Aktive Bauprozesse: Worker, im seriellen oder golden-Betrieb der
        Hauptprozess."""
        out = []
        for name, d in sorted(self.run.status.items()):
            if d.get("phase") in ("build", "golden", "netwait") and d.get("target", "-") != "-":
                out.append(d)
        return out

    def current_template(self, target, code):
        """Die Statusdatei nennt den Site-Code; key- und nokey-Variante teilen
        ihn. Gebaut wird in der Reihenfolge der Domainliste, also ist es die
        erste noch offene Variante mit diesem Code."""
        for dm in self.run.domains:
            c = dm[:-4] if dm.endswith("-key") else dm
            if c == code and (dm, target) not in self.run.done:
                return dm
        return code

    def eta(self, steps, prior):
        D = len(self.run.domains)
        if not D or not self.run.targets:
            return None, {}
        by = collections.defaultdict(list)
        for s in steps:
            by[s["target"]].append(s["sec"])
        allm = statistics.mean([s["sec"] for s in steps]) if steps else None
        mean = {}
        for t in self.run.targets:
            mean[t] = statistics.mean(by[t]) if by[t] else prior.get(t, allm)
        done = collections.Counter(t for _, t in self.run.done)
        now = time.time()
        running = {}
        for d in self.workers():
            try:
                running[d["target"]] = now - int(d.get("seit", now))
            except ValueError:
                running[d["target"]] = 0
        rem = {}
        for t in self.run.targets:
            left = D - done[t]
            if left <= 0:
                rem[t] = 0.0
                continue
            if mean[t] is None:
                return None, mean
            rem[t] = max(0.0, left * mean[t] - running.get(t, 0))
        try:
            W = int(self.run.head.get("workers") or 0)
        except ValueError:
            W = 0
        W = max(W, self.max_workers_seen, 1)
        free = sorted([rem[t] for t in running if rem.get(t)])
        free += [0.0] * max(0, W - len(free))
        free.sort()
        pending = sorted((rem[t] for t in self.run.targets if t not in running and rem[t] > 0), reverse=True)
        for p in pending:
            free[0] += p
            free.sort()
        return max(free) + 10 * D if free else 0.0, mean

    def worker_log(self, target):
        if self.src.remote:
            return ""
        text = self.src.tail(os.path.join(self.root, ".overlays", target + ".log"), 4096) or ""
        lines = [z for z in text.splitlines() if z.strip()]
        if not lines:
            return ""
        z = re.sub(r"\x1b\[[0-9;]*m", "", lines[-1])
        z = re.sub(r"^\[[\d:T +-]+\]\s*", "", z)     # Zeitstempel von timestamp_lines
        return z.strip()

    # -- Zeichnen -------------------------------------------------------

    def draw(self, W, H, color=True):
        cv = Canvas(W, H, color)
        steps, prior = self.steps()
        eta, means = self.eta(steps, prior) if self.run.active else (None, {})
        wk = self.workers()

        self._header(cv, 0, 0, W, steps, eta)
        y = 4
        wk_h = (max(1, len(wk)) + 3) if self.run.active else 3
        wk_h = min(wk_h, max(3, H // 3))
        nt = len(self.run.targets)
        bottom_h = 0
        rest = H - y - wk_h
        if self.run.active and nt and rest >= 22:
            bottom_h = min(nt + 4, rest - 14)
        mid_h = rest - bottom_h
        self._system(cv, 0, y, W, mid_h)
        y += mid_h
        self._workers(cv, 0, y, W, wk_h, wk, means)
        y += wk_h
        if bottom_h:
            if W >= 110:
                mw = min(W - 40, max(60, len(self.run.domains) + 36))
                self._matrix(cv, 0, y, mw, bottom_h, means)
                self._events(cv, mw, y, W - mw, bottom_h, steps, means)
            else:
                self._matrix(cv, 0, y, W, bottom_h, means)
        return cv.render()

    def _header(self, cv, x, y, w, steps, eta):
        cv.box(x, y, w, 4, "build-monitor", C["hdr"], time.strftime("%H:%M:%S"))
        r = self.run
        if not r.active:
            cv.put(x + 2, y + 1, "kein Lauf aktiv", C["warn"], True)
            cv.put(x + 18, y + 1, "(images/running/.build-state fehlt)", C["dim"])
            last = self._last_summary()
            if last:
                cv.put(x + 2, y + 2, last[:w - 4], C["dim"])
            return
        h = r.head
        D, T = len(r.domains), len(r.targets)
        total = int(h.get("steps") or D * T or 0)
        done = len(r.done)
        try:
            started = time.mktime(time.strptime(h.get("started", "")[:19], "%Y-%m-%dT%H:%M:%S"))
        except ValueError:
            started = None
        main = r.status.get("main", {})
        phase = main.get("phase") or ("build" if self.workers() else "?")
        if phase in ("golden", "prepare") and main.get("target", "-") != "-":
            phase += " (%s)" % main["target"]
        # Reihenfolge = Wichtigkeit: was nicht mehr passt, faellt hinten weg
        parts = [
            ("", h.get("sbranch", "?"), C["val"]),
            ("Phase ", phase, C["run"] if phase.startswith("build") else C["warn"]),
        ]
        if eta is not None:
            parts.append(("ETA ", time.strftime("%H:%M", time.localtime(time.time() + eta))
                          + " (noch %s)" % fmt_dur(eta), C["ok"]))
        if started:
            parts.append(("läuft ", fmt_clock(time.time() - started), C["val"]))
        parts.append(("", "%d Domains × %d Targets" % (D, T), C["text"]))
        parts.append(("Worker ", h.get("workers") or str(self.max_workers_seen or "?"), C["val"]))
        erl = self._erlang()
        if erl:
            parts.append(("", "%.1f Erl" % erl, C["busy"]))
        cx = x + 2
        for i, (k, v, fg) in enumerate(parts):
            sep = 3 if i else 0
            if cx + sep + len(k) + len(v) > x + w - 2:
                continue
            if sep:
                cv.put(cx, y + 1, " │ ", C["faint"])
                cx += 3
            cv.put(cx, y + 1, k, C["dim"])
            cx += len(k)
            cv.put(cx, y + 1, v, fg, True)
            cx += len(v)
        label = " %d/%d Schritte  %d%%  · %d Domains fertig " % (
            done, total, 100 * done // max(1, total), r.finalized)
        bw = w - 4 - len(label)
        meter(cv, x + 2, y + 2, bw, done / max(1, total))
        cv.put(x + 2 + bw, y + 2, label, C["hi"], True)

    def _last_summary(self):
        if self.src.remote:
            return ""
        img = os.path.join(self.root, "images")
        try:
            runs = sorted(d for d in os.listdir(img) if d.startswith("images-"))
        except OSError:
            return ""
        for d in reversed(runs):
            bi = os.path.join(img, d, "buildinfo")
            try:
                for f in os.listdir(bi):
                    if f.endswith(".summary.txt"):
                        with open(os.path.join(bi, f)) as fh:
                            z = [l.strip() for l in fh if l.strip().startswith(("Lauf", "Dauer"))]
                        return "letzter Lauf: " + "  ".join(z)
            except OSError:
                continue
        return ""

    def _erlang(self):
        v = [s.get("workers_busy") for s in self.hist if s.get("workers_busy")]
        return statistics.mean(v) if v else None

    def _series(self, key, scale=1.0):
        return [None if s.get(key) is None else s[key] * scale for s in self.hist]

    def _system(self, cv, x, y, w, h):
        if h < 5:
            return
        two_rows = h >= 14
        left_w = int(w * 0.62) if w >= 100 else w
        rh = h // 2 if two_rows else h
        # CPU
        s = self.last_sample or {}
        cores = s.get("cores", self.cores)
        info = ("~%d Kerne" if self.src.remote else "%d Kerne") % cores
        if s.get("load") is not None:
            info += "  Last %.1f" % s["load"]
        cv.box(x, y, left_w, rh, "CPU", C["cpu"], info)
        gh = rh - 3
        per = s.get("per")
        if per and rh >= 8 and left_w >= 40:
            gh -= 1
        braille(cv, x + 1, y + 1, left_w - 2, max(1, gh), self._series("busy"), cores)
        line = y + 1 + max(1, gh)
        if per and rh >= 8 and left_w >= 40:
            cv.put(x + 2, line, "Kerne ", C["dim"])
            cx = x + 8
            for f in per[:left_w - 12]:
                cv.put(cx, line, SPARK[min(8, int(round(f * 8)))] if f > 0.01 else "▁", grad(f))
                cx += 1
            line += 1
        busy = s.get("busy")
        txt = [("belegt ", "%.1f (%d %%)" % (busy, 100 * busy / max(1, cores)) if busy is not None else "–", C["val"]),
               ("  iowait ", "%.2f" % s["iowait"] if s.get("iowait") is not None else "–", C["warn"]),
               ("  steal ", "%.2f" % s["steal"] if s.get("steal") is not None else "–", C["dim"]),
               ("  run ", "%d" % s["running"] if s.get("running") is not None else "–", C["val"]),
               ("  blk ", "%d" % s["blocked"] if s.get("blocked") is not None else "–", C["bad"])]
        cx = x + 2
        for k, v, fg in txt:
            if cx + len(k) + len(v) > x + left_w - 2:
                break
            cv.put(cx, line, k, C["dim"])
            cv.put(cx + len(k), line, v, fg, True)
            cx += len(k) + len(v)
        if w >= 100:
            self._pressure(cv, x + left_w, y, w - left_w, rh, s)
        if not two_rows:
            return
        y2, h2 = y + rh, h - rh
        self._disk(cv, x, y2, left_w, h2, s)
        if w >= 100:
            self._busy(cv, x + left_w, y2, w - left_w, h2)

    def _pressure(self, cv, x, y, w, h, s):
        cv.box(x, y, w, h, "Druck & Speicher", C["psi"], "PSI some")
        row = y + 1
        mw = w - 16
        for k, lab in (("psi_cpu", "cpu"), ("psi_io", "io "), ("psi_mem", "mem")):
            if row >= y + h - 1:
                return
            v = s.get(k)
            cv.put(x + 2, row, "PSI " + lab, C["dim"])
            meter(cv, x + 10, row, mw, (v or 0) / 100.0)
            cv.put(x + 11 + mw, row, "%3.0f%%" % v if v is not None else "  – ", C["hi"], True)
            row += 1
        m = s.get("mem") or {}
        if m.get("MemTotal") and row < y + h - 1:
            used = m["MemTotal"] - m.get("MemAvailable", 0)
            cv.put(x + 2, row, "RAM    ", C["dim"])
            meter(cv, x + 10, row, mw, used / m["MemTotal"])
            cv.put(x + 11 + mw, row, "%3.0f%%" % (100 * used / m["MemTotal"]), C["hi"], True)
            row += 1
            if row < y + h - 1:
                cv.put(x + 2, row, "%.0f von %.0f GB  Cache %.0f GB" % (
                    used / 1e9, m["MemTotal"] / 1e9, m.get("Cached", 0) / 1e9), C["text"], limit=x + w - 1)
                row += 1
            if row < y + h - 1:
                cv.put(x + 2, row, "Dirty ", C["dim"])
                cv.put(x + 8, row, "%.0f MB" % (m.get("Dirty", 0) / 1e6), C["warn"], True)
                cv.put(x + 17, row, "Writeback ", C["dim"])
                cv.put(x + 27, row, "%.0f MB" % (m.get("Writeback", 0) / 1e6), C["bad"], True)
                row += 1
        if row < y + h - 2:
            braille(cv, x + 1, row, w - 2, y + h - 1 - row, self._series("psi_io"), 100,
                    lambda f: grad(0.35 + f * 0.65))

    def _disk(self, cv, x, y, w, h, s):
        free = s.get("free_gb")
        info = "%.0f GB frei" % free if free is not None else ""
        cv.box(x, y, w, h, "Platte schreiben", C["disk"], info)
        wr = self._series("write_mb")
        vals = [v for v in wr if v is not None]
        # Skala nach dem 98. Perzentil: einzelne Spitzen von einigen GB/s
        # (Images schreiben) druecken den Rest sonst auf die Nulllinie.
        srt = sorted(vals)
        vmax = nice_ceil(max(50.0, srt[int(0.98 * (len(srt) - 1))] if srt else 50.0))
        gh = h - 3
        braille(cv, x + 1, y + 1, w - 2, max(1, gh), wr, vmax, lambda f: [214, 208, 202, 196, 197][min(4, int(f * 5))])
        cv.put(x + w - 2 - len("%d MB/s" % vmax), y + 1, "%d MB/s" % vmax, C["dim"])
        line = y + h - 2
        cur = s.get("write_mb")
        util = s.get("util")
        cv.put(x + 2, line, "jetzt ", C["dim"])
        cv.put(x + 8, line, "%.0f MB/s" % cur if cur is not None else "–", C["hi"], True)
        cv.put(x + 20, line, "util ", C["dim"])
        if util is not None:
            meter(cv, x + 25, line, min(20, w - 40), util / 100)
            cv.put(x + 26 + min(20, w - 40), line, "%3.0f%%" % util, C["hi"], True)
        if vals:
            cv.put(x + w - 20, line, "max %.0f MB/s" % max(vals), C["dim"])

    def _busy(self, cv, x, y, w, h):
        try:
            W = int(self.run.head.get("workers") or 0)
        except ValueError:
            W = 0
        W = max(W, self.max_workers_seen, 1)
        erl = self._erlang()
        cv.box(x, y, w, h, "Worker belegt", C["busy"], "%.2f Erl" % erl if erl else "")
        braille(cv, x + 1, y + 1, w - 2, max(1, h - 3), self._series("workers_busy"), W,
                lambda f: [99, 105, 141, 177, 213][min(4, int(f * 5))])
        cur = self.hist[-1].get("workers_busy") if self.hist else None
        cv.put(x + 2, y + h - 2, "jetzt ", C["dim"])
        cv.put(x + 8, y + h - 2, "%s von %d" % ("%.0f" % cur if cur is not None else "–", W), C["hi"], True)

    def _workers(self, cv, x, y, w, h, wk, means):
        cv.box(x, y, w, h, "Worker", C["wrk"], "%d aktiv" % len(wk) if self.run.active else "")
        if not self.run.active:
            return
        D = len(self.run.domains) or 1
        done = collections.Counter(t for _, t in self.run.done)
        tw = max([len(t) for t in self.run.targets] + [10]) + 3
        dw = max([len(d) for d in self.run.domains] + [8]) + 2
        cols = [("Target", tw), ("Domain", dw), ("Schritt", 18), ("Fortschritt", 26), ("Rest", 8),
                ("Log" if not self.src.remote else "Beginn", 0)]
        lim = x + w - 1
        cx = x + 2
        for name, cw in cols:
            cv.put(cx, y + 1, name, C["dim"], limit=lim)
            cx += cw
        now = time.time()
        for i, d in enumerate(wk[:h - 3]):
            row = y + 2 + i
            t = d.get("target", "?")
            try:
                el = now - int(d.get("seit", now))
            except ValueError:
                el = 0
            m = means.get(t)
            cx = x + 2
            ph = d.get("phase")
            cv.put(cx, row, "▶ " if ph == "build" else "◆ ", C["run"] if ph == "build" else C["warn"])
            cv.put(cx + 2, row, t, C["hi"], True, limit=lim)
            cx += tw
            cv.put(cx, row, self.current_template(t, d.get("domain", "?")), C["val"], limit=lim)
            cx += dw
            frac = el / m if m else 0
            fg = C["ok"] if not m or frac < 0.9 else C["warn"] if frac < 1.2 else C["bad"]
            txt = fmt_dur(el) + (" / ø" + fmt_dur(m) if m else "")
            cv.put(cx, row, txt, fg, True, limit=min(lim, cx + 17))
            cx += 18
            nd = done[t]
            meter(cv, cx, row, 14, nd / D, limit=lim)
            cv.put(cx + 15, row, "%d/%d" % (nd, D), C["text"], limit=lim)
            cx += 26
            if m:
                cv.put(cx, row, fmt_dur(max(0, (D - nd) * m - el)), C["ok"], limit=lim)
            cx += 8
            if self.src.remote:
                try:
                    cv.put(cx, row, time.strftime("%H:%M:%S", time.localtime(int(d.get("seit")))),
                           C["dim"], limit=lim)
                except (TypeError, ValueError):
                    pass
            else:
                cv.put(cx, row, self.worker_log(t), C["dim"], limit=lim)
        if not wk:
            cv.put(x + 2, y + 2, "gerade kein Bauprozess (prepare, finalize oder Wechsel)", C["dim"], limit=lim)

    def _matrix(self, cv, x, y, w, h, means):
        r = self.run
        cv.box(x, y, w, h, "Domains × Targets", C["mat"], "■ fertig ▶ läuft · offen")
        running = {}
        for d in self.workers():
            running[d.get("target")] = d.get("domain")
        lw = max(len(t) for t in r.targets) + 1 if r.targets else 10
        avail = w - lw - 16
        doms = r.domains
        for i, t in enumerate(r.targets[:h - 3]):
            row = y + 1 + i
            cv.put(x + 2, row, t, C["text"])
            cur = self.current_template(t, running[t]) if t in running else None
            n = 0
            for j, dm in enumerate(doms[:avail]):
                if (dm, t) in r.done:
                    cv.put(x + 2 + lw + j, row, "■", grad(0.2 + 0.25 * (j % 2)))
                    n += 1
                elif dm == cur:
                    cv.put(x + 2 + lw + j, row, "▶", C["run"], True)
                else:
                    cv.put(x + 2 + lw + j, row, "·", C["todo"])
            n = sum(1 for dm in doms if (dm, t) in r.done)
            m = means.get(t)
            cv.put(x + 3 + lw + min(len(doms), avail), row,
                   "%2d/%d" % (n, len(doms)) + ("  ø%s" % fmt_dur(m) if m else ""), C["dim"], limit=x + w - 1)
        axis = y + 1 + min(len(r.targets), h - 3)
        if axis < y + h - 1:
            for j in range(0, min(len(doms), avail), 10):
                cv.put(x + 2 + lw + j, axis, "|%d" % j if j else "|0", C["faint"])

    def _events(self, cv, x, y, w, h, steps, means):
        cv.box(x, y, w, h, "Fertig", C["log"], "%d Schritte" % len(steps) if steps else "")
        rows = sorted(steps, key=lambda s: s["end"], reverse=True)[:h - 2]
        lim = x + w - 1
        tw = max([len(t) for t in self.run.targets] + [10]) + 1
        for i, s in enumerate(rows):
            row = y + 1 + i
            m = means.get(s["target"])
            f = s["sec"] / m if m else 1.0
            fg = C["ok"] if f < 0.95 else C["warn"] if f < 1.15 else C["bad"]
            cv.put(x + 2, row, time.strftime("%H:%M:%S", time.localtime(s["end"])), C["dim"], limit=lim)
            cv.put(x + 11, row, "%7s" % fmt_dur(s["sec"]), fg, True, limit=lim)
            cv.put(x + 19, row, s["target"], C["text"], limit=lim)
            cv.put(x + 19 + tw, row, s["template"], C["val"], limit=lim)
        if not rows:
            msg = ["noch keine Schrittzeiten"]
            if self.src.remote:
                msg.append("aus der Ferne erst nach dem")
                msg.append("ersten Domainwechsel je Worker")
            for i, z in enumerate(msg[:h - 2]):
                cv.put(x + 2, y + 1 + i, z, C["dim"], limit=lim)


# --------------------------------------------------------------------------
# Terminal

class Terminal:
    def __init__(self):
        self.fd = sys.stdin.fileno()
        self.old = None

    def __enter__(self):
        import termios
        import tty
        self.old = termios.tcgetattr(self.fd)
        tty.setcbreak(self.fd)
        sys.stdout.write("\x1b[?1049h\x1b[?25l\x1b[2J")
        sys.stdout.flush()
        return self

    def __exit__(self, *a):
        import termios
        sys.stdout.write("\x1b[0m\x1b[?25h\x1b[?1049l")
        sys.stdout.flush()
        if self.old:
            termios.tcsetattr(self.fd, termios.TCSADRAIN, self.old)

    def key(self, timeout):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if r:
            return os.read(self.fd, 16).decode("utf-8", "replace")
        return None


def main():
    ap = argparse.ArgumentParser(description="Live-Ansicht eines build.sh-Laufs")
    ap.add_argument("--dir", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    help="Buildverzeichnis (Standard: das Verzeichnis ueber scripts/)")
    ap.add_argument("--url", help="aus der Ferne: images-URL, z. B. https://imageslive.ffdus.de/images2023.2ad")
    ap.add_argument("-i", "--interval", type=float, default=None, help="Sekunden je Bild (lokal 2, Ferne 5)")
    ap.add_argument("--once", action="store_true", help="ein Bild auf stdout und Ende")
    ap.add_argument("--size", help="BxH fuer --once, z. B. 160x50")
    ap.add_argument("--no-color", action="store_true", help="ohne Farben (nur mit --once)")
    a = ap.parse_args()

    src = HttpSource(a.url) if a.url else LocalSource(a.dir)
    interval = a.interval or (5.0 if a.url else 2.0)
    mon = Monitor(src, a.dir, interval)

    if a.once:
        if a.size:
            W, H = (int(v) for v in a.size.lower().split("x"))
        else:
            W, H = shutil.get_terminal_size((160, 50))
        mon.collect()
        if mon.proc:
            time.sleep(min(1.0, interval))
            mon.collect()
        sys.stdout.write(mon.draw(W, H, color=not a.no_color))
        sys.stdout.write("\n")
        return

    if not sys.stdin.isatty() or not sys.stdout.isatty():
        sys.exit("buildmonitor: braucht ein Terminal (sonst --once)")
    resized = [True]
    signal.signal(signal.SIGWINCH, lambda *x: resized.__setitem__(0, True))
    with Terminal() as term:
        next_collect = 0.0
        while True:
            now = time.time()
            if now >= next_collect:
                mon.collect()
                next_collect = now + mon.interval
            W, H = shutil.get_terminal_size((120, 40))
            if resized[0]:
                sys.stdout.write("\x1b[2J")
                resized[0] = False
            sys.stdout.write(mon.draw(W, H))
            sys.stdout.flush()
            keys = term.key(max(0.05, next_collect - time.time()))
            if keys is None:
                continue
            if any(k in keys for k in ("q", "Q", "\x03")) or keys == "\x1b":
                break
            for k in keys:
                if k == "+":
                    mon.interval = min(60.0, mon.interval * 1.5)
                elif k == "-":
                    mon.interval = max(0.5, mon.interval / 1.5)
                elif k == " ":
                    next_collect = 0.0


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
