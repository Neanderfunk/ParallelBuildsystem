#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Test fuer release_name_check aus build.sh: die Funktion wird herausgeloest
# und gegen einen lokalen HTTP-Server mit nachgebautem Firmware-Server
# (Verzeichnisseiten mit absoluten Links, Manifeste) und einen
# Sandbox-Baum mit images/ und templates/ geprueft.
#
#   tests/release-name-check.sh        braucht bash, curl, python3
set -o errexit -o nounset -o pipefail

HIER="$(cd "$(dirname "$0")" && pwd)"
BUILD_SH="$HIER/../build.sh"
TMP="$(mktemp -d)"
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
SERVER_PID=""

# Funktion und abort aus build.sh holen
{
  sed -n '/^abort ()$/,/^}$/p' "$BUILD_SH"
  sed -n '/^release_name_check ()$/,/^}$/p' "$BUILD_SH"
} > "$TMP/fn.sh"
grep -q '^release_name_check ()' "$TMP/fn.sh" || { echo "release_name_check nicht gefunden"; exit 1; }

# Nachgebauter Firmware-Server: firmware/<zweig>/ mit Verzeichnisseite,
# <zweig>/<domain>/sysupgrade/<zweig>.manifest
W="$TMP/www"
manifest () {  # zweig domain release site
  mkdir -p "$W/firmware/$1/$2/sysupgrade"
  printf 'BRANCH=%s\nDATE=2026-11-03 23:06:15+01:00\nPRIORITY=0\n\n' "$1" > "$W/firmware/$1/$2/sysupgrade/$1.manifest"
  printf 'tp-link-tl-wdr3600-v1 %s %064d 7013188 gluon-%s-%s-tp-link-tl-wdr3600-v1-sysupgrade.bin\n' \
    "$3" 0 "$4" "$3" >> "$W/firmware/$1/$2/sysupgrade/$1.manifest"
  printf -- '---\n' >> "$W/firmware/$1/$2/sysupgrade/$1.manifest"
}
manifest stable 21_dias 26101610sta nef-21_dias
manifest stable 21_dias.key 26101610sta nef-21_dias
manifest broken 21_dias 26111701bro nef-21_dias
# ein Verzeichnis ohne Manifest (Server liefert dort eine HTML-Seite)
mkdir -p "$W/firmware/stable/99_leer/sysupgrade"
printf '<html>keine Datei</html>\n' > "$W/firmware/stable/99_leer/sysupgrade/stable.manifest"
for Z in stable broken experimental; do
  mkdir -p "$W/firmware/$Z"
  {
    echo '<html><a href="/">home</a><a href="/css/style.min.css?v=1.0">x</a>'
    for D in "$W/firmware/$Z"/*/; do
      [ -d "$D" ] || continue
      D="${D%/}"; echo "<a href=\"/firmware/$Z/${D##*/}\">${D##*/}</a>"
    done
    echo '</html>'
  } > "$W/firmware/$Z/index.html"
done

PORT=$(( 20000 + RANDOM % 20000 ))
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$W" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 50); do curl -fs "http://127.0.0.1:$PORT/firmware/stable/" >/dev/null && break; sleep 0.1; done

# Sandbox
S="$TMP/sandbox"
mkdir -p "$S/templates/21_dias" "$S/templates/multidomain" "$S/images"
echo "  site_code = 'METAPREFIX-DOMAINNR_SITESMALL'," > "$S/templates/21_dias/site.conf"
echo "  site_code = 'ffnef'," > "$S/templates/multidomain/site.conf"

