# build.sh – Arbeitsweise, Optionen, Parallelbetrieb

Stand 10.09.2026, Branch `v2023.2.x-parallel`. Messwerte vom Buildhost
wir-horst und einem lokalen Messplatz, siehe Abschnitt 8.

---

## 1. Überblick

- Baut Gluon-Firmware für viele Domains aus **einem** Gluon-Baum (`gluon/`).
- Arbeitseinheit: **eine Domain × ein Target** (`make GLUON_TARGET=…` mit der
  Site-Konfiguration dieser Domain).
- Pro Domain danach ein **Abschluss** (finalize): Manifest, Signatur,
  Site-Verzeichnis, Herkunftsdatei.
- Ergebnis eines Laufs: `images/images-<epoch>/`, bis dahin `images/running/`.
- Ein Lauf ist **fortsetzbar** (`--resume`), der Fortschritt steht in einer
  Zustandsdatei.
- Optional **parallel** über mehrere Targets gleichzeitig (`WORKERS` ≥ 2),
  rootless über User-Namespaces und Kernel-overlayfs.

---

## 2. Aufruf und Optionen

```
./build.sh <build.conf> <targets.conf> <domains.conf> [target …] [--resume | --restart]
```

| Teil | Bedeutung |
|---|---|
| `build.conf` | *wie* gebaut wird: Version, Aufräumen, Parallelität, Gluon-Optionen |
| `targets.conf` | *welche Hardware*: `GLUON_TARGETS` |
| `domains.conf` | *welche Domains*: `SITES_FILE`, `DOMAINS_INCLUDE`, `DOMAINS_EXCLUDE` |
| `[target …]` | überschreibt `GLUON_TARGETS`, für einzelne Testbauten |
| `--resume` | abgebrochenen Lauf fortsetzen: nur Fehlendes bauen, Release-String und Ausgabeverzeichnis bleiben |
| `--restart` | übrig gebliebenen Lauf verwerfen (`images/running` löschen) und neu anfangen |
| *(keins von beiden)* | liegt noch ein `images/running` herum → Abbruch mit Hinweis |
| `--worker=<target>` | intern, startet sich build.sh im Parallelbetrieb selbst; nicht von Hand |

- `--resume` und `--restart` zusammen → Abbruch.
- Optionen dürfen vor oder hinter den drei Dateien stehen.
- Muss aus dem **eigenen Verzeichnis** gestartet werden (sonst Abbruch).
- Auf wir-horst üblich mit dem Wrapper, der mit `nice 15` startet und nach
  `long-server-task.log` loggt:

  ```
  ./long-server-task.sh ./build.sh build.conf targets.conf domains.conf &
  ```

Beispiele:

| Zweck | Aufruf |
|---|---|
| Volllauf stable | `./build.sh build.conf targets.conf domains.conf` |
| Broken-Testlauf | `./build.sh build.conf targets.conf domains-broken.conf` |
| nur ein Target | `./build.sh build.conf targets.conf domains.conf ramips-mt7621` |
| nach Abbruch weiter | `./build.sh build.conf targets.conf domains.conf --resume` |
| alten Rest wegwerfen | `./build.sh build.conf targets.conf domains.conf --restart` |

---

## 3. Konfiguration

### 3.1 Ladereihenfolge

1. Vorgaben in build.sh (`set_config_defaults`)
2. `build.conf`
3. `build.local.conf` – optional, gitignored, maschinenabhängig (z. B.
   `WORKERS`, `MAKECLEAN=false` im Entwicklungsbaum)

Später Geladenes gewinnt.

### 3.2 build.conf

