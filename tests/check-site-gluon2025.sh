#!/bin/bash
#
# Prueft unsere site.conf gegen die check_site-Regeln eines Gluon-2025.1-Baums,
# ohne dafuer bauen zu muessen.
#
# Gluon prueft die site.conf normalerweise erst beim "make", im postinst jedes
# Pakets (siehe GluonCheckSite in package/gluon.mk). Das kostet einen halben
# Build. Hier laeuft dieselbe check-site.lua direkt auf dem Host: Lua 5.1
# genuegt, das fehlende jsonc aus libubox ist in tests/lib/ nachgebaut.
#
#   tests/check-site-gluon2025.sh <gluon-2025.1-baum> <assemblierte-site> [weitere-feeds...]
#
# Beispiel:
#   tests/check-site-gluon2025.sh ~/gluon-2025.1/gluon \
#       ~/gluon-testbuild/repo/assembled/21_dias/21_dias
#
# Wichtig: gemeldet werden auch Pakete, die wir gar nicht einsetzen - jede
# check_site.lua im Baum wird ausgefuehrt. Die Meldung "expected
# mesh_vpn.fastd.methods ..." heisst also nicht, dass etwas fehlt, sondern nur,
# dass fastd andere Angaben braeuchte. Erst die Liste der tatsaechlich
# ausgewaehlten Pakete macht daraus ein Urteil.

set -o errexit -o nounset -o pipefail

abort () { echo >&2 "Fehler: $*"; exit 1; }

(( $# >= 2 )) || abort "Aufruf: $0 <gluon-2025.1-baum> <assemblierte-site> [weitere-feed-verzeichnisse...]"

GLUON="$(cd "$1" && pwd)"; shift
SITE="$(cd "$1" && pwd)";  shift
SKRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

[ -f "$GLUON/package/gluon-core/luasrc/lib/gluon/check-site.lua" ] \
  || abort "\"$GLUON\" sieht nicht nach einem Gluon-Baum aus."
[ -f "$SITE/site.conf" ] || abort "In \"$SITE\" liegt keine site.conf."

LUA=""
for k in lua lua5.1; do command -v "$k" >/dev/null 2>&1 && { LUA="$k"; break; }; done
[ -n "$LUA" ] || abort "Kein Lua 5.1 gefunden (site_config.lua braucht setfenv, das es ab 5.2 nicht mehr gibt)."

ARBEIT="$(mktemp -d)"
trap 'rm -rf -- "$ARBEIT"' EXIT
mkdir -p "$ARBEIT/root/lib/gluon" "$ARBEIT/lua/gluon"

cp "$SKRIPT_DIR/lib/jsonc.lua"                                              "$ARBEIT/"
cp "$GLUON/package/gluon-core/luasrc/lib/gluon/check-site.lua"              "$ARBEIT/root/lib/gluon/"
cp "$GLUON/package/gluon-core/luasrc/usr/lib/lua/gluon/validator.lua"       "$ARBEIT/lua/gluon/"

# site.conf -> site.json, mit Gluons eigenem Wandler statt eines Nachbaus
( cd "$GLUON" && GLUON_SITEDIR="$SITE" GLUON_SITE_CONFIG=site.conf \
  "$LUA" -e "package.path='$ARBEIT/?.lua;'..package.path
             print(require('jsonc').stringify(assert(dofile('scripts/site_config.lua'))(os.getenv('GLUON_SITE_CONFIG'))))" \
) > "$ARBEIT/root/lib/gluon/site.json"

pruefe () {
  IPKG_INSTROOT="$ARBEIT/root" LUA_PATH="$ARBEIT/?.lua;$ARBEIT/lua/?.lua;;" \
    "$LUA" "$ARBEIT/root/lib/gluon/check-site.lua" < "$1" 2>&1
}

# Selbsttest: ein Pruefstand, der nicht fehlschlagen kann, beweist nichts.
"$LUA" -e "package.path='$ARBEIT/?.lua;'..package.path
           local j=require'jsonc'
           local s=j.load('$ARBEIT/root/lib/gluon/site.json')
           s.site_code=nil
           local f=io.open('$ARBEIT/root/lib/gluon/site.json','w')
           f:write(j.stringify(s)); f:close()"
if [ -z "$(pruefe "$GLUON/package/gluon-core/check_site.lua")" ]; then
  abort "Selbsttest fehlgeschlagen: eine site.conf ohne site_code haette beanstandet werden muessen."
fi
( cd "$GLUON" && GLUON_SITEDIR="$SITE" GLUON_SITE_CONFIG=site.conf \
  "$LUA" -e "package.path='$ARBEIT/?.lua;'..package.path
             print(require('jsonc').stringify(assert(dofile('scripts/site_config.lua'))(os.getenv('GLUON_SITE_CONFIG'))))" \
) > "$ARBEIT/root/lib/gluon/site.json"
echo "Selbsttest bestanden: fehlender site_code wird erkannt."
echo

OHNE=0; MIT=0
for FEED in "$GLUON/package" "$@"; do
  for F in "$FEED"/*/check_site.lua; do
    [ -f "$F" ] || continue
    PAKET="$(basename "$(dirname "$F")")"
    # "|| true": eine Beanstandung liefert Exitcode 1, und unter errexit
    # wuerde die Zuweisung den Lauf sonst hier beenden - genau die Meldungen,
    # derentwegen das Skript existiert, kaemen dann nie zur Anzeige.
    AUS="$(pruefe "$F" || true)"
    if [ -z "$AUS" ]; then
      OHNE=$(( OHNE + 1 ))
    else
      MIT=$(( MIT + 1 ))
      printf '%-38s %s\n' "$PAKET" "$(echo "$AUS" | head -1)"
    fi
  done
done

echo
echo "  ohne Beanstandung: $OHNE    mit Meldung: $MIT"
echo "  (Meldungen zu Paketen, die wir nicht auswaehlen, sind keine Befunde.)"
