#!/bin/bash
#
# Prueft, ob die Lua-Dateien der Site-Templates syntaktisch in Ordnung sind:
#
#   site.conf                 wird eingelesen und als JSON ausgegeben
#   image-customization.lua   wird uebersetzt (nicht ausgefuehrt, die
#                             DSL-Funktionen gibt es nur im Gluon-Kontext)
#
# Das ist ein Vorabcheck in Sekunden, kein Ersatz fuer Gluon: Gluon prueft die
# site.conf bei jedem "make" ueber CheckSite/check-site.lua semantisch gegen
# die Regeln der Pakete. Hier geht es nur darum, einen Tippfehler zu finden,
# bevor "make update" eine halbe Stunde laeuft.
#
# Aufruf von ueberall:  tests/check-site-conf.sh

set -o nounset
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( dirname "$SCRIPT_DIR" )"
cd "$REPO_DIR" || exit 1

# Farben nur, wenn die Ausgabe auf einem Terminal landet - im CI-Log stoeren
# die Escape-Sequenzen.
if [ -t 1 ]; then
  GREEN=$'\e[32m'; RED=$'\e[31m\e[1m'; RESET=$'\e[0m'
else
  GREEN=''; RED=''; RESET=''
fi

log_ok  () { echo "${GREEN}${*}${RESET}"; }
log_err () { echo "${RED}${*}${RESET}" >&2; }

# Nicht /usr/bin/lua fest verdrahten: der Interpreter heisst je nach
# Distribution anders, und die CI installiert lua5.4.
LUA=""
for candidate in lua lua5.4 lua5.3 lua5.2 lua5.1; do
  if command -v "$candidate" >/dev/null 2>&1; then
    LUA="$candidate"
    break
  fi
done
if [ -z "$LUA" ]; then
  log_err "Kein Lua-Interpreter gefunden (gesucht: lua, lua5.4 ... lua5.1)."
  exit 1
fi
echo "Lua: $($LUA -v 2>&1 | head -1)"

# Nur echte Verzeichnisse pruefen. 86 der 87 Templates sind Symlinks auf ein
# und dasselbe Verzeichnis (01_vel -> 05_mon -> common); ueber "templates/*"
# haette derselbe Inhalt 88-mal geprueft.
declare -i checked=0
declare -i failed=0

while read -r template; do
  echo "--- $template"

  if [ -f "$template/site.conf" ]; then
    checked+=1
    if output="$(GLUON_SITEDIR="$template" "$LUA" tests/site_config.lua 2>&1)"; then
      log_ok "    site.conf: in Ordnung ($(printf '%s' "$output" | wc -c) Byte JSON)"
    else
      failed+=1
      log_err "    site.conf: FEHLER"
      printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
  else
    log_err "    site.conf fehlt"
    failed+=1
  fi

  if [ -f "$template/image-customization.lua" ]; then
    checked+=1
    if output="$("$LUA" -e "assert(loadfile('$template/image-customization.lua'))" 2>&1)"; then
      log_ok "    image-customization.lua: in Ordnung"
    else
      failed+=1
      log_err "    image-customization.lua: FEHLER"
      printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
  fi
done < <(find templates -mindepth 1 -maxdepth 1 -type d | sort)

echo
if (( failed > 0 )); then
  log_err "$failed von $checked Pruefungen fehlgeschlagen."
  exit 1
fi
log_ok "Alle $checked Pruefungen bestanden."