| Schlüssel | Default | Bedeutung |
|---|---|---|
| `SBRANCH_MODE` | `date` | Versions-String: `fixed` / `date` (`JJMMTTHH` + 3 Zeichen Branch, z. B. `26030610sta`) / `datetime` |
| `SBRANCH_FIXED` | | String für `fixed` |
| `MAKECLEAN` | `true` | einmal je Lauf `make clean` für jedes Target |
| `GITRESET` | `true` | Gluon, Module und Feeds hart auf den Remote-Stand |
| `MAKE_J_VAL` | `0` | make-Jobs, 0 = Kerne × `MAKE_J_FACTOR` |
| `MAKE_J_FACTOR` | `2` | |
| `BROKEN` | `1` | auch als broken markierte Geräte bauen |
| `AUTOUPDATER_ENABLED` | `true` | Branch kommt aus Feld 1 der Sites-Datei |
| `VERBOSE_BUILD` | `true` | `V=s`, volles Log |
| `BUILD_LOG` | `false` | zusätzlich Gluons eigene Logs |
| `BUILD_LOG_TIMESTAMPS` | `true` | `[HH:MM:SS]` vor jeder Zeile (braucht gawk) |
| `GLUON_SITE_VERSION` | Datum | Versionsstempel der site.conf |
| `GLUONDEVICES` | leer | leer = alle Geräte, sonst Liste |
| `SIGNKEY_FILE` | | Schlüssel unter `buildkeys/` |
| `BUILD_ORDER` | `domain` | seriell: `domain` (alle Targets einer Domain) oder `target` (alle Domains eines Targets) |
| `BUILD_TIMES_FILE` | `build-times.csv` | CSV je Bauschritt, wird angehängt |
| `WORKERS` | `1` | Zahl gleichzeitiger Targets; `auto` = Empfehlung des letzten Laufs |
| `WORKER_START_DELAY` | `60` | Sekunden Versatz beim Hochfahren der Worker |
| `WORKERS_AUTO_START` | `3` | Startwert für `auto` ohne Empfehlung |
| `METRICS` | `true` | Collector sampelt Last, Empfehlung für den nächsten Lauf |
| `SPACE_CHECK` | `true` | Platzschätzung vor dem Lauf mit Rückfall |
| `SPACE_UNIT_MB` | `250` | je Domain × Target |
| `SPACE_TARGET_MB` | `50` | je Target einmal (opkg-Feeds) |
| `SPACE_WORKER_BASE_MB` | `3000` | je Worker, upperdir erste Domain |
| `SPACE_WORKER_DOMAIN_MB` | `200` | je Worker und weitere Domain |
| `SPACE_RESERVE_MB` | `20480` | wird nicht verplant |
| `DISK_FULL_MB` | `1024` | darunter nennt ein Abbruch die volle Platte als Ursache |
| `DATE_SUFFIX_FORMAT` | `+%s` | Name des Ausgabeverzeichnisses |
| `SITE_COPY_EXCLUDES` | `*.old *.backup *~ *.nonworking` | nicht ins Site-Verzeichnis kopieren |

### 3.3 targets.conf

- `GLUON_TARGETS=( … )`, Reihenfolge = Baureihenfolge.
- Deaktivieren mit führendem `-` (bleibt sichtbar an seinem Platz).
- Kommentar hinter dem Target in derselben Zeile erlaubt.

### 3.4 domains.conf und Sites-Datei

- `SITES_FILE` – z. B. `sites.nefall.sta` (stable) oder `sites.nefall.bro` (broken).
- `DOMAINS_INCLUDE=( all )` oder eine Liste von **Template-Namen** (Feld 3,
  z. B. `21_dias-key`); `DOMAINS_EXCLUDE` gewinnt.
- Unbekannter Name → Abbruch (kein stilles Falschbauen).
- Reihenfolge der Domains kommt aus `DOMAINS_INCLUDE`, nicht aus der Sites-Datei.
- Sites-Datei: eine Zeile je Variante, **33 Felder**, Tab/Leerzeichen getrennt,
  `#`-Zeilen und Leerzeilen werden übersprungen.
  - Feld 1 `RELBRANCH` (stable/broken → Autoupdater-Branch, Manifest)
  - Feld 2 `GLUONBRANCH`, Feld 3 `TEMPLATE_NAME`, Feld 4 `SITE_CODE`, …
  - key- und nokeys-Variante teilen den `SITE_CODE`, unterscheiden sich im
    Template-Namen.
- Templates: `templates/<name>` sind Symlink-Ketten, die in `templates/common/` enden
  (`site.conf`, `site.mk`, `modules`, `image-customization.lua`, `prepare.sh`,
  `i18n/`). Platzhalter wie `SITECODE`, `DOMAINHASH` ersetzt build.sh.

---

## 4. Ablauf eines Laufs

### 4.1 Start

1. Optionen trennen, cwd prüfen, die drei Konfigurationen laden
2. `resolve_workers` (`auto` → Zahl), bei `WORKERS` ≥ 2 → `BUILD_ORDER=parallel`
3. `preflight_check` – **alle** Mängel auf einmal, in zwei Sorten:
   - **für den Bau nötig → Abbruch:** git make patch sed grep awk find xargs
     cp rsync sort tee date stat mktemp gzip sha256sum getconf sync df tail,
     `/usr/bin/ecdsasign` (Paket ecdsautils), Signaturschlüssel lesbar
   - **nur für Zugaben → fette Warnung, Lauf geht weiter:**
     - Parallelbetrieb (unshare, setsid, flock, bash ≥ 5.1, **Selbsttest** mit
       echtem rootless Overlay-Mount, siehe 7.9) → seriell mit einem Worker
       und der konfigurierten `BUILD_ORDER`
     - python3 → ohne Collector (`METRICS=false`)
   - Jeder solche Rückfall steht am Ende des Laufs noch einmal im Log
     („Dieser Lauf lief NICHT wie konfiguriert“), wie auch der Rückfall der
     Platzprüfung
4. `tests/check-site-conf.sh --optional` – Lua-Syntax von site.conf und
   image-customization.lua (ohne Lua nur Warnung)
