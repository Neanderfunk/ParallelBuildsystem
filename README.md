# ParallelBuildsystem

*A build system for Gluon firmware with many site variants: one `build.sh`
that builds every domain × target combination, reuses a "golden tree" and
parallelises across targets with rootless overlayfs workers, signs the
manifests and records the provenance of every image. Used by Freifunk im
Neanderland (Neanderfunk) for Gluon v2023.2.x. A measurement report in English
is in [`docs/parallel-builds/`](docs/parallel-builds/).*

`build.sh` baut für jede Domain (Site-Variante) und jedes Target die
Gluon-Images, signiert die Manifeste mit dem Buildbot-Schlüssel und legt neben
jedem Ergebnis ab, woraus es entstanden ist (`site/build-info.txt`). Einmal je
Lauf entsteht ein **golden tree**; die Targets bauen danach parallel in je
einem Kernel-overlayfs darüber, ohne root und ohne Docker.

Die ausführliche Betreiberdoku mit allen Optionen, Dateien und Fallen steht in
[`docs/build-sh.md`](docs/build-sh.md).

## Aufbau: Buildsystem und Konfiguration getrennt

Dieses Repo enthält nur das Buildsystem. Was eine Community ausmacht, liegt
in einem eigenen **Konfigurationsverzeichnis**, aus dem `build.sh` aufgerufen
wird. Dort entstehen auch der Gluon-Baum und die Images:

```
community-config/            <- Arbeitsverzeichnis, eigenes Repo
  build.conf                    wie gebaut wird
  targets.conf                  welche Targets
  domains.conf                  welche Domains aus der sites-Datei
  sites.<name>                  eine Zeile je Domain und Variante
  templates/<name>/             Site-Templates (site.conf, modules,
                                image-customization.lua, prepare.sh, i18n/)
  patches/                      eigene Patches, von prepare.sh angewendet
  buildkeys/                    Signier- und SSH-Schlüssel
  gluon/ images/ assembled/     entstehen beim Bauen
ParallelBuildsystem/         <- dieses Repo, irgendwo daneben
```

```
cd community-config
../ParallelBuildsystem/build.sh --detach build.conf targets.conf domains.conf
```

`--detach` startet den Lauf in einer tmux-Sitzung und verbindet sofort; ein
Lauf dauert Stunden und soll nicht an der SSH-Sitzung hängen.

Ein vollständiges, im Betrieb genutztes Konfigurationsverzeichnis ist
[Neanderfunk/FirmwareConfigs](https://github.com/Neanderfunk/FirmwareConfigs):
Templates mit Platzhaltern, `prepare.sh` in zwei Phasen, Patch-Repos über die
Pin-Datei `templates/common/patchrepos`. In [`examples/`](examples/) liegen die
drei Konfigurationsdateien und eine sites-Datei mit einer Domain als
Ausgangspunkt.

## Voraussetzungen

- Die Abhängigkeiten von Gluon (siehe Gluons „Getting Started“), dazu
  `ecdsautils` (signiert die Manifeste), `lua5.1`, `python3` (Collector,
  optional), `rsync`, `tmux` oder `screen` für `--detach`.
- Für OpenWrt 23.05 ein Host-Compiler bis GCC 13, etwa Debian Bookworm.
- Parallelbetrieb braucht rootless Kernel-overlayfs: Linux ≥ 5.11,
  util-linux ≥ 2.38, bash ≥ 5.1; unter Ubuntu ≥ 23.10 zusätzlich
  `kernel.apparmor_restrict_unprivileged_userns=0`. Fehlt es, baut `build.sh`
  seriell und sagt das laut.
- `build.sh` prüft das alles vorab und nennt fehlende Teile auf einmal.

## Bekannte Grenze: erster Bau eines Targets

Der erste Bau eines Targets (golden tree, Toolchain und Host-Werkzeuge noch
nicht gebaut) läuft mit voller Parallelität (`make -j`). OpenWrt ist dabei
nicht frei von Race Conditions: Ab und zu scheitert ein Paket, weil ein
anderer Job dieselbe Datei in `staging_dir/` gerade schreibt. Beobachtet am
27.09.2026 unter Gluon 2025.1 bei x86-64: das Paket `perl` (kommt über
Gluons `ALL_NONSHARED`) fand `ExtUtils/Liblist/Kid.pm` des Host-perl halb
geschrieben vor.

Abhilfe: den Lauf mit `--resume` fortsetzen, der zweite Versuch findet die
fertigen Dateien vor. Scheitert dasselbe Paket an derselben Stelle erneut,
ist es kein Zufall mehr und gehört untersucht.

Das ist ein bewusster Tradeoff: Ein erster Bau mit `-j1` wäre stabiler, aber
um ein Vielfaches langsamer. Spätere Bauschritte auf dem fertigen golden tree
betrifft das kaum, dort ist die Toolchain schon da.

## Herkunft und Lizenz

Herausgelöst aus Neanderfunk/FirmwareConfigs (bis September 2026
Neanderfunk/firmware) mit der vollständigen Git-Geschichte der betroffenen
Dateien; die Autorenschaft steht dort je Commit.

Lizenz: GNU AGPLv3 (siehe `LICENSE`), wie im Kopf von `build.sh`. Fremde
Teile: `esign` geht auf Gluons `contrib/sign.sh` zurück, `tests/site_config.lua`
enthält json4lua (Quelle im Dateikopf); für sie gilt die Lizenz ihrer Herkunft.
