#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Test fuer die Weiche GOLDEN_COMPILE in build_parallel aus build.sh: die
# Funktion wird herausgeloest, prepare, Bauschritte und Worker sind Attrappen,
# die nur protokollieren. Geprueft wird, wann prepare und golden laufen und
# was im Fingerabdruck steht.
#
#   tests/golden-compile.sh        braucht bash
set -o errexit -o nounset -o pipefail

HIER="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

sed -n '/^build_parallel ()$/,/^}$/p' "$HIER/../build.sh" > "$TMP/fn.sh"
grep -q '^build_parallel ()' "$TMP/fn.sh" || { echo "build_parallel nicht gefunden"; exit 1; }

FEHLER=0
# lauf name modus fp-vorher erwartetes-protokoll erwarteter-fp
lauf () {
  local NAME="$1" MODUS="$2" VORHER="$3" ERW_LOG="$4" ERW_FP="$5"
  local D="$TMP/$RANDOM"; mkdir -p "$D"
  [ "$VORHER" = "-" ] || echo "$VORHER" > "$D/golden.fingerprint"
  local LOG FP
  # Protokoll der Attrappen ueber fd 3, die Meldungen von build_parallel weg
  LOG="$(bash -c '
    set -o errexit -o nounset -o pipefail
    . "'"$TMP"'/fn.sh"
    OVL_DIR="'"$D"'"; GOLDEN_FP_FILE="$OVL_DIR/golden.fingerprint"
    GOLDEN_COMPILE="'"$MODUS"'"; BUILD_PHASE=build
    ALL_SITE_GLUON_BRANCHES=(main); BUILD_TARGETS=(t1 t2)
    golden_fingerprint () { echo abc123; }
    run_prepare () { printf "prepare(reset=%s,clean=%s) " "$GITRESET" "$MAKECLEAN" >&3; }
    run_build_step () { printf "golden:%s/%s:%s " "$1" "$2" "$BUILD_PHASE" >&3; }
    status_clear () { :; }
    run_parallel () { printf "parallel" >&3; }
    build_parallel >/dev/null
  ' 3>&1)"
  FP="$(cat "$D/golden.fingerprint" 2>/dev/null || echo -)"
  if [ "$LOG" = "$ERW_LOG" ] && [ "$FP" = "$ERW_FP" ]; then
    echo "OK      $NAME"
  else
    echo "FEHLER  $NAME"
    echo "        Ablauf     ist: $LOG"; echo "               erwartet: $ERW_LOG"
    echo "        Fingerabdr ist: $FP";  echo "               erwartet: $ERW_FP"
    FEHLER=$(( FEHLER + 1 ))
  fi
}

G="prepare(reset=true,clean=true) golden:0/0:golden golden:0/1:golden parallel"
P="prepare(reset=true,clean=true) parallel"

lauf "golden, kein Baum"                 true  -                 "$G"       "abc123"
lauf "golden, Baum aktuell"              true  "abc123"          "parallel" "abc123"
lauf "golden, Baum veraltet"             true  "alt999"          "$G"       "abc123"
lauf "golden, nur vorbereitet -> neu"    true  "abc123 prepared" "$G"       "abc123"
lauf "je Target, kein Baum"              false -                 "$P"       "abc123 prepared"
lauf "je Target, vorbereitet aktuell"    false "abc123 prepared" "parallel" "abc123 prepared"
lauf "je Target, durchgebaut aktuell"    false "abc123"          "parallel" "abc123"
lauf "je Target, Baum veraltet"          false "alt999"          "$P"       "abc123 prepared"
lauf "je Target, alt vorbereitet"        false "alt999 prepared" "$P"       "abc123 prepared"

if [ "$FEHLER" -ne 0 ]; then echo "$FEHLER Fehler"; exit 1; fi
echo "alle Faelle bestanden"