5. SBRANCH bestimmen, Sites-Datei parsen, Targets auflösen
6. `prepare_run_state` – neuer Lauf / `--resume` / `--restart`
7. `space_check` – reicht der Platz? sonst weniger Worker oder seriell
8. `generate_all_site_configs` – je Domain `assembled/<template>/<code>/`
   aus dem Template, Platzhalter ersetzt (**räumt `assembled/` jedes Mal**)
9. `build_all_images`

### 4.2 prepare (einmal je Lauf, bzw. einmal je golden tree)

- `GITRESET`: Gluon `reset --hard origin/<branch>`, Module `reset --hard` +
  `clean -fd` (ohne `-x`: dl/, build_dir/, staging_dir/ bleiben)
- `prepare.sh pre-update` – Patches, die `make update` anwenden soll
- `make update` – OpenWrt und Feeds holen und patchen
- `MAKECLEAN`: `make clean GLUON_TARGET=…` für jedes Target
  (löscht `build_dir/target-*`, `staging_dir/target-*`, `bin/`; Toolchain bleibt)
- `prepare.sh post-update` – Patches auf openwrt/ und Gluon-Pakete
  (`patches/*.sh` über `lib-patch.sh`, idempotent über Marker)
- Quellen herunterladen
- Log: `assembled/prepare.log`, später in jedes Site-Verzeichnis kopiert

### 4.3 Bauschritt (Domain × Target)

- `make GLUON_TARGET=<t> V=s -j <n> --output-sync=recurse` mit
  - `GLUON_SITEDIR=assembled/<template>/<code>`
  - `GLUON_IMAGEDIR=images/running/<template>/<code>`
  - `GLUON_PACKAGEDIR=images/running/packages`
  - `GLUON_AUTOUPDATER_BRANCH=<RELBRANCH>`, `BROKEN`, `GLUON_SITE_VERSION`, ggf. `GLUON_DEVICES`
- opkg-Feeds nach `images/running/opkg-<gluon>/gluon-<sbranch>/<target>/`
- Log während des Schritts: `assembled/<template>/<code>/build-<target>.log`
- nach Erfolg: Log **sofort gepackt** nach `…/site/build-<target>.log.gz`,
  dann Zustand `build` vermerkt, Bauzeit notiert
- Seriell nach `BUILD_ORDER`: `domain` = Targets innen, `target` = Domains innen

### 4.4 Abschluss (finalize, je Domain)

- `make manifest` → `sysupgrade/<RELBRANCH>.manifest`
- `esign` signiert das Manifest (`/usr/bin/ecdsasign`)
- Site-Konfiguration, build.sh, die drei Konfigurationen, prepare.log ins
  Site-Verzeichnis
- `build-info.txt` (Herkunft, siehe 6)
- `build.log.gz` aus den Target-Logs (Targetreihenfolge) + Finalize-Log,
  Einzelteile erst nach dem Zustand `finalize` weg
- Seriell mit `BUILD_ORDER=domain`: direkt nach der Domain; sonst am Ende

### 4.5 Ende des Laufs

- Collector stoppen, Empfehlung übernehmen (nur bei Erfolg)
- `compress_build_logs` – Rückfallebene für ungepackte Alt-Logs
- Zustandsdatei und Statusverzeichnis löschen
- `images/running` → `images/images-<epoch>`
- Kasten mit den Eckdaten als Letztes im Log:

  ```
  ==============================================================================
   Lauf     26091021bro -> images/images-1789067658  (parallel, 6 Worker)
   Dauer    2 h 04 min  (prepare 21 min, je Domain im Mittel 20 min)
   Umfang   5 Domains x 6 Targets = 30 Bauschritte
   Worker   4.6 Erl von 6  (Parallelphase 41 min, 24 Bauschritte)
   Images   … (sysupgrade …, factory …, other …)
   Groesse  …: Images …, Pakete …, opkg …, Logs …
   Platte   … GB frei unter <Checkout>
  ==============================================================================
  ```

- darunter, falls der Lauf nicht wie konfiguriert lief (seriell statt
  parallel, weniger Worker, ohne Metriken), noch einmal die fette Warnung

---

## 5. Zustand, Abbruch, Resume

- Zustandsdatei `images/running/.build-state`:
  - Kopf: `sbranch`, `date_suffix`, `site_version`, `fingerprint`, `started`
  - danach je erledigtem Schritt eine Zeile `build <template> <code> <target>`
    bzw. `finalize <template> <code> -` (O_APPEND, mehrere Worker gleichzeitig ok)
- Fingerabdruck des Laufs über: BUILD_ORDER, Targets, Domains, alle
  Konfigurationen inkl. `build.local.conf`, Sites-Datei, `templates/` und
  `patches/` (sha256). Weicht er bei `--resume` ab → Abbruch, denn eine
  Fortsetzung mit anderen Eingaben ist keine.
- `--resume` übernimmt SBRANCH, Ausgabeverzeichnis und Site-Version aus der
  Zustandsdatei – ein Lauf, **ein** Release-String.
- Was einen Abbruch überlebt:

| Was | überlebt? |
|---|---|
| Images fertiger Schritte | ja (`images/running`) |
| Logs fertiger Target-Schritte | ja, gepackt im Site-Verzeichnis |
| `build.log.gz` fertiger Domains | ja |
| Log des abgebrochenen / gescheiterten Schritts | nein (`assembled/` wird geräumt) |
| Bauzeiten je Domain | ja (`images/running/.site-seconds`) |

- Abbruch per Strg-C / TERM: EXIT-Trap schreibt `run_end` in die Zeiten-CSV,
  beendet Collector und Worker (TERM, nach 10 s KILL, ganze Prozessgruppen).
- Bei `df` unter `DISK_FULL_MB` nennt der Abbruch die volle Platte ausdrücklich.

---

## 6. Ausgabe und Logs

```
images/
  running/                          während des Laufs
    .build-state                    Zustand (5)
    .site-seconds                   Bauzeit je Domain
    .status/<main|target>           Phase je Prozess (7.5)
    packages/                       Gluon-Pakete
    opkg-2023.2.x/gluon-<sbranch>/<target>/<sub>/   opkg-Feeds
    <template>/<code>/
      sysupgrade/  factory/  other/ Images, Manifest
      site/                         Site-Konfig, build.sh, Konfigs,
                                    prepare.log, build-info.txt, build.log.gz
  images-<epoch>/                   fertiger Lauf
assembled/                          erzeugte Site-Konfigs, Roh-Logs laufender Schritte
.overlays/                          Parallelbetrieb: Worker-Overlays, golden.fingerprint
metrics/                            Collector: <lauf>.csv, empfehlung.txt
build-times.csv                     Zeiten aller Läufe
```

| Datei | Inhalt |
|---|---|
| `site/build.log.gz` | komplettes Log der Domain, ein gzip-Member, `zless`/`zgrep` |
| `site/build-<t>.log.gz` | nur während des Laufs: fertige Targets vor dem Abschluss |
| `site/prepare.log` | Patch- und Update-Protokoll |
| `site/build-info.txt` | Release, Domain, Bauzeit der Domain, Lauf von–bis, Host, Aufruf, Commits von Firmware-Repo, Gluon und Modulen (Soll vs. Ist) |
| `build-times.csv` | `run_id,timestamp,epoch,build_order,phase,template,site_code,target,seconds,note`; Phasen `run_start`, `prepare`, `build`, `finalize`, `run_end` |
| `.overlays/<target>.log` | Ausgabe eines Workers |
| `long-server-task.log` | Hauptlog beim Start über den Wrapper |

- Kontrolle eines Laufs: Zahl der `build`-Zeilen je `run_id` gegen `steps`
  aus `run_start`; ohne `run_end` wurde hart abgeschossen.

---

## 7. Parallelbetrieb

### 7.1 Idee

- Ein Imagebau lastet die Maschine schlecht aus (8 % in Folgedomains, siehe 8.3),
  `make -j` wirkt nur **innerhalb** eines Targets.
- Also mehrere Targets gleichzeitig, jedes in einem **eigenen Overlay** über
  einem gemeinsamen, durchgebauten Baum.
- Parallel über die **Target-Achse**, nicht über Domains:
  - Targets teilen keinen Schreibpfad (bin/, staging_dir, tmp)
  - Overlay-Delta gehört dem Target: 2,8 GB + 0,2 GB je weitere Domain, statt 2,8 GB je Domain × Target
  - `.config` wird 22-mal statt tausendfach umgeschrieben
- Einschalten: `WORKERS=6` (oder `auto`) in `build.local.conf`.
  Ausschalten: `WORKERS=1` – seriell wie früher, ohne Overlay.

### 7.2 Ablauf

1. **golden tree** sicherstellen (7.3)
2. Warteschlange aller Targets; bis zu `WORKERS` gleichzeitig,
   Start im Abstand von `WORKER_START_DELAY`
3. Jeder Worker: **ein Target über alle Domains**, in seinem Overlay
4. Worker fertig → Overlay verwerfen, nächstes Target starten
5. Alle fertig → Abschluss aller Domains seriell im Hauptprozess (4.4)

- `BUILD_ORDER` aus der Konfiguration gilt hier nicht (intern `parallel`);
  sie greift wieder beim Rückfall auf seriell.

### 7.3 golden tree

- Der normale `gluon/`-Baum, einmal vollständig durchgebaut:
  prepare mit **erzwungenem** `GITRESET` + `MAKECLEAN`, dann Domain 1 seriell
  über alle Targets direkt im Baum.
- Danach nur noch gelesen (lowerdir aller Overlays).
- Fingerabdruck in `.overlays/golden.fingerprint`, gebildet aus den
  **Eingaben** (nicht über den Baum):
  - Gluon-Commit `origin/<branch>`
  - Targets (sortiert), `GLUONDEVICES`, `BROKEN`
  - gcc- und libc-Version
  - `patches/` und `templates/common/` (sha256, ohne Editor-Reste)