FEHLER=0
lauf () {  # erwartung(ok|abbruch) name umgebung... -- skript
  local ERW="$1" NAME="$2"; shift 2
  local AUS RC
  set +o errexit
  AUS="$(env "$@" bash -c '
    set -o errexit -o nounset -o pipefail
    . "'"$TMP"'/fn.sh"
    SANDBOX_DIR="'"$S"'"
    RESUME="${T_RESUME:-false}"
    SBRANCH="$T_SBRANCH"
    SBRANCH_MODE="${T_MODE:-date}"
    SBRANCH_FROM_LOCAL="${T_LOCAL:-false}"
    RELEASE_CHECK_URL="${T_URL-http://127.0.0.1:'"$PORT"'/firmware}"
    RELEASE_CHECK_BRANCHES="stable broken experimental"
    if [ "${T_MULTI:-}" = 1 ]; then
      ALL_SITE_TEMPLATE_NAMES=(multidomain); ALL_SITE_CODES=(ffnef-multi)
      ALL_SITE_DOMAIN_NRS=(00); ALL_SITE_SITE_SMALLS=(x)
    else
      ALL_SITE_TEMPLATE_NAMES=(21_dias); ALL_SITE_CODES=(21_dias)
      ALL_SITE_DOMAIN_NRS=(21); ALL_SITE_SITE_SMALLS=(dias)
    fi
    ALL_SITE_SITE_BIGS=(X); ALL_SITE_FF_PREFIXS=(ff); ALL_SITE_META_PREFIXS=(nef)
    ALL_SITE_RELBRANCHES=("${T_REL:-stable}")
    release_name_check ath79-generic
    echo "NOTE=${RELEASE_REBUILD_NOTE:-}"
  ' 2>&1)"
  RC=$?
  set -o errexit
  local IST=ok; [ "$RC" -ne 0 ] && IST=abbruch
  if [ "$IST" = "$ERW" ]; then
    echo "OK      $NAME"
  else
    echo "FEHLER  $NAME (erwartet $ERW, war $IST)"; printf '%s\n' "$AUS" | sed 's/^/        /'
    FEHLER=$(( FEHLER + 1 ))
  fi
  LETZTE_AUSGABE="$AUS"
}

lauf ok      "neuer Name"                           T_SBRANCH=26111802sta
lauf abbruch "Name im veroeffentlichten stable"      T_SBRANCH=26101610sta
lauf abbruch "Name im veroeffentlichten broken"      T_SBRANCH=26111701bro
lauf ok      "--resume prueft nicht"                 T_SBRANCH=26101610sta T_RESUME=true
lauf abbruch "fixed aus build.local.conf, unbestaetigt" T_SBRANCH=26111802sta T_MODE=fixed T_LOCAL=true
lauf ok      "fixed aus build.local.conf, bestaetigt"   T_SBRANCH=26111802sta T_MODE=fixed T_LOCAL=true CONFIRM_SBRANCH_FIXED=26111802sta
lauf ok      "fixed aus build.conf"                  T_SBRANCH=26111802sta T_MODE=fixed
lauf ok      "Nachbau, gleiche Variante"             T_SBRANCH=26101610sta REBUILD_EXISTING_RELEASE=1
printf '%s\n' "$LETZTE_AUSGABE" | grep -q '^NOTE=Nachbau fuer bestehende Release 26101610sta, Targets: ath79-generic$' \
  && echo "OK      Nachbau-Notiz fuer den Bericht" || { echo "FEHLER  Nachbau-Notiz fehlt"; FEHLER=$(( FEHLER + 1 )); }
lauf abbruch "Nachbau, Multi mit Single-Namen"        T_SBRANCH=26101610sta REBUILD_EXISTING_RELEASE=1 T_MULTI=1
lauf abbruch "Nachbau, anderer Zweig"                 T_SBRANCH=26101610sta REBUILD_EXISTING_RELEASE=1 T_REL=broken
lauf abbruch "Server nicht erreichbar"                T_SBRANCH=26111802sta T_URL=http://127.0.0.1:1/firmware

# fertiger Lauf unter images/ zaehlt, images/running nicht
mkdir -p "$S/images/running/21_dias/sysupgrade"
touch "$S/images/running/21_dias/sysupgrade/gluon-nef-21_dias-26111803sta-x86-64-sysupgrade.img.gz"
lauf ok      "nur in images/running"                 T_SBRANCH=26111803sta T_URL=
mkdir -p "$S/images/images-2026-11-18/21_dias/sysupgrade"
touch "$S/images/images-2026-11-18/21_dias/sysupgrade/gluon-nef-21_dias-26111803sta-x86-64-sysupgrade.img.gz"
lauf abbruch "in einem fertigen Lauf unter images/"  T_SBRANCH=26111803sta T_URL=

if [ "$FEHLER" -ne 0 ]; then echo "$FEHLER Fehler"; exit 1; fi
echo "alle Faelle bestanden"
