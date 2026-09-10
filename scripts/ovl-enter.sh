#!/bin/bash
#
# ovl-enter.sh - betritt ein Overlay ueber dem golden tree und fuehrt dort
# einen Befehl als eigene UID aus.
#
#   unshare -Urm ovl-enter.sh <golden> <workerdir> <mountpunkt> <uid> <gid> <befehl> [arg ...]
#
# Muss mit "unshare -Urm" aufgerufen werden: es laeuft dann in einem eigenen
# User- und Mount-Namespace als dessen UID 0. Nur dort darf ein unprivilegierter
# Benutzer mounten. Weder root noch sudo noch Docker sind noetig.
#
# Ablauf:
#
#   1. Den golden tree an <workerdir>/lower binden. Das Overlay kann ihn dann
#      von dort als lowerdir lesen, obwohl es selbst an genau dem Pfad liegt,
#      unter dem der golden tree sonst zu sehen ist.
#   2. Kernel-overlayfs am <mountpunkt> - dem ORIGINALPFAD des Baums. OpenWrt
#      schreibt absolute Pfade in die .prepared<hash>-Signaturen, ein Baum unter
#      anderem Pfad gilt als fremd und wird komplett neu gebaut.
#   3. In einen zweiten User-Namespace wechseln, in dem die eigene UID wieder
#      sie selbst ist. OpenWrt verweigert Builds als root; die Mounts aus
#      Schritt 1 und 2 bleiben sichtbar, weil der Mount-Namespace geerbt wird.
#
# userxattr ist Pflicht: ohne root kann overlayfs seine Whiteouts nicht als
# Geraetedatei anlegen und legt sie in user.*-Attributen ab. Kernel ab 5.11.
#
# Warum Kernel-overlayfs und nicht fuse-overlayfs: OpenWrt macht in
# package/Makefile ein "rm -rf root.orig-<target>" gefolgt von einem
# "cp -fpR" an denselben Ort. Auf fuse-overlayfs bleiben die Verzeichnisse aus
# dem lowerdir danach sichtbar, und cp bricht mit "File exists" ab.
#
# Der Mount lebt nur in diesem Namespace und verschwindet mit dem letzten
# Prozess darin - kein umount noetig, und der Hauptprozess wie jeder andere
# Worker sieht den golden tree unveraendert.

set -o errexit -o nounset -o pipefail

if (( $# < 6 )); then
  echo "Aufruf: unshare -Urm $0 <golden> <workerdir> <mountpunkt> <uid> <gid> <befehl> [arg ...]" >&2
  exit 2
fi

GOLDEN="$1" WORKERDIR="$2" MOUNTPUNKT="$3" ZIEL_UID="$4" ZIEL_GID="$5"
shift 5

if [ "$(id -u)" != 0 ]; then
  echo "ovl-enter.sh: nicht im Namespace als UID 0 - mit 'unshare -Urm' aufrufen." >&2
  exit 2
fi

mount --bind -- "$GOLDEN" "$WORKERDIR/lower"
mount -t overlay overlay \
  -o "lowerdir=$WORKERDIR/lower,upperdir=$WORKERDIR/upper,workdir=$WORKERDIR/work,userxattr" \
  -- "$MOUNTPUNKT"

exec unshare -U --map-user="$ZIEL_UID" --map-group="$ZIEL_GID" -- "$@"