- Passt der Fingerabdruck → prepare entfällt komplett, der Baum bleibt unberührt.
- Passt er nicht → Neuaufbau. Datei wird vorher gelöscht, ein abgebrochener
  Aufbau gilt also nie als gültig.
- Serieller Lauf mit `MAKECLEAN` oder `GITRESET` verwirft den Fingerabdruck
  ebenfalls (der Baum ist danach ein anderer).

### 7.4 Isolation eines Workers (rootless)

```
build.sh (Hauptprozess, eigene UID)
 └─ setsid unshare -Urm scripts/ovl-enter.sh …        eigene Prozessgruppe,
     │                                                 User+Mount-Namespace, UID 0 darin
     ├─ mount --bind gluon  .overlays/<t>/lower         golden tree als lowerdir greifbar
     ├─ mount -t overlay … userxattr  auf gluon/        am ORIGINALPFAD
     └─ unshare -U --map-user=<uid> build.sh --worker=<t>   wieder eigene UID
```

- **Originalpfad**: OpenWrt schreibt absolute Pfade in `.prepared<hash>`;
  unter anderem Pfad würde alles neu gebaut.
- **eigene UID**: OpenWrt verweigert Builds als root.
- **userxattr**: Whiteouts ohne root in `user.*`-Attributen (Kernel ≥ 5.11).
- **Kernel-overlayfs, nicht fuse-overlayfs**: OpenWrt macht `rm -rf` und direkt
  danach `cp` an denselben Ort, fuse-overlayfs scheitert dort mit „File exists“.
- Mount lebt nur im Namespace – kein umount, Hauptprozess und andere Worker
  sehen den golden tree unverändert.
- Worker liest seinen Kontext (SBRANCH, Ausgabeverzeichnis, Site-Version) aus
  der Zustandsdatei, `BUILD_RUN_ID` aus der Umgebung.
- Kein root, kein sudo, kein Docker.

### 7.5 Phasen-Signale

- `images/running/.status/<main|target>`: `phase`, `target`, `domain`, `seit`, `pid`
- atomar geschrieben (tmp + mv)
- Phasen: `prepare`, `golden`, `build`, `finalize`
- Nutzen: Collector ordnet jede Lastprobe einer Phase zu; zum Mitlesen:
  `grep -H phase images/running/.status/*`

### 7.6 Collector und WORKERS=auto

- `scripts/buildcollect.py` läuft neben dem Lauf, 1 Probe/s:
  aktive Kerne, iowait, Plattenauslastung, Phase
- Ausgewertet **nur** Proben, in denen alle Worker im Imagebau belegt sind
  (Hoch-/Auslaufen sagt nichts über freie Kapazität), mindestens 300 Proben
- Regeln:

| Befund | Empfehlung |
|---|---|
| iowait > 1 Kern im Mittel oder Platte > 50 % | einen Worker weniger |
| CPU < 65 % | einen Worker mehr |
| sonst / zu wenig Proben | unverändert |

- gedämpft ±1 je Lauf, begrenzt auf 1 … Kerne/2
- dazu der **Worker-Verkehr in Erlang** (Einheit nach A. K. Erlang,
  Telefonvermittlung): die mittlere Zahl gleichzeitig belegter Worker über die
  Parallelphase, in `metrics/empfehlung.txt` als `worker_erlang`. Der Kasten am
  Ende des Laufs rechnet ihn unabhängig aus der Zeiten-CSV nach (Schrittzeit
  ÷ Wandzeit). wir-horst mit 6 Workern: erster Lauf 4,6 Erl, zweiter Lauf
  4,9 Erl (Kasten) und 5,0 Erl (Collector). Die beiden unabhängigen
  Rechenwege stimmen also überein
- **Die Empfehlung kennt die Zahl der Targets nicht.** Ein Worker baut ein
  Target über alle Domains, mehr gleichzeitige Worker als Targets gibt es
  also nicht. Der zweite horst-Lauf empfahl 7 Worker bei 6 Targets; das wirkt
  erst bei Läufen mit mehr Targets, etwa dem Volllauf mit 22
- nur ein **erfolgreicher** Lauf setzt `metrics/empfehlung.txt`
  (ein an Speichermangel gestorbener Lauf könnte sonst „mehr“ empfehlen)
- `WORKERS=auto` liest sie; ohne Datei `WORKERS_AUTO_START`
- auch seriell nützlich: zeigt vorab, ob sich Parallelbetrieb lohnt

### 7.7 Platzprüfung und Rückfall

- vor dem Lauf, nach Anlegen des Zustands
- Bedarf = Domains × Targets × `SPACE_UNIT_MB` + Targets × `SPACE_TARGET_MB`
  + Worker × (`SPACE_WORKER_BASE_MB` + Domains × `SPACE_WORKER_DOMAIN_MB`)
  + `SPACE_RESERVE_MB`
- bei `--resume` zählen nur noch nicht abgeschlossene Domains
- Ergebnis:
  - reicht für alle Worker → wie konfiguriert
  - reicht nur für weniger → so viele Worker wie passen, laut angekündigt
  - unter 2 → seriell mit der konfigurierten `BUILD_ORDER`
  - reicht nicht mal seriell → Abbruch sofort (kostet dann nichts)

### 7.8 Fehler und Abbruch

- Worker scheitert:
  - keine neuen Worker mehr, laufende werden zu Ende gebracht
  - letzte 25 Zeilen seines Logs im Hauptlog, bei voller Platte ausdrücklich genannt
  - sein Overlay bleibt zur Ansicht liegen
  - Abbruch; `--resume` baut nur das Fehlende
- Hauptprozess abgebrochen: jede Worker-Gruppe bekommt TERM, nach 10 s KILL
  (getestet: 80 Prozesse in 1 s weg)
- Übrig gebliebenes `.overlays/<t>/work/work` hat Modus 000 – build.sh räumt es
  beim nächsten Start selbst (`chmod` vor `rm`)

### 7.9 Voraussetzungen und Einrichtung

| Voraussetzung | Prüfen | Abhilfe |
|---|---|---|
| bash ≥ 5.1 (`wait -n -p`) | `bash --version` | |
| util-linux ≥ 2.38 (`unshare --map-user`) | `unshare --version` | |
| Kernel ≥ 5.11 | `uname -r` | |
| overlay-Modul | `grep overlay /proc/filesystems` | `sudo modprobe overlay`, dauerhaft: `echo overlay \| sudo tee /etc/modules-load.d/overlay.conf` |
| unprivilegierte User-Namespaces | `unshare -Urm true` | Ubuntu ≥ 23.10: `kernel.apparmor_restrict_unprivileged_userns=0` (sysctl.d) |
| setsid, flock | | util-linux |

- Die Vorabprüfung macht einen **echten** Overlay-Mount wie die Worker
  (inkl. `rm -rf` + Neuanlegen). Scheitert er oder fehlt ein Werkzeug, baut
  der Lauf **seriell** weiter, mit fetter Warnung samt Abhilfe am Anfang und
  Erinnerung am Ende - kein Abbruch.
- Die Einrichtung einmal als root, der Build-User selbst braucht keine Rechte.
- wir-horst: overlay-Modul war anfangs nicht geladen, jetzt über
  `modules-load.d` dauerhaft.

---

## 8. Messwerte und Abschätzungen

### 8.1 Kostenstruktur (wir-horst, seriell, 22 Targets)

| Posten | Zeit |
|---|---|
| Sockel (prepare mit Reset + Clean, Paketkompilierung) | ~170 min |
| erste Domain gesamt | **264 min** |
| jede weitere Domain | **93–95 min** |
| Images je Domain | 448 (306 sysupgrade, 124 factory, 18 other) |
| je Image | ~12,6 s |

- `make clean` nur einmal je Lauf – „zu viele make clean“ trifft nicht zu.
- Domainwechsel kompiliert **kein** Paket (nur `gluon-site` hängt an der Site).
- Domainwechsel, gemessen an ramips-mt7621:

| Anteil | Zeit |
|---|---|
| `target/linux/install` (Images) | 37,6 s |
| `target/linux/compile` (Kernel-Recheck ohne Änderung) | 21,4 s |
| `package/kernel/linux/compile` | 4,3 s |
| übrige Pakete zusammen | ~5 s |

### 8.2 Hosts

| | wir-horst | lokaler Messplatz |
|---|---|---|
| CPU | Xeon E5-2698 v4, KVM-Gast 2×18 vCPU, numa | Ryzen 9 5950X, 32 Threads (WSL2) |
| RAM | 118 GB | 31 GB |
| Platte | virtio-scsi-single, iothread, ZFS-Mirror 2× PM983, ext4 im Gast | NVMe |

### 8.3 Auslastung (wir-horst, seriell)

| Phase | aktive Kerne (Mittel) | Median | Auslastung | Platte |
|---|---|---|---|---|
| prepare | 1,1 von 36 | | 3 % | IOPS-Spitzen bis 12.400 |
| erste Domain | 14,4 | 5,6 | 40 % | Schreiben bis 1599 MB/s, %util p95 100 |
| Folgedomain | | 1,3 | **8 %** | |

- **bimodal**: lange serielle Strecken, kurze Vollastphasen → deshalb
  versetzter Worker-Start.
- Engpass ist **Parallelität, nicht IO** (lokal iowait ~0, 130 Schreib-IOPS).
- Mehr Kerne helfen seriell nicht, die serielle Arbeit bleibt gleich lang.

### 8.4 Overlay, Docker, Host (lokal, ramips-mt7621)

| Variante | Domain 2 | Lauf |
|---|---|---|
| Host direkt (2 Geräte) | 86 s | 339 s |
| Docker direkt (2 Geräte) | 77 s | 268 s |
| Docker + Kernel-overlayfs (2 Geräte) | 79 s | 279 s |
| Host + fuse-overlayfs | gescheitert | |
| Host direkt, **alle** Geräte | 219–241 s | |
| Overlay, **alle** Geräte | 224–238 s | |

- Overlay-Overhead bei vollem Gerätesatz **nicht messbar**.
- Overlay mounten 0,00 s, verwerfen ~3 s (3 GB, ~70.000 Dateien).
- Docker ~10 % schneller als Host – ungeklärt (Vermutung: andere
  Host-Werkzeuge), keine Grundlage für eine Umstellung.
- x86-64 nicht gemessen (fast alle Targets sind crosscompiled).

### 8.5 Platzbedarf

| Posten | Größe |
|---|---|
| je Domain × Target | ~250 MB (Images ~185, Pakete ~35, Log gepackt ~1, Luft) |
| gemessen, 6 große Targets (8.7, Lauf 2) | **~430 MB**: 23,3 GB für 54 Bauschritte (Images 21,8 GB, opkg 1,3 GB, Pakete 216 MB, Logs 19 MB) |
| upperdir je Worker | 2,8 GB erste Domain, +0,2 GB je weitere |
| golden tree | einmal, gemeinsam (lowerdir) |
| Beispiel 96 Varianten × 22 Targets | ~530 GB Ausgabe |
| Beispiel 6 Worker × 86 Domains | ~6 × 20 GB upperdir, zeitweise |

- `SPACE_UNIT_MB` ist ein Mittel über alle 22 Targets. Ein Lauf nur mit den
  großen Targets (x86-64, mediatek-*, ramips-mt7621) braucht je Schritt fast
  das Doppelte. Die Platzprüfung unterschätzt ihn also und fängt das nur über
  `SPACE_RESERVE_MB` ab. Genauer wäre eine Größe je Target (offen, Kapitel 9).

### 8.6 Laufzeit-Abschätzung

- seriell: **170 + D × 94 min**
- parallel: **264 + (D − 1) × 94 / F min** (golden tree + Rest verteilt)
- **F ist nicht W.** Gemessen auf wir-horst mit W = 6 (8.7): **F = 2,7–2,8**.
  Ein Schritt dauert unter Last 1,7× so lange wie seriell, und im Mittel sind
  4,6–4,9 der 6 Worker belegt: F ≈ Erl ÷ 1,7.
- Mit 22 Targets ist F eher größer: Die Warteschlange bleibt länger voll, der
  Auslauf ungleich großer Targets fällt weniger ins Gewicht. Obergrenze mit
  6 Workern, alle belegt: 6 ÷ 1,7 ≈ 3,5.

| Domains | seriell | parallel, W = 6, F = 2,8 (gemessen) | F = 3,5 (Obergrenze) |
|---|---|---|---|
| 4 (broken) | ~9,1 h | ~6,1 h | ~5,7 h |
| 43 | ~70 h | ~28 h | ~23 h |
| 86 (stable voll) | ~138 h (5,7 Tage) | ~52 h | ~42 h |

- Bei wenigen Domains dominiert der golden tree (4,4 h), der Parallelbetrieb
  zahlt sich erst ab vielen Domains richtig aus.
- Passt der golden-Fingerabdruck beim nächsten Lauf, entfällt der Neuaufbau –
  dann sind es nur noch **D × 94 / F** plus Abschluss (Beispiel 86 Domains:
  ~48 h mit F = 2,8, ~38 h mit F = 3,5).
- Die frühere Schätzung mit F = W (86 Domains ~27 h) war zu optimistisch.

### 8.7 Parallelläufe auf wir-horst (gemessen)

#### Lauf 1 (10.09.2026)

`domains-broken.conf` mit 5 Domains × 6 Targets (ath79-generic, ath79-nand,
mediatek-filogic, mediatek-mt7622, ramips-mt7621, x86-64), `WORKERS=6`,
Stand `111be7c`. Vergleich: serieller Lauf mit denselben 6 Targets am selben
Tag (3 Domains, 143 min).

| Phase | parallel | seriell (Vergleich / Hochrechnung) |
|---|---|---|
| prepare (mit Reset + Clean) | 14 min | ~14 min |
| erste Domain (golden tree, 6 Targets nacheinander) | 66 min | 65 min |
| 4 Folgedomains (24 Bauschritte) | **41 min** Wandzeit | ~112 min (4 × 27–29 min) |
| finalize, 5 Domains | 1 min | 1 min |
| **ganzer Lauf** | **124 min** | **~193 min** |

- Folgedomains **2,7× schneller**, ganzer Lauf 1,6× – bei nur 6 Targets
  dominiert der golden tree. Mit 22 Targets und vielen Domains wiegt er
  entsprechend weniger.
- Ein Bauschritt dauert unter Last im Mittel 475 s statt ~280 s seriell
  (1,7× langsamer), dafür laufen im Mittel 4,6 gleichzeitig (Schrittsumme
  190 min in 41 min).
- Die Worker brauchten je 30–35 min (ein Target über 4 Domains, x86-64 am
  längsten). Der Startversatz (`WORKER_START_DELAY` 60 s × 5 Worker) kostet
  davon ~5 min – spürbar, wenn es kaum mehr Targets als Worker gibt.
- Collector: keine Auswertung, 0 von 6887 Proben galten als „alle Worker
  aktiv“ – Fehler, der Hauptprozess blieb auf Status „golden“ stehen
  (behoben in `1f2b3ae`).

#### Lauf 2 (11.09.2026, `26091100bro`)

`sites.nefall.bro`, 9 Domains × dieselben 6 Targets, `WORKERS=6`, Stand
`69eefea`. Die Werte stammen aus dem Kasten am Laufende und der Zeile des
Collectors.

| Phase | parallel | seriell (hochgerechnet wie Lauf 1) |
|---|---|---|
| prepare | 13 min | ~14 min |
| golden tree + finalize | ~71 min (Rest aus 163 − 13 − 79) | ~67 min |
| 8 Folgedomains (48 Bauschritte) | **79 min** Wandzeit | ~224 min (8 × 28 min) |
| **ganzer Lauf** | **163 min** (2 h 43 min) | **~305 min** |

- Folgedomains **2,8× schneller**, ganzer Lauf 1,9×.
- **Skaliert linear.** Doppelt so viele Folgeschritte wie in Lauf 1 (48 statt
  24) kosten fast genau doppelt so viel Wandzeit (79 statt 41 min, 9,9 statt
  10,3 min je Domain). Hochlaufen und Auslauf fallen weniger ins Gewicht.
- Worker: **4,9 Erl** (Kasten, aus der CSV) bzw. **5,0 Erl** (Collector, aus
  1-s-Proben) von 6, gegen 4,6 in Lauf 1. Schritt unter Last im Mittel
  ~480 s (4,9 × 79 min ÷ 48), also wieder 1,7× langsamer als seriell.
- Collector: 8513 Proben, davon 2632 (31 %) mit allen 6 Workern belegt. In
  diesen Proben: **CPU 46 %**, iowait 0,52 Kerne, Platte 11 % → Empfehlung
  **7 Worker**. Weder Platte noch CPU sind der Engpass.
- Warum ein Schritt trotzdem 1,7× langsamer wird, ist offen (Kapitel 9).
  CPU und Platte zeigen es nicht. Denkbar sind kurze gleichzeitige
  Plattenspitzen, die im Mittel verschwinden, sowie Speicherbandbreite, NUMA
  oder ein niedrigerer Turbo-Takt bei vielen aktiven Kernen.
- Ausgabe: **2556 Images** (284 je Domain: 192 sysupgrade, 89 factory,
  3 other), **23,3 GB**. Das sind ~430 MB je Bauschritt, deutlich mehr als
  `SPACE_UNIT_MB` (8.5). Danach 780 GB frei.
- **Der golden tree ist jetzt der größte Posten**: 71 von 163 min (44 %),
  seriell über die 6 Targets.

### 8.8 Multidomain (Einordnung)

- Kosten hängen an der **Zahl der Images**, nicht an der Zahl der Domains darin.
- Gewinn nur, wenn Varianten wegfallen: eine setupmode-Firmware statt 43,
  key-Firmwares bleiben einzeln.
- stable: 86 → 44 Varianten (~66 h seriell gespart); broken (> 90 % key):
  praktisch kein Gewinn.
- Offen: passt ein Image mit 43 Domain-Konfigurationen auf 4-MB-Geräte?

---

## 9. Grenzen und offene Punkte

- Parallelbetrieb auf wir-horst: zwei Läufe erfolgreich (8.7, 10. und
  11.09.2026), golden-Neuaufbau und 6 Worker gleichzeitig im echten Bau.
- **Größter Posten bei wenigen Domains ist jetzt der golden tree** (Lauf 2:
  44 % der Laufzeit, seriell über die Targets). Nächster Hebel, falls es sich
  lohnt: dessen Targets verteilen. Das ist nicht trivial, weil alle in
  denselben lowerdir bauen.
- Ein Bauschritt wird unter Last 1,7× langsamer, obwohl CPU (46 %) und Platte
  (11 %) Luft zeigen. Die Ursache ist nicht gemessen.
- `WORKERS`-Empfehlung ohne Blick auf die Zahl der Targets (7.6).
- `SPACE_UNIT_MB` als Mittel über alle Targets unterschätzt Läufe mit großen
  Targets (8.5). Eine Größe je Target wäre genauer.
- Log eines gescheiterten Schritts geht beim `--resume` verloren
  (liegt ungepackt in `assembled/`).
- Abschluss aller Domains erst am Ende des Parallellaufs – die Site-Verzeichnisse
  (Manifest, `build.log.gz`) erscheinen spät, die Target-Logs aber schon früher.
- Laufzeit-Abschätzung 8.6 beruht auf dem gemessenen Faktor F mit 6 Targets.
  Für den Volllauf mit 22 Targets liefert erst ein echter Lauf den Wert.
