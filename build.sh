#!/bin/bash

# Copyright (c) 2018 R. Diez - Licensed under the GNU AGPLv3

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace  # ERR-Trap gilt auch in Funktionen und Subshells

# Freier Platz in MB unter SANDBOX_DIR, oder leer, wenn df nichts liefert.
#
# Gemessen wird am Sandbox-Verzeichnis: dort liegen Gluon-Baum, images/,
# assembled/ und .overlays/. Liegt eines davon per Symlink auf einer anderen
# Platte, sieht diese Pruefung das nicht.
disk_free_mb ()
{
  df -Pm -- "${SANDBOX_DIR:-.}" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# Sagt es laut, wenn die Platte praktisch voll ist. Die eigentliche Meldung
# ("No space left on device") steht sonst irgendwo weiter oben zwischen den
# Error- und Leaving-directory-Zeilen von make -j - und im Parallelbetrieb im
# Log eines Workers, das auf derselben vollen Platte womoeglich selbst nicht
# mehr geschrieben werden konnte. Gemessen am 10.09. mit einem kleinen tmpfs:
# die Abbruchmeldung nannte nur Exitcode und Zeile, nie die Ursache.
report_disk_if_full ()
{
  local FREI
  FREI="$(disk_free_mb)" || true
  if [ -n "$FREI" ] && (( FREI < ${DISK_FULL_MB:-1024} )); then
    echo "  PLATTE VOLL: unter ${SANDBOX_DIR:-.} sind nur noch $FREI MB frei - sehr wahrscheinlich die Ursache (No space left on device)." >&2
  fi
}

# Sagt beim Abbruch, woran es lag. Ohne das endet der Bau seit der
# Fehlererkennung wortlos mit einem Exitcode - genau das war frueher das
# Problem, nur eine Ebene hoeher.
on_error ()
{
  local -i EXIT_CODE="$?"
  local SIGNAL_HINT=""
  if (( EXIT_CODE > 128 )); then
    SIGNAL_HINT=" (Signal $(( EXIT_CODE - 128 )): $(kill -l $(( EXIT_CODE - 128 )) 2>/dev/null || echo unbekannt))"
  fi
  echo >&2
  echo "build.sh: Abbruch mit Exitcode $EXIT_CODE$SIGNAL_HINT" >&2
  echo "  Zeile ${BASH_LINENO[0]}: $BASH_COMMAND" >&2
  report_disk_if_full
}
trap on_error ERR

abort ()
{
  echo >&2 && echo "Error in script \"$0\": $*" >&2
  exit 1
}

replace_string_in_files ()
{
  local DIR="$1"
  local STRING_TO_REPLACE="$2"
  local REPLACEMENT_STRING="$3"

  find "$DIR" -type f -print0 | xargs -0 sed -i "s;$STRING_TO_REPLACE;$REPLACEMENT_STRING;g"
}

read_uptime_as_integer ()
{
  local PROC_UPTIME_CONTENTS
  PROC_UPTIME_CONTENTS="$(</proc/uptime)"

  local PROC_UPTIME_COMPONENTS
  IFS=$' \t' read -r -a PROC_UPTIME_COMPONENTS <<< "$PROC_UPTIME_CONTENTS"

  local UPTIME_AS_FLOATING_POINT=${PROC_UPTIME_COMPONENTS[0]}

  # The /proc/uptime format is not exactly documented, so I am not sure whether
  # there will always be a decimal part. Therefore, capture the integer part
  # of a value like "123" or "123.45".
  # I hope /proc/uptime never yields a value like ".12" or "12.", because
  # the following code does not cope with those.

  local REGEXP="^([0-9]+)(\\.[0-9]+)?\$"

  if ! [[ $UPTIME_AS_FLOATING_POINT =~ $REGEXP ]]; then
    abort "Error parsing this uptime value: $UPTIME_AS_FLOATING_POINT"
  fi

  UPTIME=${BASH_REMATCH[1]}
}

get_human_friendly_elapsed_time ()
{
  local -i SECONDS="$1"

  if (( SECONDS <= 59 )); then
    ELAPSED_TIME_STR="$SECONDS seconds"
    return
  fi

  local -i V="$SECONDS"

  ELAPSED_TIME_STR="$(( V % 60 )) seconds"

  V="$(( V / 60 ))"

  ELAPSED_TIME_STR="$(( V % 60 )) minutes, $ELAPSED_TIME_STR"

  V="$(( V / 60 ))"

  if (( V > 0 )); then
    ELAPSED_TIME_STR="$V hours, $ELAPSED_TIME_STR"
  fi

  printf -v ELAPSED_TIME_STR  "%s (%'d seconds)"  "$ELAPSED_TIME_STR"  "$SECONDS"
}


# Stellt jeder Zeile einen Zeitstempel voran, sofern ein awk mit strftime da
# ist. mawk und busybox awk koennen das nicht, deshalb die Pruefung beim Start.
# Ohne passendes awk laeuft die Ausgabe unveraendert durch, statt zu scheitern.
timestamp_lines ()
{
  if [ "$TIMESTAMP_AWK" = "" ]; then
    cat
  else
    "$TIMESTAMP_AWK" '{ print strftime("[%H:%M:%S]"), $0; fflush() }'
  fi
}


# Raeumt den PATH auf, bevor irgendetwas gebaut wird.
#
# Unter WSL reicht Windows seinen eigenen PATH durch. Ein Eintrag wie
# "/mnt/c/Program Files/PuTTY/" ist fuer sich genommen gueltig, zerfaellt im
# Build-System aber am Leerzeichen zu "/mnt/c/Program" und "Files/PuTTY/" -
# und ein *relativer* Eintrag im PATH bringt "find -execdir" dazu, die Arbeit
# grundsaetzlich zu verweigern:
#
#   find: The relative path 'Files/PuTTY/' is included in the PATH environment
#         variable, which is insecure in combination with the -execdir action
#
# OpenWrt benutzt genau das in package/install, um die Zeitstempel des
# root-Verzeichnisses zu normalisieren. Der Lauf stirbt damit erst nach der
# halben Bauzeit eines Targets, mit einer Meldung, die nach allem aussieht,
# nur nicht nach dem PATH. Deshalb hier, am Anfang, statt dort.
#
# Entfernt werden: relative Eintraege, leere Eintraege (die "." bedeuten) und
# Eintraege mit Leerzeichen. Nichts davon gehoert in einen Build-PATH.
sanitize_path ()
{
  local ENTRY
  local -a KEPT=()
  local -a DROPPED=()
  local SAVED_IFS="$IFS"

  IFS=':'
  for ENTRY in $PATH; do
    if [ -z "$ENTRY" ] || [[ $ENTRY != /* ]] || [[ $ENTRY == *" "* ]]; then
      DROPPED+=( "${ENTRY:-<leer>}" )
    else
      KEPT+=( "$ENTRY" )
    fi
  done
  IFS="$SAVED_IFS"

  if (( ${#DROPPED[@]} == 0 )); then
    return
  fi

  if (( ${#KEPT[@]} == 0 )); then
    abort "Cleaning the PATH would leave it empty. Entries: $PATH"
  fi

  local OLD_PATH="$PATH"
  printf -v PATH "%s:" "${KEPT[@]}"
  PATH="${PATH%:}"
  export PATH

  echo "Removed ${#DROPPED[@]} unusable PATH entry/entries for this build:"
  for ENTRY in "${DROPPED[@]}"; do
    echo "  $ENTRY"
  done
  echo "  (relative, empty or containing a space - \"find -execdir\" refuses to run with those)"
  unset OLD_PATH
}

detect_timestamp_awk ()
{
  local CANDIDATE

  TIMESTAMP_AWK=""

  if [ "$BUILD_LOG_TIMESTAMPS" != true ]; then
    return
  fi

  for CANDIDATE in gawk awk; do
    if command -v "$CANDIDATE" >/dev/null 2>&1 &&
       "$CANDIDATE" 'BEGIN { if (strftime("%s") == "") exit 1 }' >/dev/null 2>&1; then
      TIMESTAMP_AWK="$CANDIDATE"
      return
    fi
  done

  echo "Note: no awk with strftime found, the build logs get no timestamps."
}


# Liefert "<commit>  (<branch>, sauber|N Aenderungen)" fuer ein Git-Verzeichnis.
git_state ()
{
  local DIR="$1"

  if [ ! -d "$DIR/.git" ]; then
    echo "kein Git-Verzeichnis"
    return
  fi

  local COMMIT BRANCH DIRTY_COUNT STATE

  COMMIT="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo "?")"
  BRANCH="$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
  DIRTY_COUNT="$(git -C "$DIR" status --porcelain 2>/dev/null | wc -l)"

  if [ "$DIRTY_COUNT" -eq 0 ]; then
    STATE="sauber"
  else
    STATE="$DIRTY_COUNT Aenderungen"
  fi

  echo "$COMMIT  ($BRANCH, $STATE)"
}


# Schreibt die Herkunftsdaten neben die Images. Ohne diese Datei laesst sich
# hinterher nicht feststellen, aus welchem Stand ein Image entstanden ist -
# die Konfigurationsdateien daneben zeigen nur den Inhalt, nicht die Version.
write_build_info ()
{
  local SITE_IMAGE_DIR="$1"
  local RELBRANCH="$2"
  local TEMPLATE_NAME="$3"
  local SITE_CODE="$4"

  local INFO="$SITE_IMAGE_DIR/build-info.txt"
  local MODULE MODULE_LIST PINNED ACTUAL

  # Nur die Zeit dieser Domain, nicht die des ganzen Laufs. Bis 2026-09-10 stand
  # hier BUILD_START_EPOCH, also der Beginn des Skriptlaufs - dadurch trugen alle
  # Domains eines Laufs dieselbe Startzeit, und die ausgewiesene Dauer wuchs mit
  # jeder weiteren Domain an, statt die eigene zu nennen.
  #
  # Summiert aus SITE_SECONDS_FILE. Die Datei liegt in images/running und
  # ueberlebt damit einen Abbruch: beim --resume stehen die Zeiten der schon
  # erledigten Schritte noch darin, die Summe ist also auch dann vollstaendig.
  local -i SITE_SECONDS
  SITE_SECONDS="$(awk -F'\t' -v k="$TEMPLATE_NAME/$SITE_CODE" \
                   '$1 == k { s += $2 } END { print s + 0 }' \
                   "$SITE_SECONDS_FILE" 2>/dev/null || echo 0)"
  local SITE_ELAPSED_STR
  get_human_friendly_elapsed_time "$SITE_SECONDS"
  SITE_ELAPSED_STR="$ELAPSED_TIME_STR"

  {
    echo "Herkunft dieses Images"
    echo "======================"
    echo
    echo "Release:        $SBRANCH"
    echo "Domain:         $SITE_CODE (Template $TEMPLATE_NAME, Zweig $RELBRANCH)"
    echo "Bauzeit:        $SITE_ELAPSED_STR"
    echo "Lauf:           $(date -d "@$BUILD_START_EPOCH" "+%F %T") bis $(date "+%F %T") ($(( ( $(date +%s) - BUILD_START_EPOCH ) / 60 )) Minuten)"
    echo "Host:           $(uname -n) ($(uname -sr))"
    echo "Aufruf:         $BUILD_COMMAND_LINE"
    echo
    echo "Firmware-Repo:  $(git_state "$SANDBOX_DIR")"
    echo "Gluon:          $(git_state "$GLUON_DIR")"
    echo
    # Verglichen wird gegen den Zweig "base", nicht gegen HEAD: "make update"
    # legt ueber base den Zweig "patched" mit Gluons eigenen Patches, HEAD
    # weicht dort also planmaessig ab. Genauso prueft Gluons module_check.sh.
    echo "Module, Soll (modules) gegen Ist (Zweig base):"

    # In einer Subshell, die modules.sh eingelesen hat: dort stehen die
    # Soll-Commits als <MODUL>_COMMIT bereit, so wie Gluons eigenes
    # scripts/module_check.sh sie liest.
    (
      cd "$GLUON_DIR" || exit 0
      export GLUON_SITEDIR="$SANDBOX_DIR/assembled/$TEMPLATE_NAME/$SITE_CODE"
      . scripts/modules.sh 2>/dev/null || exit 0

      for MODULE in $GLUON_MODULES; do
        VAR="$(echo "$MODULE" | tr '[:lower:]/' '[:upper:]_')_COMMIT"
        eval "PINNED=\${$VAR:-}"
        ACTUAL="$(git -C "$GLUON_DIR/$MODULE" rev-parse heads/base 2>/dev/null || echo "-")"
        PATCHED="$(git -C "$GLUON_DIR/$MODULE" rev-parse HEAD 2>/dev/null || echo "-")"

        if [ "$PINNED" = "$ACTUAL" ]; then
          if [ "$PATCHED" = "$ACTUAL" ]; then
            printf "  %-22s %s\n" "$MODULE" "$PINNED"
          else
            printf "  %-22s %s  (gepatcht: %s)\n" "$MODULE" "$PINNED" "${PATCHED:0:12}"
          fi
        else
          printf "  %-22s Soll %s\n  %-22s Ist  %s   ABWEICHUNG\n" \
                 "$MODULE" "${PINNED:-?}" "" "$ACTUAL"
        fi
      done
    )

    echo
    echo "Targets:        ${TARGETS[*]}"
    echo "Domains:        ${ALL_SITE_CODES[*]}"

    local MANIFEST KERNEL_LINES
    KERNEL_LINES="$(find "$GLUON_DIR/openwrt/bin/targets" -name '*.manifest' -exec \
                    grep -hE '^(kmod-mac80211|kmod-mt7915e|kmod-ath10k|kmod-ath9k) ' {} + 2>/dev/null | sort -u || true)"
    if [ -n "$KERNEL_LINES" ]; then
      echo
      echo "Kernel und WLAN-Treiber laut OpenWrt-Manifest:"
      printf "%s\n" "$KERNEL_LINES" | sed 's/^/  /'
    fi

    # Die Patchliste aus dem Protokoll des Vorbereitungslaufs. Sie steht dort
    # ohnehin, aber verstreut ueber Zehntausende Zeilen Buildausgabe.
    if [ -f "$SANDBOX_DIR/assembled/prepare.log" ]; then
      echo
      awk '
    {
      line = $0
      sub(/^\[[0-9:]+\] +/, "", line)

      if (line ~ /Phase pre-update/)  { phase = "pre-update";  next }
      if (line ~ /Phase post-update/) { phase = "post-update"; next }

      if (line ~ /--- Patching module /) {
        n = split(line, part, /\047/)
        if (n >= 2) {
          mod = part[2]
          if (!(mod in seenmod)) { modorder[++nmod] = mod; seenmod[mod] = 1 }
        }
        next
      }

      if (line ~ /^Applying: /) {
        subj = line; sub(/^Applying: /, "", subj)
        gluonpatch[mod] = gluonpatch[mod] sprintf("      %s\n", subj)
        gluoncount[mod]++
        next
      }

      # "kopiert" und "liegt bereits im Baum" kommen von copy_into_tree:
      # Patches, die wir nur ablegen und die OpenWrt selbst anwendet.
      # Ohne sie fehlten hier der Zbit- und der MIPS-TLB-Patch.
      if (line ~ /\.patch: (angewendet|bereits angewendet|kopiert|liegt bereits im Baum|\047)/) {
        name = line
        sub(/^ +/, "", name)
        sub(/.*\//, "", name)
        res = name
        sub(/^[^:]+: +/, "", res)
        sub(/\.$/, "", res)
        sub(/:.*/, "", name)
        if (res ~ /^\047/) res = "schon im Baum"
        ours[++nours] = sprintf("      %-40s %s\n", name, res)
        ourphase[nours] = (phase == "" ? "?" : phase)
        next
      }
    }
    END {
      print "Patches"
      print "-------"
      print ""
      print "  Von Gluon auf die Module angewendet (make update):"
      for (i = 1; i <= nmod; i++) {
        m = modorder[i]
        if (gluoncount[m] > 0) {
          printf "    %s (%d):\n", m, gluoncount[m]
          printf "%s", gluonpatch[m]
        }
      }
      print ""
      print "  Von uns angewendet (prepare.sh):"
      for (p = 1; p <= 2; p++) {
        ph = (p == 1 ? "pre-update" : "post-update")
        first = 1
        for (i = 1; i <= nours; i++) {
          if (ourphase[i] == ph) {
            if (first) { printf "    %s:\n", ph; first = 0 }
            printf "%s", ours[i]
          }
        }
      }
    }
' "$SANDBOX_DIR/assembled/prepare.log"
    fi
  } > "$INFO"

  echo "Provenance written to \"$INFO\"."
}

# Mit Target: das Log genau eines Bauschritts, build-<target>.log. Ohne: das
# Log des Abschlusses der Domain, build.log, in das finalize schreibt.
#
# Beide liegen nur, solange ihr Schritt laeuft, ungepackt in assembled/. Ist ein
# Schritt durch, wandert sein Log gepackt nach images/running (store_target_log,
# finish_site_log) - assembled/ raeumt jeder Lauf ab, auch der --resume.
#
# Warum je Target getrennt: im Parallelbetrieb bauen mehrere Worker
# verschiedene Targets derselben Domain gleichzeitig. In ein gemeinsames Log
# geschrieben, ergaebe das zwar keine zerrissenen Zeilen (tee --append, kurze
# Zeilen sind atomar), aber ein Durcheinander aus zwei Builds Zeile um Zeile.
# finish_site_log fuegt die Teile beim Abschluss in Target-Reihenfolge zusammen,
# das veroeffentlichte build.log.gz sieht also aus wie immer.
get_site_log_filename ()
{
  local TEMPLATE_NAME="$1"
  local SITE_CODE="$2"
  local TARGET="${3:-}"

  if [ -n "$TARGET" ]; then
    LOG_FILENAME="$SANDBOX_DIR/assembled/$TEMPLATE_NAME/$SITE_CODE/build-$TARGET.log"
  else
    LOG_FILENAME="$SANDBOX_DIR/assembled/$TEMPLATE_NAME/$SITE_CODE/build.log"
  fi
}

# Wohin die Logs einer Domain gepackt wandern: in ihr Site-Verzeichnis unter
# images/running. Das ueberlebt einen Abbruch und den --resume, und waehrend des
# Laufs sind die Logs fertiger Targets dort schon zu sehen.
get_site_log_dir ()
{
  SITE_LOG_DIR="$SANDBOX_DIR/images/running/$1/$2/site"
}

# Packt das Log eines durchgelaufenen Bauschritts sofort weg, als
# site/build-<target>.log.gz. Aufgerufen nur nach erfolgreichem make und vor
# state_mark: ein als gebaut vermerktes Target hat damit immer sein Log.
#
# Frueher lag es bis zum Laufende ungepackt in assembled/ und war bei einem
# --resume weg, weil generate_all_site_configs assembled/ mit rm -rf raeumt.
#
# Ueber .tmp und mv: ein Abbruch mitten im Packen hinterlaesst kein halbes
# .gz, das spaeter als vollstaendig durchginge. Wird das Target nach einem
# Abbruch zwischen mv und state_mark neu gebaut, ersetzt das neue Log das alte.
store_target_log ()
{
  local TEMPLATE_NAME="$1"
  local SITE_CODE="$2"
  local TARGET="$3"
  local SITE_LOG_DIR
  get_site_log_dir "$TEMPLATE_NAME" "$SITE_CODE"
  local ROH="$SANDBOX_DIR/assembled/$TEMPLATE_NAME/$SITE_CODE/build-$TARGET.log"
  local GZ="$SITE_LOG_DIR/build-$TARGET.log.gz"

  [ -f "$ROH" ] || return 0
  mkdir --parents -- "$SITE_LOG_DIR"
  gzip --best --stdout -- "$ROH" > "$GZ.tmp"
  mv -- "$GZ.tmp" "$GZ"
  rm -f -- "$ROH"
}

# Setzt beim Abschluss einer Domain site/build.log.gz zusammen: die gepackten
# Logs der Targets in der Reihenfolge der Targetliste - so, wie es unter
# BUILD_ORDER=domain schon immer aussah - und dahinter das Log von finalize.
# Aufgerufen, wenn finalize_site durch ist, also vollstaendig.
#
# Einmal entpackt und als Ganzes neu gepackt statt die .gz einfach
# aneinanderzuhaengen. Das Aneinanderhaengen waere gueltiges gzip, und zcat,
# zgrep und zless kaemen damit zurecht, aber nicht jedes Werkzeug liest ueber
# das erste Member hinaus. Die paar Sekunden sind es wert.
#
# Wiederholbar: die Teile bleiben liegen, bis state_mark finalize geschrieben
# ist (drop_target_log_parts). Bricht der Lauf dazwischen ab, entsteht
# build.log.gz beim naechsten finalize einfach neu aus denselben Teilen. Gibt
# es keine Teile, aber schon ein build.log.gz, bleibt dessen Inhalt vorn stehen.
finish_site_log ()
{
  local TEMPLATE_NAME="$1"
  local SITE_CODE="$2"
  local SITE_LOG_DIR
  get_site_log_dir "$TEMPLATE_NAME" "$SITE_CODE"
  local GZ="$SITE_LOG_DIR/build.log.gz"
  local FIN="$SANDBOX_DIR/assembled/$TEMPLATE_NAME/$SITE_CODE/build.log"
  local TARGET
  local -a TEILE=()

  for TARGET in "${BUILD_TARGETS[@]}"; do
    [ -f "$SITE_LOG_DIR/build-$TARGET.log.gz" ] && TEILE+=( "$SITE_LOG_DIR/build-$TARGET.log.gz" )
  done
  if (( ${#TEILE[@]} == 0 )) && [ -f "$GZ" ]; then
    TEILE=( "$GZ" )
  fi

  mkdir --parents -- "$SITE_LOG_DIR"
  {
    (( ${#TEILE[@]} == 0 )) || gzip --decompress --stdout -- "${TEILE[@]}"
    [ ! -f "$FIN" ] || cat -- "$FIN"
  } | gzip --best > "$GZ.tmp"
  mv -- "$GZ.tmp" "$GZ"
}

# Raeumt nach dem Abschluss einer Domain die Einzelteile weg: die gepackten
# Target-Logs, jetzt in build.log.gz enthalten, und das ungepackte Log von
# finalize in assembled/. Erst nach state_mark finalize, siehe finish_site_log;
# und noch einmal, wenn eine abgeschlossene Domain uebersprungen wird, falls ein
# Abbruch genau zwischen state_mark und hier lag.
drop_target_log_parts ()
{
  local TEMPLATE_NAME="$1"
  local SITE_CODE="$2"
  local SITE_LOG_DIR
  get_site_log_dir "$TEMPLATE_NAME" "$SITE_CODE"
  local TARGET

  for TARGET in "${BUILD_TARGETS[@]}"; do
    rm -f -- "$SITE_LOG_DIR/build-$TARGET.log.gz"
  done
  rm -f -- "$SANDBOX_DIR/assembled/$TEMPLATE_NAME/$SITE_CODE/build.log"
}
# Default values for every setting that build.conf may override. They are
# defined here so that build.sh still runs if no configuration file exists.
set_config_defaults ()
{
  SBRANCH_MODE="date"
  SBRANCH_FIXED=""

  MAKECLEAN=false
  GITRESET=false

  MAKE_J_VAL=0
  MAKE_J_FACTOR=2

  BROKEN=1
  AUTOUPDATER_ENABLED=true
  VERBOSE_BUILD=true
  BUILD_LOG=false
  BUILD_LOG_TIMESTAMPS=true
  GLUON_SITE_VERSION="$(date +%Y%m%d)"
  GLUONDEVICES=""
  SIGNKEY_FILE="untrustworthy-buildbot-signkey.priv"

  BUILD_ORDER="domain"
  BUILD_TIMES_FILE="$SANDBOX_DIR/build-times.csv"

  # Parallelbetrieb, siehe build.conf. 1 = seriell wie bisher, ohne Overlay.
  WORKERS=1
  WORKER_START_DELAY=60
  WORKERS_AUTO_START=3
  METRICS=true

  # Platzschaetzung vor dem Lauf, siehe space_check und build.conf.
  SPACE_CHECK=true
  SPACE_UNIT_MB=250
  SPACE_TARGET_MB=50
  SPACE_WORKER_BASE_MB=3000
  SPACE_WORKER_DOMAIN_MB=200
  SPACE_RESERVE_MB=20480
  DISK_FULL_MB=1024

  # Quellen vorab holen, mit Wiederholung. 0 Versuche schaltet den Schritt ab.
  DOWNLOAD_ATTEMPTS=5
  DOWNLOAD_RETRY_DELAY=30

  DATE_SUFFIX_FORMAT="+%s"
  SITE_COPY_EXCLUDES=( '*.old' '*.backup' '*~' '*.nonworking' )
}

# Fingerabdruck des golden tree: alles, was bestimmt, WAS im Baum kompiliert
# steht - unabhaengig davon, welche Domains daraus gebaut werden.
#
# Er wird aus den EINGABEN gebildet, vor prepare, und nicht aus dem fertigen
# Baum. Der naheliegende andere Weg - immer git reset und die Patches
# anwenden, dann ueber den Baum hashen - taugt nicht: beides setzt die
# Aenderungszeiten aller gepatchten Dateien neu, auch bei identischem Inhalt,
# und OpenWrt entscheidet teils an Aenderungszeiten ueber Neubauten. Ein
# golden tree, der bei jedem Lauf angefasst wird, ist keiner mehr. Passt der
# Fingerabdruck, bleibt der Baum deshalb komplett unberuehrt.
#
# Das ist nur sicher, wenn er JEDE Eingabe erfasst. Im Zweifel lieber zu grob:
# ein ueberfluessiger Neubau kostet so viel wie heute jeder Lauf, eine
# vergessene Eingabe dagegen erzeugt stillschweigend Images aus altem
# Quellstand.
#
#   origin/<gluonbranch>   Gluons eigene modules-Datei, also OpenWrt,
#                          packages, routing und gluon samt ihren Pins
#   templates/common/      die Site-modules (Feed-Pins neanderfunk, ffac,
#                          community), image-customization.lua, site.mk,
#                          prepare.sh. Bewusst zu grob: site.conf und i18n
#                          gehen nur in gluon-site ein, das ohnehin je Domain
#                          entsteht, loesen hier aber trotzdem einen Neubau aus.
#   patches/               alle Patch-Inhalte
#   Targets, Geraete,      welche Geraete und Pakete ueberhaupt gebaut werden
#   BROKEN
#   Host-Compiler, glibc   die Host-Werkzeuge im Baum sind dagegen gelinkt;
#                          nach einem Upgrade liefen sie auf einem Stand
#                          weiter, den niemand bewusst gewaehlt hat
#
# Nicht erfasst: sites-Datei und Domainauswahl (nur gluon-site), build.sh
# selbst, und die Laufwerte SBRANCH, DATE_SUFFIX, GLUON_SITE_VERSION, WORKERS.
#
# Editor-Reste (SITE_COPY_EXCLUDES, etwa modules~) bleiben aussen vor, sonst
# baute ein gespeicherter Editorpuffer den golden tree neu.
golden_fingerprint ()
{
  local GLUONBRANCH="$1"
  local -a AUSSCHLUSS=()
  local MUSTER

  for MUSTER in "${SITE_COPY_EXCLUDES[@]}"; do
    AUSSCHLUSS+=( ! -name "$MUSTER" )
  done

  {
    echo "gluon=$(git -C "$GLUON_DIR" rev-parse --verify "origin/$GLUONBRANCH^{commit}")"
    # Sortiert: die Reihenfolge in targets.conf aendert nichts daran, was
    # kompiliert wird, und soll keinen Neubau ausloesen.
    echo "targets=$(printf '%s\n' "${BUILD_TARGETS[@]}" | sort | tr '\n' ' ')"
    echo "devices=$GLUONDEVICES"
    echo "broken=$BROKEN"
    echo "cc=$(gcc --version 2>/dev/null | head -n 1)"
    echo "libc=$(ldd --version 2>/dev/null | head -n 1)"
    # Sortiert, damit die Reihenfolge im Dateisystem keine Rolle spielt.
    ( cd "$SANDBOX_DIR" \
        && find patches templates/common -type f "${AUSSCHLUSS[@]}" -print0 \
         | sort -z | xargs -0 sha256sum )
  } | sha256sum | cut -d' ' -f1
}

# Raeumt ein Overlay-Arbeitsverzeichnis weg. overlayfs legt darin work/work
# mit Modus 000 an, ohne chmod scheitert das rm schon beim eigenen Benutzer.
ovl_discard_dir ()
{
  local DIR="$1"
  [ -e "$DIR" ] || return 0
  chmod -R u+rwx -- "$DIR" 2>/dev/null || true
  rm -rf -- "$DIR"
}

# Prueft, ob dieser Host kann, was ein Worker spaeter tut: rootless ein
# Kernel-overlayfs mounten, darin als eigene UID arbeiten, und dabei den
# golden tree unberuehrt lassen. Benutzt dafuer scripts/ovl-enter.sh, prueft
# also genau den Weg, den die Worker nehmen - nicht bloss, ob die Werkzeuge
# da sind. Nur ein echter Mount zeigt, ob der Kernel oder AppArmor dazwischen
# geht.
#
# Getestet wird auch "rm -rf" samt Neuanlegen am selben Ort, denn genau daran
# ist fuse-overlayfs gescheitert.
#
# 0 bei Erfolg, sonst 1 und der Grund auf stdout.
ovl_selftest ()
{
  local T="$OVL_DIR/selftest"
  local OUT

  ovl_discard_dir "$T"
  mkdir -p "$T/gold/verz/unter" "$T/w/lower" "$T/w/upper" "$T/w/work" \
    || { echo "kann $T nicht anlegen"; return 1; }
  echo golden > "$T/gold/stand"

  OUT="$(unshare -Urm "$SANDBOX_DIR/scripts/ovl-enter.sh" \
           "$T/gold" "$T/w" "$T/gold" "$(id -u)" "$(id -g)" \
           bash -c '
             [ "$(id -u)" = "$1" ] || { echo "UID-Wechsel misslungen (uid $(id -u))"; exit 1; }
             rm -rf "$2/verz" && mkdir "$2/verz" && mkdir "$2/verz/neu" \
               || { echo "rm -rf und Neuanlegen im Overlay scheitert"; exit 1; }
             echo neu > "$2/stand"
             echo ok
           ' _ "$(id -u)" "$T/gold" 2>&1)" || true

  # Der Test hat im Overlay "stand" ueberschrieben. Steht auf dem Host danach
  # nicht mehr "golden" darin, hat das Overlay nicht isoliert.
  if [ "$(tail -n 1 <<<"$OUT")" = "ok" ] && [ "$(cat "$T/gold/stand" 2>/dev/null)" != "golden" ]; then
    OUT="das Overlay isoliert nicht - der Test hat den golden tree veraendert"
  fi

  ovl_discard_dir "$T"

  [ "$(tail -n 1 <<<"$OUT")" = "ok" ] && return 0
  echo "${OUT:-unshare lieferte nichts}" | tr '\n' ' '
  return 1
}

# Was dieser Lauf abweichend von der Konfiguration tut (seriell statt
# parallel, ohne Metriken, weniger Worker). Wird beim Rueckfall laut gemeldet
# und am Ende des Laufs noch einmal, damit es nicht in Stunden Log untergeht.
declare -a DEGRADIERT=()

# Eine Warnung, die man beim Durchscrollen nicht uebersieht. Erste Zeile ist
# die Ueberschrift, jede weitere eine Zeile darunter.
fat_warning ()
{
  local BALKEN="!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  local ZEILE
  echo
  echo "$BALKEN"
  echo "!!! $1"
  shift
  for ZEILE in "$@"; do
    echo "!!!   $ZEILE"
  done
  echo "$BALKEN"
  echo
}

# Prueft vorab alles, was der Lauf an Werkzeugen und Dateien braucht, und
# meldet ALLE Maengel auf einmal.
#
# Zwei Sorten Maengel: Fehlt etwas fuer den Bau selbst (git, make, ecdsasign,
# der Schluessel ...), bricht der Lauf ab. Fehlt nur etwas fuer eine Zugabe -
# den Parallelbetrieb oder den Collector -, laeuft er ohne sie weiter, mit
# einer fetten Warnung: seriell mit der konfigurierten BUILD_ORDER bzw. ohne
# Metriken. Ein Buildhost, auf dem das overlay-Modul fehlt, baut also trotzdem
# - nur langsamer, und das steht unuebersehbar im Log.
#
# Ohne das scheitert ein fehlendes Werkzeug erst dort, wo es gebraucht wird.
# Das Tueckische daran ist die Reihenfolge: die Werkzeuge des Anfangs (git,
# make, patch) fallen sofort auf, aber gerade die des Endes nicht. esign ruft
# /usr/bin/ecdsasign mit festem Pfad auf, und zwar in finalize_site - also nach
# dem letzten Target einer Domain, im Volllauf Stunden nach dem Start. gzip
# braucht erst store_target_log, nach dem ersten fertig gebauten Target.
#
# Gesammelt statt beim ersten Treffer abgebrochen: wer drei Werkzeuge
# nachinstallieren muss, soll das nicht in drei Anlaeufen erfahren.
#
# Was OpenWrt selbst fuer den Bau braucht, prueft OpenWrt in prereq-build.mk
# ohnehin, und zwar gleich beim ersten make - das wird hier nicht dupliziert.
preflight_check ()
{
  local -a FEHLT=()
  local WERKZEUG

  # Was build.sh und seine Helfer (esign, prepare.sh, lib-patch.sh) direkt
  # aufrufen.
  for WERKZEUG in git make patch sed grep awk find xargs cp rsync sort tee \
                  date stat mktemp gzip sha256sum getconf sync df tail; do
    command -v "$WERKZEUG" >/dev/null 2>&1 || FEHLT+=( "$WERKZEUG" )
  done

  # Signieren. Faellt sonst erst beim Manifest der ersten Domain auf.
  if [ -n "$SIGNKEY_FILE" ]; then
    [ -x /usr/bin/ecdsasign ] \
      || FEHLT+=( "/usr/bin/ecdsasign (esign ruft es mit festem Pfad auf; Paket ecdsautils)" )
    [ -r "$SANDBOX_DIR/buildkeys/$SIGNKEY_FILE" ] \
      || FEHLT+=( "Signaturschluessel buildkeys/$SIGNKEY_FILE (SIGNKEY_FILE)" )
  fi

  # Der Gluon-Baum. build.sh klont ihn nicht selbst; ohne ihn scheiterte der
  # Lauf erst nach der Site-Erzeugung an einem pushd. Der Branch steht in
  # Spalte 2 der Sites-Datei.
  if ! git -C "$SANDBOX_DIR/gluon" rev-parse --git-dir >/dev/null 2>&1; then
    local GB=""
    [ -f "$SITES_FILE" ] && GB="$(awk '!/^[[:space:]]*#/ && NF { print $2; exit }' "$SITES_FILE")"
    FEHLT+=( "Gluon-Baum $SANDBOX_DIR/gluon (git). Einmalig: git clone -b ${GB:-<Gluon-Branch aus Spalte 2 der Sites-Datei>} https://github.com/freifunk-gluon/gluon $SANDBOX_DIR/gluon" )
  fi

  # Der Collector ist ein Python-Skript. Ohne python3 ohne Metriken.
  if [ "$METRICS" = true ] && ! command -v python3 >/dev/null 2>&1; then
    METRICS=false
    DEGRADIERT+=( "ohne Metriken (METRICS=false): python3 fehlt" )
    fat_warning "python3 fehlt - dieser Lauf laeuft OHNE Collector (METRICS=false)." \
                "Keine Lastdaten, keine Empfehlung fuer WORKERS=auto. Nachruesten: python3."
  fi

  # Parallelbetrieb. Erst die Werkzeuge, dann - nur wenn die da sind - der
  # Funktionstest; ohne unshare saehe der nur dasselbe Loch noch einmal.
  local USERNS_HINWEIS=""
  local -a PAR_FEHLT=()
  if (( WORKERS > 1 )); then
    for WERKZEUG in unshare setsid flock; do
      command -v "$WERKZEUG" >/dev/null 2>&1 || PAR_FEHLT+=( "$WERKZEUG" )
    done
    # Der Scheduler erfaehrt mit "wait -n -p", welcher Worker fertig ist. Das
    # gibt es erst ab bash 5.1; aelter scheiterte er beim ersten fertigen Worker.
    if (( BASH_VERSINFO[0] < 5 || ( BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1 ) )); then
      PAR_FEHLT+=( "bash ab 5.1 fuer wait -n -p, vorhanden ist $BASH_VERSION" )
    fi

    # Kein Vorab-Blick in /proc/filesystems: dort steht overlay erst, wenn das
    # Modul geladen ist, und das laedt der Kernel beim ersten Mount selbst nach
    # (auch aus einem User-Namespace, ueber den Alias fs-overlay). Auf einem
    # frisch gebooteten Ubuntu fehlte es dort, obwohl alles da war. Der
    # Selbsttest mountet wirklich und entscheidet damit allein.
    if command -v unshare >/dev/null 2>&1; then
      local GRUND
      if ! GRUND="$(ovl_selftest)"; then
        PAR_FEHLT+=( "rootless overlayfs: $GRUND" )
        # Steht overlay auch nach dem Mountversuch nicht in /proc/filesystems,
        # liess sich das Modul nicht laden.
        if ! grep -qw overlay /proc/filesystems; then
          USERNS_HINWEIS="overlayfs ist nicht geladen und liess sich nicht nachladen. Einmalig als root: modprobe overlay, dauerhaft mit einer Zeile \"overlay\" in /etc/modules-load.d/overlay.conf. Gemeint ist das Kernelmodul, nicht fuse-overlayfs - das ist fuer diesen Zweck untauglich."
        fi
        # Ubuntu ab 23.10 sperrt unprivilegierte User-Namespaces per AppArmor.
        # Steht der Schalter auf 1, ist das mit hoher Wahrscheinlichkeit die
        # Ursache - dann gleich die Abhilfe nennen statt raten zu lassen.
        local SPERRE=/proc/sys/kernel/apparmor_restrict_unprivileged_userns
        if [ -r "$SPERRE" ] && [ "$(cat "$SPERRE")" = 1 ]; then
          USERNS_HINWEIS="${USERNS_HINWEIS:+$USERNS_HINWEIS }AppArmor sperrt unprivilegierte User-Namespaces (kernel.apparmor_restrict_unprivileged_userns = 1). Einmalig als root: sysctl -w kernel.apparmor_restrict_unprivileged_userns=0, dauerhaft ueber eine Datei in /etc/sysctl.d/."
        fi
      fi
    fi
  fi

  if (( ${#FEHLT[@]} > 0 )); then
    echo >&2
    echo "Vorabpruefung: ${#FEHLT[@]} Voraussetzung(en) fuer den Bau fehlen:" >&2
    printf '  - %s\n' "${FEHLT[@]}" >&2
    abort "Bitte zuerst nachruesten. Der Lauf wuerde sonst erst dort scheitern, wo das Fehlende gebraucht wird - womoeglich Stunden nach dem Start."
  fi

  # Parallelbetrieb nicht moeglich: seriell weiter, laut.
  if (( ${#PAR_FEHLT[@]} > 0 )); then
    local -a ZEILEN=( "Es fehlt:" )
    local M
    for M in "${PAR_FEHLT[@]}"; do ZEILEN+=( "  - $M" ); done
    [ -n "$USERNS_HINWEIS" ] && ZEILEN+=( "" "Abhilfe: $USERNS_HINWEIS" )
    ZEILEN+=( "" "Der Bau laeuft trotzdem, nur langsamer. Ausdruecklich seriell: WORKERS=1." )
    fat_warning "PARALLELBETRIEB NICHT MOEGLICH - dieser Lauf baut SERIELL (WORKERS=1, BUILD_ORDER=$BUILD_ORDER_KONFIG) statt mit $WORKERS Workern." \
                "${ZEILEN[@]}"
    DEGRADIERT+=( "SERIELL statt mit $WORKERS Workern: ${PAR_FEHLT[*]}" )
    WORKERS=1
    BUILD_ORDER="$BUILD_ORDER_KONFIG"
  fi

  echo "Vorabpruefung bestanden."
}

# Prints the given path as an absolute one, without requiring the file to exist
# yet. A relative path is resolved against the current working directory, which
# is still the one the user called build.sh from.
to_absolute_path ()
{
  local FILE_PATH="$1"

  if [[ $FILE_PATH == /* ]]; then
    echo "$FILE_PATH"
  else
    echo "$PWD/$FILE_PATH"
  fi
}

# Sources one configuration file, aborting if it is missing. The three
# configurations are passed on the command line, so a wrong path is a mistake
# worth stopping for rather than silently falling back to defaults.
source_config_file ()
{
  local KIND="$1"
  local CONFIG_FILE="$2"

  if [ ! -f "$CONFIG_FILE" ]; then
    abort "The $KIND configuration \"$CONFIG_FILE\" does not exist."
  fi

  echo "Reading the $KIND configuration from \"$CONFIG_FILE\" ..."
  source "$CONFIG_FILE"
}

# Reads the build configuration: built-in defaults first, then the given file,
# then the optional machine-local overrides in build.local.conf.
load_build_config ()
{
  set_config_defaults
  source_config_file build "$1"

  # Machine-local overrides, not tracked in Git.
  local LOCAL_CONFIG_FILE="$SANDBOX_DIR/build.local.conf"

  if [ -f "$LOCAL_CONFIG_FILE" ]; then
    echo "Reading the local build configuration from \"$LOCAL_CONFIG_FILE\" ..."
    source "$LOCAL_CONFIG_FILE"
  fi
}

# Reads the target configuration, which only holds GLUON_TARGETS.
load_targets_config ()
{
  GLUON_TARGETS=()
  source_config_file target "$1"

  if (( ${#GLUON_TARGETS[@]} == 0 )); then
    abort "GLUON_TARGETS is empty in \"$1\"."
  fi
}

# Reads the domain configuration: which sites file to use, and which of its
# domains to build.
load_domains_config ()
{
  SITES_FILE=""
  DOMAINS_INCLUDE=( all )
  DOMAINS_EXCLUDE=()

  source_config_file domain "$1"

  if [ -z "$SITES_FILE" ]; then
    abort "SITES_FILE is not set in \"$1\"."
  fi

  # A relative SITES_FILE is resolved against the directory of build.sh, so that
  # the domain configuration does not depend on the current working directory.
  if [[ $SITES_FILE != /* ]]; then
    SITES_FILE="$SANDBOX_DIR/$SITES_FILE"
  fi

  if [ ! -f "$SITES_FILE" ]; then
    abort "The sites file \"$SITES_FILE\" named in \"$1\" does not exist."
  fi

  if (( ${#DOMAINS_INCLUDE[@]} == 0 )); then
    abort "DOMAINS_INCLUDE is empty in \"$1\". Use ( all ) to build every domain."
  fi
}

# Decides whether one domain of the sites file is built. Domains are addressed
# by their template name, which is the only field that is unique per row: the
# key and nokeys variant of a domain share the same site code.
# DOMAINS_EXCLUDE wins over DOMAINS_INCLUDE.
domain_is_selected ()
{
  local TEMPLATE_NAME="$1"
  local ENTRY

  for ENTRY in "${DOMAINS_EXCLUDE[@]}"; do
    if [[ $ENTRY == "$TEMPLATE_NAME" ]]; then
      return 1
    fi
  done

  for ENTRY in "${DOMAINS_INCLUDE[@]}"; do
    if [[ $ENTRY == all || $ENTRY == "$TEMPLATE_NAME" ]]; then
      return 0
    fi
  done

  return 1
}

# Reports entries of DOMAINS_INCLUDE and DOMAINS_EXCLUDE that match no row of
# the sites file. Without this a typo would quietly build the wrong set.
check_domain_selection ()
{
  local -a UNKNOWN=()
  local ENTRY
  local SEEN

  for ENTRY in "${DOMAINS_INCLUDE[@]}" "${DOMAINS_EXCLUDE[@]}"; do
    if [[ $ENTRY == all ]]; then
      continue
    fi

    SEEN=false

    for TEMPLATE_NAME in "${ALL_TEMPLATE_NAMES_IN_FILE[@]}"; do
      if [[ $TEMPLATE_NAME == "$ENTRY" ]]; then
        SEEN=true
        break
      fi
    done

    if [ "$SEEN" = false ]; then
      UNKNOWN+=( "$ENTRY" )
    fi
  done

  if (( ${#UNKNOWN[@]} != 0 )); then
    abort "These domains are named in the domain configuration but do not appear in \"$SITES_FILE\": ${UNKNOWN[*]}"
  fi
}

# Determines the firmware version string, see SBRANCH_MODE in build.conf.
determine_sbranch ()
{
  local SITES_FILE="$1"

  case "$SBRANCH_MODE" in

    fixed)
      if [ -z "$SBRANCH_FIXED" ]; then
        abort "SBRANCH_MODE is \"fixed\", but SBRANCH_FIXED is empty."
      fi
      SBRANCH="$SBRANCH_FIXED"
      ;;

    date)
      # The date followed by the first 3 characters of the release branch
      # of the first site in the sites file, which yields e.g. "26030610sta".
      local RELBRANCH_PREFIX
      # "grep -m1" statt "| head -1": head schliesst die Pipe nach der ersten
      # Zeile, der schreibende grep bekommt dann SIGPIPE und endet mit 141.
      # Zusammen mit pipefail und errexit bricht das den Bau ab - je nach
      # Zeitverhalten, also sporadisch. grep hoert von sich aus auf.
      RELBRANCH_PREFIX="$(grep -m1 -v -e '^#' -e '^[[:space:]]*$' -- "$SITES_FILE" | cut -c1-3)"
      SBRANCH="$(date +%y%m%d%H)$RELBRANCH_PREFIX"
      ;;

    datetime)
      SBRANCH="$(date +%Y%m%d%H%M)"
      ;;

    *)
      abort "Invalid SBRANCH_MODE \"$SBRANCH_MODE\". Valid values are: fixed, date, datetime."
      ;;

  esac

  # Bei --resume gilt der Wert aus der Zustandsdatei (state_resume nennt ihn);
  # der hier frisch berechnete wuerde sonst eine Version anzeigen, die gar
  # nicht gebaut wird.
  if [ "$RESUME" = true ]; then
    echo "Firmware version (SBRANCH): taken from the interrupted run (--resume), see below."
  else
    echo "Firmware version (SBRANCH): $SBRANCH"
  fi
}

# Copies GLUON_TARGETS into ENABLED_TARGETS, dropping the entries that are
# disabled with a leading "-".
get_enabled_targets ()
{
  ENABLED_TARGETS=()

  local TARGET

  for TARGET in "${GLUON_TARGETS[@]}"; do
    if [[ $TARGET == -* ]]; then
      continue
    fi
    ENABLED_TARGETS+=( "$TARGET" )
  done

  if (( ${#ENABLED_TARGETS[@]} == 0 )); then
    abort "No targets enabled. Check GLUON_TARGETS in the build configuration."
  fi
}
generate_site_config ()
{
  local RELBRANCH="${1}"
  local GLUONBRANCH="${2}"
  local TEMPLATE_NAME="${3}"
  local SITE_CODE="${4}"
  local DOMAIN_NR="${5}"
  local SITE_SMALL="${6}"
  local SITE_BIG="${7}"
  local FF_PREFIX="${8}"
  local META_PREFIX="${9}"
  local MESH_SSID="${10}"
  local DOMAIN_NAME="${11}"
  local SUPERNODE_DEFAULT="${12}"
  local V4_PREFIX="${13}"
  local V6_PREFIX="${14}"
  local WIFICH_24="${15}"
  local WIFICH_5="${16}"
  local MAP_LAT="${17}"
  local MAP_LON="${18}"
  local MAP_ZOOM="${19}"
  local DOMAIN_HASH="${20}"
  local META_NAME="${21}"
  local META_WEBSITE="${22}"
  local MAP_WEBSITE="${23}"
  local FWWEBSITE_HOST="${24}"
  local FWWEBSITE_TLD="${25}"
  local OPKG_FQDN="${26}"
  local SUPERNODE_TLD="${27}"
  local DOMAIN_REGION_DE="${28}"
  local DOMAIN_REGION_EN="${29}"
  local SETUP_SKIP="${30}"
  local KEY_FILE_SIGN="${31}"
  local KEY_FILE_SSH="${32}"
  local DOMAIN_LONGNAME="${33}"

  echo "Generating site $SITE_CODE..."

  local DIR="assembled/$TEMPLATE_NAME/$SITE_CODE"

  mkdir -p "assembled/$TEMPLATE_NAME"
  cp -r -L "templates/$TEMPLATE_NAME" "$DIR"

  replace_string_in_files "$DIR" SBRANCH          "$SBRANCH"
  replace_string_in_files "$DIR" RELBRANCH        "$RELBRANCH"
  replace_string_in_files "$DIR" GLUONBRANCH      "$GLUONBRANCH"
  replace_string_in_files "$DIR" SITECODE         "$SITE_CODE"
  replace_string_in_files "$DIR" DOMAINNR         "$DOMAIN_NR"
  replace_string_in_files "$DIR" SITESMALL        "$SITE_SMALL"
  replace_string_in_files "$DIR" SITEBIG          "$SITE_BIG"
  replace_string_in_files "$DIR" FFPREFIX         "$FF_PREFIX"
  replace_string_in_files "$DIR" METAPREFIX       "$META_PREFIX"
  replace_string_in_files "$DIR" MESHSSID         "$MESH_SSID"
  replace_string_in_files "$DIR" DOMAINNAME       "$(echo $DOMAIN_NAME|sed -e 's/_/\ /g')"
  replace_string_in_files "$DIR" SUPERNODEDEFAULT "$SUPERNODE_DEFAULT"
  replace_string_in_files "$DIR" V4PREFIX         "$V4_PREFIX"
  replace_string_in_files "$DIR" V6PREFIX         "$V6_PREFIX"
  replace_string_in_files "$DIR" WIFICH24         "$WIFICH_24"
  replace_string_in_files "$DIR" WIFICH5          "$WIFICH_5"
  replace_string_in_files "$DIR" MAPLAT           "$MAP_LAT"
  replace_string_in_files "$DIR" MAPLON           "$MAP_LON"
  replace_string_in_files "$DIR" MAPZOOM          "$MAP_ZOOM"
  replace_string_in_files "$DIR" DOMAINHASH       "$DOMAIN_HASH"
  replace_string_in_files "$DIR" METANAME         "$(echo $META_NAME|sed -e 's/_/\ /g')"
  replace_string_in_files "$DIR" METAWEBSITE      "$META_WEBSITE"
  replace_string_in_files "$DIR" MAPWEBSITE       "$MAP_WEBSITE"
  replace_string_in_files "$DIR" FWWEBSITEHOST    "$FWWEBSITE_HOST"
  replace_string_in_files "$DIR" FWWEBSITETLD     "$FWWEBSITE_TLD"
  replace_string_in_files "$DIR" OPKGFQDN         "$OPKG_FQDN"
  replace_string_in_files "$DIR" SUPERNODETLD     "$SUPERNODE_TLD"
  replace_string_in_files "$DIR" DOMAINREGIONDE   "$(echo $DOMAIN_REGION_DE|sed -e 's/_/\ /g')"
  replace_string_in_files "$DIR" DOMAINREGIONEN   "$(echo $DOMAIN_REGION_EN|sed -e 's/_/\ /g')"
  replace_string_in_files "$DIR" SETUPSKIP        "$SETUP_SKIP"
  replace_string_in_files "$DIR" KEYFILESIGN      "$(cat buildkeys/$KEY_FILE_SIGN|sed ':a;N;$!ba;s/\n/\\n/g')"
  replace_string_in_files "$DIR" KEYFILESSH       "$(cat buildkeys/$KEY_FILE_SSH|sed ':a;N;$!ba;s/\n/\\n/g')"
  replace_string_in_files "$DIR" DOMAINLONGNAME   "$(echo $DOMAIN_LONGNAME|sed -e 's/_/\ /g')"

  # Create the log file, or truncate it if it already exists.
  get_site_log_filename  "$TEMPLATE_NAME"  "$SITE_CODE"
  echo -n "" >"$LOG_FILENAME"
}


generate_all_site_configs ()
{
  echo "Generating sites for sbranch $SBRANCH ..."

  rm -rf assembled

  local -i  index
  for (( index=0; index < ${#ALL_SITE_RELBRANCHES[@]}; index += 1 )); do
    generate_site_config "${ALL_SITE_RELBRANCHES[$index]}" \
                          "${ALL_SITE_GLUON_BRANCHES[$index]}" \
                          "${ALL_SITE_TEMPLATE_NAMES[$index]}" \
                          "${ALL_SITE_CODES[$index]}" \
                          "${ALL_SITE_DOMAIN_NRS[$index]}" \
                          "${ALL_SITE_SITE_SMALLS[$index]}" \
                          "${ALL_SITE_SITE_BIGS[$index]}" \
                          "${ALL_SITE_FF_PREFIXS[$index]}" \
                          "${ALL_SITE_META_PREFIXS[$index]}" \
                          "${ALL_SITE_MESH_SSIDS[$index]}" \
                          "${ALL_SITE_DOMAIN_NAMES[$index]}" \
                          "${ALL_SITE_SUPERNODE_DEFAULTS[$index]}" \
                          "${ALL_SITE_V4_PREFIXS[$index]}" \
                          "${ALL_SITE_V6_PREFIXS[$index]}" \
                          "${ALL_SITE_WIFICH_24S[$index]}" \
                          "${ALL_SITE_WIFICH_5S[$index]}" \
                          "${ALL_SITE_MAP_LATS[$index]}" \
                          "${ALL_SITE_MAP_LONS[$index]}" \
                          "${ALL_SITE_MAP_ZOOMS[$index]}" \
                          "${ALL_SITE_DOMAIN_HASHS[$index]}" \
                          "${ALL_SITE_META_NAMES[$index]}" \
                          "${ALL_SITE_META_WEBSITES[$index]}" \
                          "${ALL_SITE_MAP_WEBSITES[$index]}" \
                          "${ALL_SITE_FWWEBSITE_HOSTS[$index]}" \
                          "${ALL_SITE_FWWEBSITE_TLDS[$index]}" \
                          "${ALL_SITE_OPKG_FQDNS[$index]}" \
                          "${ALL_SITE_SUPERNODE_TLDS[$index]}" \
                          "${ALL_SITE_DOMAIN_REGION_DES[$index]}" \
                          "${ALL_SITE_DOMAIN_REGION_ENS[$index]}" \
                          "${ALL_SITE_SETUP_SKIPS[$index]}" \
                          "${ALL_SITE_KEY_FILE_SIGNS[$index]}" \
                          "${ALL_SITE_KEY_FILE_SSHS[$index]}" \
                          "${ALL_SITE_DOMAIN_LONGNAMES[$index]}"
  done

  echo "Finished generating sites."
}

append_quoted_arg ()
{
  local APPEND_TO_VAR_NAME="$1"
  local APPEND_ARG_NAME="$2"
  local APPEND_PATH="$3"

  printf -v "$APPEND_TO_VAR_NAME"  "%s $APPEND_ARG_NAME=%q"  "${!APPEND_TO_VAR_NAME}"  "$APPEND_PATH"
}

# Assembles the make arguments for one site into the caller's ARGS variable.
build_make_args ()
{
  local RELBRANCH="$1"
  local TEMPLATE_NAME="$2"
  local SITE_CODE="$3"

  ARGS=""

  append_quoted_arg  ARGS  GLUON_SITEDIR    "$SANDBOX_DIR/assembled/$TEMPLATE_NAME/$SITE_CODE"
  append_quoted_arg  ARGS  GLUON_IMAGEDIR   "$SANDBOX_DIR/images/running/$TEMPLATE_NAME/$SITE_CODE"
  # Die Paketausgabe liegt im Laufverzeichnis, nicht im Gluon-Baum: sie wandert
  # beim abschliessenden Umbenennen mit nach images-<ts>/packages - genau
  # dorthin, wo sie frueher erst per mv am Ende hinkam. Vor allem aber liegt sie
  # damit ausserhalb eines Overlays, das ein Worker am Ende verwirft.
  #
  # GLUON_MODULEDIR stand hier ebenfalls, wird aber von Gluon 2023.2 nicht mehr
  # gelesen (kein Treffer im Makefile oder in scripts/) - ein Ueberbleibsel
  # aelterer Versionen, darum entfernt.
  append_quoted_arg  ARGS  GLUON_PACKAGEDIR "$SANDBOX_DIR/images/running/packages"
  append_quoted_arg  ARGS  GLUON_SITE_VERSION "$GLUON_SITE_VERSION"
  # For the Gluon build system, BROKEN=1 means "use the experimental/unstable branch".
  append_quoted_arg  ARGS  BROKEN "$BROKEN"

  if [ "$BUILD_LOG" = true ]; then
    append_quoted_arg  ARGS  BUILD_LOG "1"
  fi

  # Autoupdater, see the Gluon 2023.2.x documentation (user/getting_started):
  # GLUON_AUTOUPDATER_ENABLED is the build time default for newly installed
  # nodes, GLUON_AUTOUPDATER_BRANCH overrides the branch from site.conf and
  # also selects the branch that "make manifest" generates a manifest for.
  # The old GLUON_BRANCH is deprecated and deliberately not set any more.
  if [ "$AUTOUPDATER_ENABLED" = true ]; then
    append_quoted_arg  ARGS GLUON_AUTOUPDATER_ENABLED "1"
  else
    append_quoted_arg  ARGS GLUON_AUTOUPDATER_ENABLED "0"
  fi
  append_quoted_arg  ARGS GLUON_AUTOUPDATER_BRANCH "$RELBRANCH"
}

# --------------------------------------------------------------------------
# Zustand eines Laufs, damit ein abgebrochener Bau fortgesetzt werden kann
#
# Der Bau schreibt seine Images nach images/running und benennt das Verzeichnis
# erst ganz am Ende nach images/images-<epoch> um. Ein liegengebliebenes
# images/running heisst deshalb: der Lauf ist nicht durchgelaufen. Genau daran
# wird ein Resume erkannt, und die Zustandsdatei liegt darin - sie entsteht und
# verschwindet also mit dem Lauf, ohne eigene Lebensdauer.
#
# Bis hierher war ein liegengebliebenes images/running still gefaehrlich: der
# naechste Lauf schrieb hinein und benannte am Ende alles zusammen um. Images
# aus zwei Laeufen mit verschiedenen SBRANCHes landeten in einem Verzeichnis,
# und das Manifest deckte nur einen davon ab. Ohne --resume bricht der Lauf
# jetzt ab, statt das stillschweigend zu tun.

STATE_FILE=""

# Kennzeichnet die Eingaben eines Laufs. Weicht der Fingerabdruck beim Resume
# ab, wurde in der Zwischenzeit etwas geaendert - dann wird abgelehnt, denn
# sonst mischten sich Images aus zwei Quellstaenden in einem Manifest.
#
# Erfasst wird, was in die Images eingeht: Templates, Patches, die vier
# Konfigurationsdateien und die Liste dessen, was gebaut werden soll. Bewusst
# nicht ueber "git status", denn dann haette schon ein Commit an docs/ oder eine
# Korrektur an build.sh selbst die Fortsetzung verweigert - beides aendert kein
# einziges Byte im Image.
#
# Ebenfalls nicht erfasst: SBRANCH, DATE_SUFFIX und GLUON_SITE_VERSION. Die
# gehoeren zum Lauf und werden uebernommen statt verglichen, sie waeren beim
# Resume ohnehin immer anders.
build_fingerprint ()
{
  local DIR
  for DIR in "$SANDBOX_DIR/templates" "$SANDBOX_DIR/patches"; do
    if [ ! -d "$DIR" ]; then
      abort "The run fingerprint needs the directory \"$DIR\", which does not exist."
    fi
  done

  local LISTING
  LISTING="$( {
    echo "order=$BUILD_ORDER"
    echo "targets=${BUILD_TARGETS[*]}"
    echo "domains=${ALL_SITE_TEMPLATE_NAMES[*]}"

    local FILE
    for FILE in "$BUILD_CONF_FILE" \
                "$SANDBOX_DIR/build.local.conf" \
                "$TARGETS_CONF_FILE" \
                "$DOMAINS_CONF_FILE" \
                "$SITES_FILE"; do
      if [ -f "$FILE" ]; then
        echo "datei=$(basename -- "$FILE")"
        cat -- "$FILE"
      fi
    done

    # Editorsicherungen ("modules~") liegen mit im Baum, gehen aber nicht in den
    # Bau ein. Sortiert, damit die Reihenfolge nicht vom Dateisystem abhaengt.
    find -L "$SANDBOX_DIR/templates" "$SANDBOX_DIR/patches" \
         -type f  ! -name '*~'  -print0 \
      | sort --zero-terminated \
      | xargs --null --no-run-if-empty sha256sum
  } )"

  # Faende find nichts, waere der Fingerabdruck der immergleiche Hash der drei
  # Kopfzeilen - und jede Fortsetzung ginge durch, egal was sich geaendert hat.
  local -i FILE_COUNT
  FILE_COUNT="$(grep -c '^[0-9a-f]\{64\}  ' <<< "$LISTING" || true)"
  if (( FILE_COUNT == 0 )); then
    abort "The run fingerprint found no file at all under \"$SANDBOX_DIR/templates\" and \"$SANDBOX_DIR/patches\"."
  fi

  sha256sum <<< "$LISTING" | cut -d" " -f1
}

# Dieselben Eingaben wie build_fingerprint, aber als Liste je Posten, damit
# sich bei einem abgelehnten --resume sagen laesst, WAS sich geaendert hat.
# Die Konfigurationsdateien stehen hier nur mit ihrem Hash, nicht mit Inhalt:
# die Liste liegt in images/running/, und das ist je nach Host ueber einen
# Webserver lesbar (build.local.conf gehoert dort nicht hin).
# build_fingerprint selbst bleibt unveraendert, sonst liesse sich ein mit
# einem aelteren build.sh unterbrochener Lauf nicht mehr fortsetzen.
fingerprint_details ()
{
  echo "order=$BUILD_ORDER"
  echo "targets=${BUILD_TARGETS[*]}"
  echo "domains=${ALL_SITE_TEMPLATE_NAMES[*]}"
  local FILE
  for FILE in "$BUILD_CONF_FILE" \
              "$SANDBOX_DIR/build.local.conf" \
              "$TARGETS_CONF_FILE" \
              "$DOMAINS_CONF_FILE" \
              "$SITES_FILE"; do
    if [ -f "$FILE" ]; then
      echo "datei=$(basename -- "$FILE") $(sha256sum -- "$FILE" | cut -d" " -f1)"
    fi
  done
  find -L "$SANDBOX_DIR/templates" "$SANDBOX_DIR/patches" \
       -type f  ! -name '*~'  -print0 \
    | sort --zero-terminated \
    | xargs --null --no-run-if-empty sha256sum \
    | sed "s|  $SANDBOX_DIR/|  |"
}

# Vergleicht die gespeicherte Detailliste mit der aktuellen und gibt die
# Unterschiede aus, hoechstens 20 Zeilen.
explain_fingerprint_change ()
{
  local OLD="$1"
  if [ ! -f "$OLD" ]; then
    echo "  (No details: the run was started by an older build.sh without .build-fingerprint.)"
    return 0
  fi
  fingerprint_details | awk -v old="$OLD" '
    function key(l) { if (l ~ /^[0-9a-f]{64}  /) return substr(l, 67)
                      if (l ~ /^datei=/) { split(l, a, " "); return a[1] }
                      return substr(l, 1, index(l, "=") - 1) }
    function show(k) { return (k ~ /^datei=/) ? substr(k, 7) : k }
    function val(l) { if (l ~ /^[0-9a-f]{64}  /) return substr(l, 1, 64)
                      if (l ~ /^datei=/) { split(l, a, " "); return a[2] }
                      return substr(l, index(l, "=") + 1) }
    BEGIN { while ((getline l < old) > 0) { k = key(l); o[k] = val(l); ord[++n] = k } }
    { k = key($0); v = val($0); seen[k] = 1
      if (!(k in o))       out[++m] = "  added:   " show(k)
      else if (o[k] != v) {
        if (k ~ /^(order|targets|domains)$/) out[++m] = "  " k ": " o[k] " -> " v
        else out[++m] = "  changed: " show(k)
      } }
    END { for (i = 1; i <= n; i++) if (!(ord[i] in seen)) out[++m] = "  removed: " show(ord[i])
          for (i = 1; i <= m && i <= 20; i++) print out[i]
          if (m > 20) print "  ... and " (m - 20) " more"
          if (m == 0) print "  (No difference in the detail list, although the fingerprint differs - should not happen.)" }'
}

state_init ()
{
  local RUNNING_DIR="$SANDBOX_DIR/images/running"
  STATE_FILE="$RUNNING_DIR/.build-state"

  mkdir -p "$RUNNING_DIR"

  # Erst in eine Variable: in der Ersetzung unten wuerde ein Fehlschlag von
  # errexit nicht bemerkt, und die Datei enthielte einen leeren Fingerabdruck.
  local FINGERPRINT
  FINGERPRINT="$(build_fingerprint)"

  {
    echo "# State of a running build.sh run. Removed when the run completes and"
    echo "# the directory gets its final name."
    echo "sbranch=$SBRANCH"
    echo "date_suffix=$DATE_SUFFIX"
    echo "site_version=$GLUON_SITE_VERSION"
    echo "fingerprint=$FINGERPRINT"
    echo "started=$(date --iso-8601=seconds)"
  } > "$STATE_FILE"
  fingerprint_details > "$RUNNING_DIR/.build-fingerprint"
  sync
}

# Uebernimmt SBRANCH und DATE_SUFFIX aus der Zustandsdatei. Beide muessen ueber
# den ganzen Bau gleich bleiben: SBRANCH steht im Imagenamen und im Manifest
# und wechselt bei SBRANCH_MODE=date stuendlich, DATE_SUFFIX benennt das
# Ausgabeverzeichnis, GLUON_SITE_VERSION steht in der site.conf und wechselt
# taeglich. Neu berechnet ergaeben sie einen Lauf mit zwei Release-Strings.
state_resume ()
{
  local RUNNING_DIR="$SANDBOX_DIR/images/running"
  STATE_FILE="$RUNNING_DIR/.build-state"

  if [ ! -f "$STATE_FILE" ]; then
    abort "\"$RUNNING_DIR\" exists, but without a state file: it comes from a run of an older build.sh that had no resume support. Start afresh with --restart, or remove the directory by hand."
  fi

  local OLD_FINGERPRINT NEW_FINGERPRINT
  OLD_FINGERPRINT="$(sed -n 's/^fingerprint=//p' "$STATE_FILE")"
  NEW_FINGERPRINT="$(build_fingerprint)"

  if [ "$OLD_FINGERPRINT" != "$NEW_FINGERPRINT" ]; then
    echo "What changed since the interrupted run:"
    explain_fingerprint_change "$RUNNING_DIR/.build-fingerprint"
    abort "This run cannot be resumed: the inputs have changed since it was interrupted - the templates, the patches, one of the configuration files, or the target or domain list. Images built from two different sources do not belong under one manifest. Start afresh with --restart (it removes \"$RUNNING_DIR\" and reports what gets thrown away), or remove the directory by hand."
  fi

  SBRANCH="$(sed -n 's/^sbranch=//p' "$STATE_FILE")"
  DATE_SUFFIX="$(sed -n 's/^date_suffix=//p' "$STATE_FILE")"
  GLUON_SITE_VERSION="$(sed -n 's/^site_version=//p' "$STATE_FILE")"

  [ -n "$SBRANCH" ] || abort "The state file has no sbranch."
  [ -n "$DATE_SUFFIX" ] || abort "The state file has no date_suffix."
  [ -n "$GLUON_SITE_VERSION" ] || abort "The state file has no site_version."

  # "make clean" wuerde genau das wegwerfen, worauf fortgesetzt werden soll.
  if [ "$MAKECLEAN" = true ]; then
    echo "Turning MAKECLEAN off for the resumed run: it would delete the very tree that is being resumed on."
    MAKECLEAN=false
  fi

  local -i DONE_BUILDS DONE_DOMAINS
  DONE_BUILDS="$(  grep -c "^build	"    "$STATE_FILE" || true )"
  DONE_DOMAINS="$( grep -c "^finalize	" "$STATE_FILE" || true )"

  echo "Resuming the run started at $(sed -n 's/^started=//p' "$STATE_FILE")."
  echo "  Release:      $SBRANCH"
  echo "  Site version: $GLUON_SITE_VERSION"
  echo "  Output dir:   images-$DATE_SUFFIX"
  echo "  Already done: $DONE_BUILDS of $(( ${#ALL_SITE_TEMPLATE_NAMES[@]} * ${#BUILD_TARGETS[@]} )) domain x target units, $DONE_DOMAINS of ${#ALL_SITE_TEMPLATE_NAMES[@]} domains finalized"

  echo "resumed=$(date --iso-8601=seconds)" >> "$STATE_FILE"
  sync
}

# Angehaengt wird erst NACH einer fertigen Einheit: ein harter Abbruch
# mittendrin darf sie nicht als erledigt hinterlassen. Lieber einmal zu viel
# bauen als ein halbes Image ausliefern.
#
# Das "sync" ist der eigentliche Punkt der Uebung. Genau der Fall, fuer den es
# den Resume gibt - die USV meldet fuenf Minuten und der Hypervisor faehrt
# herunter -, ist auch der Fall, in dem ein noch im Seitencache haengender
# Anhang verloren ginge. Es faellt einmal je fertigem Target an, also im
# Minutenabstand.
state_mark ()
{
  local KIND="$1" TEMPLATE_NAME="$2" SITE_CODE="$3" TARGET="${4:--}"
  [ -n "$STATE_FILE" ] || return 0
  printf '%s\t%s\t%s\t%s\n' "$KIND" "$TEMPLATE_NAME" "$SITE_CODE" "$TARGET" >> "$STATE_FILE"
  sync
}

state_has ()
{
  local KIND="$1" TEMPLATE_NAME="$2" SITE_CODE="$3" TARGET="${4:--}"
  [ -n "$STATE_FILE" ] || return 1
  # -x, damit die Zeile ganz passen muss: ein Teiltreffer haette ein Target
  # als erledigt gelesen, dessen Name nur der Anfang eines anderen ist.
  grep -qxF "$(printf '%s\t%s\t%s\t%s' "$KIND" "$TEMPLATE_NAME" "$SITE_CODE" "$TARGET")" "$STATE_FILE"
}


# Holt vorab alle Quellen, die der Bau braucht, mit Wiederholung.
#
# Warum vorweg: ohne das werden Quellen erst waehrend des Bauens geholt. Ein
# Netzaussetzer in Stunde drei beendet dann den ganzen Lauf, weil "make" mit
# ungleich null zurueckkommt und errexit greift. Vorgezogen trifft derselbe
# Aussetzer einen billigen, beliebig wiederholbaren Schritt am Anfang - und was
# einmal in dl/ liegt, bleibt liegen, ein spaeterer Lauf braucht dafuer kein
# Netz mehr. Besonders fuer die git-basierten Pakete des Feeds: die haben
# keinen PKG_MIRROR_HASH und werden je Architektur frisch von GitHub geklont.
#
# Einmal je Target mit dem ersten Site-Verzeichnis genuegt: die Paketauswahl
# steht in image-customization.lua, und alle Domain-Vorlagen sind Symlinks auf
# "common", waehlen also dieselben Pakete.
#
# Sollte das einmal nicht mehr stimmen, faellt trotzdem nichts aus: was hier
# fehlt, wird beim Bauen nachgeholt wie bisher. Der Schritt beschleunigt und
# entschaerft, er ist keine Voraussetzung - deshalb bricht er auch nur nach
# DOWNLOAD_ATTEMPTS vergeblichen Versuchen ab und nicht beim ersten.
download_sources ()
{
  local ARGS="$1"

  if (( DOWNLOAD_ATTEMPTS <= 0 )); then
    echo "Skipping the download step (DOWNLOAD_ATTEMPTS is $DOWNLOAD_ATTEMPTS)."
    return 0
  fi

  local -i target_index
  local TARGET MAKE_CMD
  local -i attempt

  for (( target_index=0; target_index < ${#TARGETS[@]}; target_index += 1 )); do

    TARGET="${TARGETS[target_index]}"
    printf -v MAKE_CMD "make download GLUON_TARGET=%q  %s"  "$TARGET"  "$ARGS"

    for (( attempt=1; attempt <= DOWNLOAD_ATTEMPTS; attempt += 1 )); do

      echo "Downloading the sources for target $TARGET (attempt $attempt of $DOWNLOAD_ATTEMPTS) ..."
      echo "$MAKE_CMD"

      if eval "$MAKE_CMD"; then
        break
      fi

      if (( attempt >= DOWNLOAD_ATTEMPTS )); then
        abort "Could not download the sources for target $TARGET after $DOWNLOAD_ATTEMPTS attempts."
      fi

      echo "Download failed, retrying in $DOWNLOAD_RETRY_DELAY seconds ..."
      sleep "$DOWNLOAD_RETRY_DELAY"

    done

  done
}


# Brings the Gluon tree into the state that every domain is then built against:
# optionally reset it, optionally clean it for all targets, apply the patches,
# and run "make update".
#
# This runs exactly once per build.sh run, before the first domain. The tree is
# neither domain- nor target-specific, so the following domains reuse it as is.
# It is passed the first site only because "make" needs a valid GLUON_SITEDIR
# and because prepare.sh is a copy inside each assembled site directory.
prepare_gluon_tree ()
{
  local RELBRANCH="$1"
  local GLUONBRANCH="$2"
  local TEMPLATE_NAME="$3"
  local SITE_CODE="$4"

  local ARGS
  build_make_args "$RELBRANCH" "$TEMPLATE_NAME" "$SITE_CODE"

  local MAKE_CMD
  local TARGET
  local -i target_index

  if [ "$GITRESET" = true ]; then
    echo "Resetting the Gluon tree to origin/$GLUONBRANCH ..."
    rm -rf .git/rebase-apply
    # Note: this only restores tracked files. The Gluon tree is deliberately
    # not cleaned as well: "make clean" runs before the post-update patches,
    # so the target files that only a patch creates (targets/ipq807x-generic,
    # targets/ipq40xx-chromium) have to survive from the previous run. Moving
    # every Gluon-tree patch into the pre-update phase would fix that; until
    # then, cleaning here would break "make clean" for those targets.
    git reset --hard "origin/$GLUONBRANCH"

    # Four git repositories are cascaded here: this build environment, the
    # Gluon tree, the OpenWrt tree inside it and the package feeds beside it.
    # A reset in one of them does not reach the others.
    #
    # The modules are *not* submodules: "make update" creates them with a plain
    # "git init" (Gluon's scripts/update.sh), and Gluon's .gitignore hides them
    # from the tree above. Neither Gluon nor OpenWrt 23.05 has a .gitmodules
    # file, so the "git submodule foreach --recursive" that used to stand here
    # iterated over nothing - in both trees. The module list has to come from
    # Gluon itself instead.
    #
    # The reset alone is not enough either: patches that add files (the Cudy
    # 3000 device trees, the zbit kernel patch) leave them behind, which makes
    # the tree half-patched - new files still there, changes to tracked files
    # gone. The next run then fails with "the next patch would create the file
    # ..., which already exists".
    #
    # "git clean -fd" without -x on purpose: OpenWrt's .gitignore covers dl,
    # bin, build_dir, staging_dir, tmp, logs, feeds and package/feeds, so the
    # download cache and the build tree are preserved.
    local MODULE
    local MODULE_LIST
    MODULE_LIST="$(GLUON_SITEDIR="$SANDBOX_DIR/assembled/$TEMPLATE_NAME/$SITE_CODE" \
                   bash -c '. scripts/modules.sh && echo "$GLUON_MODULES"')"

    for MODULE in $MODULE_LIST; do
      if [ ! -d "$MODULE/.git" ]; then
        echo "Module $MODULE does not exist yet, \"make update\" will create it."
        continue
      fi
      echo "Resetting the module $MODULE ..."
      git -C "$MODULE" reset --hard
      git -C "$MODULE" clean -fd
    done
  fi

  # The pre-update patches deposit files under patches/openwrt and
  # patches/packages in the Gluon tree; "make update" applies those to the
  # modules right afterwards (Gluon's scripts/patch.sh). Deposited later, they
  # would only take effect on the following run.
  echo "Applying the pre-update patches from patches/ ..."
  "$SANDBOX_DIR/assembled/$TEMPLATE_NAME/$SITE_CODE/prepare.sh" pre-update

  # "make update" obtains and patches the external repositories (OpenWrt and
  # the feeds). It has to come first: every other rule goes through "config",
  # which needs openwrt/staging_dir/hostpkg/bin/lua and otherwise aborts with
  # "You don't seem to have obtained the external repositories needed by Gluon;
  # please call `make update` first!". That includes "make clean".
  # The rule is target- and site-independent, so once per run is enough.
  echo "Gluon make update..."
  printf -v MAKE_CMD "make update %s"  "$ARGS"
  echo "$MAKE_CMD"
  eval "$MAKE_CMD"

  # Gluon's "make clean" is per target, so it has to be run for each of them.
  if [ "$MAKECLEAN" = true ]; then
    for (( target_index=0; target_index < ${#TARGETS[@]}; target_index += 1 )); do
      TARGET="${TARGETS[target_index]}"
      echo "Cleaning the Gluon tree for target: $TARGET ..."
      printf -v MAKE_CMD  "make clean GLUON_TARGET=%q  %s"  "$TARGET"  "$ARGS"
      echo "$MAKE_CMD"
      eval "$MAKE_CMD"
    done
  fi

  # The post-update patches have to run last: some of them patch openwrt/ (see
  # add-cudy-3000.sh), and "make update" overwrites local changes in the
  # external repositories.
  echo "Applying the post-update patches from patches/ ..."
  "$SANDBOX_DIR/assembled/$TEMPLATE_NAME/$SITE_CODE/prepare.sh" post-update

  # Erst jetzt, denn die post-update-Patches aendern Paketdefinitionen im
  # OpenWrt-Baum - vorher gezogen waeren es teils die falschen Quellen.
  download_sources "$ARGS"
}

# Builds one target of one domain. This is the unit of work that the two loop
# orders (see BUILD_ORDER) arrange differently.
build_site_target ()
{
  local RELBRANCH="$1"
  local TEMPLATE_NAME="$2"
  local SITE_CODE="$3"
  local TARGET="$4"

  local ARGS
  build_make_args "$RELBRANCH" "$TEMPLATE_NAME" "$SITE_CODE"

  # MAKE_J_VAL is 0 in the configuration when the job count should be derived
  # from the number of CPU cores.
  local JOB_COUNT="$MAKE_J_VAL"

  if (( JOB_COUNT == 0 )); then
    JOB_COUNT="$(( $(getconf _NPROCESSORS_ONLN) * MAKE_J_FACTOR ))"
  fi

  local MAKE_CMD

  echo "GLUONDEVICEs $GLUONDEVICES"
  echo "Building the firmware for site code: $SITE_CODE, target: $TARGET ..."
  printf -v MAKE_CMD "make GLUON_TARGET=%q"  "$TARGET"
  # For the Gluon build system, V=s means generate a full build log (show build commands, compiler warnings etc.).
  if [ "$VERBOSE_BUILD" = true ]; then
    MAKE_CMD+=" V=s"
  fi
  MAKE_CMD+=" $ARGS"
  MAKE_CMD+=" -j $JOB_COUNT  --output-sync=recurse"
  if [ ! -z "$GLUONDEVICES" ] && [ "${#GLUONDEVICES}" -gt 1 ]; then
    # Gequotet wie jedes andere Argument auch: MAKE_CMD laeuft durch eval, und
    # unquotet zerfaellt eine Liste mit mehr als einem Geraet in Woerter. Das
    # zweite und jedes weitere wurde dann als make-Ziel gelesen -
    # "No rule to make target 'ubiquiti-edgerouter-x-sfp-ka'". Mit einem
    # einzelnen Geraet fiel es nicht auf.
    append_quoted_arg  MAKE_CMD  GLUON_DEVICES  "$GLUONDEVICES"
    echo "for GLUONDEVICEs $GLUONDEVICES"
  fi
  echo "$MAKE_CMD"
  eval "$MAKE_CMD"

  collect_opkg_feeds "$TARGET"
}

# Sammelt die opkg-Feeds aus bin/packages/<arch>/ ein.
#
# Gluons scripts/copy_output.lua nimmt allein bin/targets/<target>/packages mit,
# also den Target-Baum mit den Kernelmodulen, und das auch nur bei einem Lauf
# ohne GLUON_DEVICES (dortige Zeile 94). Die Feeds mit den uebrigen Paketen
# bleiben liegen:
#
#   gluon, gluon_base   Gluons eigene Pakete
#   community           freifunk-gluon/community-packages
#   neanderfunk         unser eigener Feed, 13 Pakete
#   base, packages, ... was OpenWrt fuer diesen Bau uebersetzt hat
#
# Damit war bisher keines unserer 13 Pakete auf einem Knoten nachinstallierbar.
#
# Je Target, nicht einmal am Ende: bei MAKECLEAN=true reicht "make clean" an
# OpenWrt durch und raeumt bin/ vollstaendig weg, der naechste Target-Bau faende
# sonst nichts mehr vor.
#
# Ziel ist nach Target geschluesselt, nicht nach Architektur - genau wie der
# schon veroeffentlichte modules-Feed (/firmware/modules/gluon-<release>/<target>).
# Nach Architektur waere kuerzer, aber ath79-generic, -nand und -mikrotik teilen
# sich mips_24kc: die drei Laeufe erzeugen je einen eigenen Packages-Index ueber
# ihre je eigene Paketauswahl, und beim Zusammenkopieren gaebe der letzte den
# Ton an. Die ipk-Dateien der anderen blieben liegen, waeren aber nicht mehr
# indiziert. Ein Neuerzeugen des Index scheidet aus: die Knoten pruefen
# Signaturen (option check_signature in /etc/opkg.conf), und Packages.sig traegt
# unseren Bau-Schluessel. Also lieber ein paar Megabyte doppelt.
collect_opkg_feeds ()
{
  local TARGET="$1"

  local SRC="$SANDBOX_DIR/gluon/openwrt/bin/packages"
  # "ramips-mt7621" -> "ramips/mt7621", das ist Gluons bindir und zugleich %S
  # in den opkg-URLs der site.conf.
  local BINDIR="${TARGET/-//}"

  # Nach Gluon-Zweig getrennt: "v2025.1.x" -> "opkg-2025.1.x". Abgeschnitten
  # wird allein das fuehrende "v", sonst steht dort woertlich, was in Feld 2 der
  # sites-Datei steht - der Pfad laesst sich also dagegen grepen, und es gibt
  # keine Umformung, die spaeter auseinanderlaufen koennte.
  #
  # Ein Lauf hat immer genau einen Gluon-Baum, deshalb genuegt der erste
  # Eintrag - build.sh nimmt ihn an anderer Stelle schon fuer
  # "git reset --hard origin/$GLUONBRANCH".
  #
  # Warum ueberhaupt getrennt: die Verzeichnisse tragen zwar den Release im
  # Namen und kollidieren nicht, aber so laesst sich die Aufbewahrung je Zweig
  # steuern. Ein Knoten, der noch auf dem alten Zweig steht, verliert sein
  # Verzeichnis dann nicht, wenn beim anderen aufgeraeumt wird - und das gilt
  # in beide Richtungen, ob nun vorab oder nachtraeglich ausgerollt wird.
  local GLUON_BRANCH_LABEL="${ALL_SITE_GLUON_BRANCHES[0]-}"
  GLUON_BRANCH_LABEL="${GLUON_BRANCH_LABEL#v}"
  if [ -z "$GLUON_BRANCH_LABEL" ]; then
    abort "collect_opkg_feeds: der Gluon-Zweig steht nicht fest, Feld 2 der sites-Datei ist leer."
  fi

  local DEST="$SANDBOX_DIR/images/running/opkg-$GLUON_BRANCH_LABEL/gluon-$SBRANCH/$BINDIR"

  local arch_dir feed

  if [ ! -d "$SRC" ]; then
    echo "  bin/packages fehlt - keine opkg-Feeds einzusammeln."
    return 0
  fi

  for arch_dir in "$SRC"/*/; do
    [ -d "$arch_dir" ] || continue

    for feed in "$arch_dir"*/; do
      [ -d "$feed" ] || continue
      # Ohne Index ist das Verzeichnis fuer opkg wertlos.
      [ -f "$feed/Packages.gz" ] || continue

      mkdir -p "$DEST"
      cp -r "$feed" "$DEST/" \
        || abort "opkg-Feed $feed liess sich nicht nach $DEST kopieren."
    done
  done

  if [ -d "$DEST" ]; then
    echo "  opkg-Feeds nach images/running/opkg-$GLUON_BRANCH_LABEL/gluon-$SBRANCH/$BINDIR: $(ls "$DEST" | tr '\n' ' ')"
  fi
}

# Runs once per domain, after all of its targets have been built: manifest,
# signature and the copy of the site configuration next to the images.
finalize_site ()
{
  local RELBRANCH="$1"
  local TEMPLATE_NAME="$2"
  local SITE_CODE="$3"

  local ARGS
  build_make_args "$RELBRANCH" "$TEMPLATE_NAME" "$SITE_CODE"

  # Parameters for setting buildbot signatures
  local SIGN_ARGS=""
  SIGN_ARGS+=" $(cat "$SANDBOX_DIR/buildkeys/$SIGNKEY_FILE")"
  SIGN_ARGS+=" $SANDBOX_DIR/images/running/$TEMPLATE_NAME/$SITE_CODE/sysupgrade/$RELBRANCH.manifest"

  local MAKE_CMD
  local SIGN_CMD

  echo "Making manifest..."

  printf -v MAKE_CMD "make manifest %s"  "$ARGS"
  echo "$MAKE_CMD"
  eval "$MAKE_CMD"

  printf -v SIGN_CMD "$SANDBOX_DIR/esign $SIGN_ARGS"
  echo "$SIGN_CMD"
  eval "$SIGN_CMD"

  local SITE_IMAGE_DIR="$SANDBOX_DIR/images/running/$TEMPLATE_NAME/$SITE_CODE/site"

  echo "Copying build result to \"$SITE_IMAGE_DIR\" ..."
  # This directory may already exist from a previous run.
  mkdir --parents -- "$SITE_IMAGE_DIR"

  local -a RSYNC_EXCLUDE_ARGS=()
  local PATTERN

  for PATTERN in "${SITE_COPY_EXCLUDES[@]}"; do
    RSYNC_EXCLUDE_ARGS+=( --exclude "$PATTERN" )
  done

  # Ohne die Logs: das von finalize wird gerade noch geschrieben, und
  # build.log.gz setzt run_finalize_step erst danach zusammen.
  RSYNC_EXCLUDE_ARGS+=( --exclude '/build.log' --exclude '/build-*.log' )

  rsync --archive "$SANDBOX_DIR/assembled/$TEMPLATE_NAME/$SITE_CODE/" "${RSYNC_EXCLUDE_ARGS[@]}" "$SITE_IMAGE_DIR"

  # Keep the build script and all three configurations next to the images, so
  # that it stays visible with which settings they were built.
  cp -- "$SANDBOX_DIR/build.sh" "$SITE_IMAGE_DIR/"
  cp -- "$BUILD_CONF_FILE" "$TARGETS_CONF_FILE" "$DOMAINS_CONF_FILE" "$SITE_IMAGE_DIR/"

  # Das Patch-Protokoll liegt eine Ebene ueber dem Site-Verzeichnis und wuerde
  # vom rsync nicht erfasst. Es ist klein und zeigt, welche Patches beim
  # Vorbereiten des Baums angewendet wurden.
  if [ -f "$SANDBOX_DIR/assembled/prepare.log" ]; then
    cp -- "$SANDBOX_DIR/assembled/prepare.log" "$SITE_IMAGE_DIR/"
  fi

  write_build_info "$SITE_IMAGE_DIR" "$RELBRANCH" "$TEMPLATE_NAME" "$SITE_CODE"
}


# Rueckfallebene am Ende des Laufs: packt ein ungepacktes site/build.log, falls
# noch eines herumliegt. Im Normalfall gibt es keines mehr - die Logs werden
# gepackt, sobald ihr Schritt durch ist (store_target_log, finish_site_log).
# Uebrig bleiben kann eines nur aus einem Lauf, den ein aelteres build.sh
# begonnen hat und dieses mit --resume fortsetzt.
#
# Mit V=s sind das je Domain mehrere Dutzend MB, die sich um etwa Faktor 25
# packen lassen. gzip statt xz, weil zgrep, zcat und zless ueberall da sind -
# xz kaeme auf zwei Drittel der Groesse, aber mit xzgrep.
compress_build_logs ()
{
  local -i site_index
  local -i GEPACKT=0
  local LOG

  for (( site_index=0; site_index < ${#ALL_SITE_RELBRANCHES[@]}; site_index += 1 )); do
    LOG="$SANDBOX_DIR/images/running/${ALL_SITE_TEMPLATE_NAMES[$site_index]}/${ALL_SITE_CODES[$site_index]}/site/build.log"
    if [ -f "$LOG" ]; then
      gzip --force --best -- "$LOG"
      GEPACKT=$(( GEPACKT + 1 ))
    fi
  done

  (( GEPACKT == 0 )) || echo "Compressed $GEPACKT left-over build log(s)."
}

# Appends one record to the timing CSV. The file is meant for comparing build
# runs against each other, for example the two BUILD_ORDER variants.
log_build_time ()
{
  local PHASE="$1"
  local TEMPLATE_NAME="$2"
  local SITE_CODE="$3"
  local TARGET="$4"
  local ELAPSED_SECONDS="$5"
  local NOTE="${6:-}"

  # The run id and the build order have to be recorded because the file is
  # appended to across runs; without them the rows of two runs could not be
  # told apart. The template name is needed because the key and nokeys variants
  # of a domain share the same site code and differ only in the template.
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
         "$BUILD_RUN_ID" \
         "$(date --iso-8601=seconds)" \
         "$(date +%s)" \
         "$BUILD_ORDER" \
         "$PHASE" \
         "$TEMPLATE_NAME" \
         "$SITE_CODE" \
         "$TARGET" \
         "$ELAPSED_SECONDS" \
         "$NOTE" \
         >>"$BUILD_TIMES_FILE"
}

# Writes the closing run_end record, including the exit status. Installed as an
# EXIT trap by open_build_times_file, so that a run that is aborted or that
# fails still leaves a terminal record behind: a run whose rows are not closed
# by a run_end is incomplete and must not be read as a finished measurement.
finish_build_times_file ()
{
  local -i EXIT_STATUS="$?"

  # Do not fire from a subshell, for example the left hand side of a pipe.
  if [ "$BASHPID" != "$$" ]; then
    return
  fi

  # Laufende Worker nicht verwaisen lassen. Bricht der Hauptprozess ab - durch
  # Strg-C, kill oder einen Fehler -, liefen sie sonst weiter: Kindprozesse
  # beendet niemand, ihre Ergebnisse saemmelte keiner ein, und ein --resume
  # startete neue Worker in dieselben Overlay-Verzeichnisse, in denen die alten
  # noch schreiben.
  #
  # Nicht zu verwechseln mit einem gescheiterten Worker: den regelt
  # run_parallel, indem es die uebrigen zu Ende bringt. Dann ist
  # WORKER_LAUFEND hier schon leer.
  #
  # TERM an die ganze Gruppe, hoechstens 10 Sekunden warten - sofort weiter,
  # sobald alles weg ist -, dann KILL fuer den Rest.
  if (( ${#WORKER_LAUFEND[@]} > 0 )); then
    echo "Beende ${#WORKER_LAUFEND[@]} noch laufende(n) Worker: ${WORKER_LAUFEND[*]}" >&2
    local PID
    local -i FRIST=0 LEBT
    for PID in "${!WORKER_LAUFEND[@]}"; do
      kill -TERM -- "-$PID" 2>/dev/null || true
    done
    while (( FRIST < 10 )); do
      LEBT=0
      for PID in "${!WORKER_LAUFEND[@]}"; do
        kill -0 -- "-$PID" 2>/dev/null && LEBT=1
      done
      (( LEBT )) || break
      sleep 1
      FRIST+=1
    done
    for PID in "${!WORKER_LAUFEND[@]}"; do
      kill -KILL -- "-$PID" 2>/dev/null || true
    done
    wait "${!WORKER_LAUFEND[@]}" 2>/dev/null || true
    WORKER_LAUFEND=()
  fi

  # Am normalen Ende ist der Collector schon gestoppt und seine Empfehlung
  # uebernommen, dann tut das hier nichts. Bei einem Abbruch wertet er noch aus,
  # seine Empfehlung bleibt aber nur in der Datei dieses Laufs - ein
  # abgebrochener Lauf setzt die gueltige Empfehlung nicht.
  collector_stop

  local UPTIME
  read_uptime_as_integer

  log_build_time run_end "-" "-" "-" "$(( UPTIME - RUN_UPTIME_BEGIN ))" "exit=$EXIT_STATUS"
}

# Prepares the timing CSV. The file is appended to across runs, so that several
# runs can be compared without moving it out of the way first; the header is
# only written when the file is still empty or does not exist.
open_build_times_file ()
{
  local -i DOMAIN_COUNT="$1"
  local -i TARGET_COUNT="$2"

  BUILD_RUN_ID="$(date +%s)-$$"

  if [ ! -s "$BUILD_TIMES_FILE" ]; then
    echo "run_id,timestamp,epoch,build_order,phase,template,site_code,target,seconds,note" >"$BUILD_TIMES_FILE"
  fi

  local UPTIME
  read_uptime_as_integer
  RUN_UPTIME_BEGIN="$UPTIME"

  # The expected step count makes it possible to tell later how far a run got.
  log_build_time run_start "-" "-" "-" 0 \
                 "domains=$DOMAIN_COUNT targets=$TARGET_COUNT steps=$(( DOMAIN_COUNT * TARGET_COUNT )) sbranch=$SBRANCH"

  trap finish_build_times_file EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# Builds one domain x one target and records how long it took.
# Schliesst eine Domain ab: Manifest, Signatur, Site-Verzeichnis. Eine bereits
# abgeschlossene Domain wird uebersprungen - das braucht sowohl der Resume als
# auch der vorgezogene Abschluss unter BUILD_ORDER=domain, damit die Domain am
# Ende nicht ein zweites Mal drankommt.
run_finalize_step ()
{
  local -i site_index="$1"

  if state_has finalize "${ALL_SITE_TEMPLATE_NAMES[$site_index]}" "${ALL_SITE_CODES[$site_index]}"; then
    echo "Skipping site code ${ALL_SITE_CODES[$site_index]}: already finalized."
    drop_target_log_parts "${ALL_SITE_TEMPLATE_NAMES[$site_index]}" "${ALL_SITE_CODES[$site_index]}"
    return
  fi

  status_set finalize - "${ALL_SITE_CODES[$site_index]}"
  get_site_log_filename  "${ALL_SITE_TEMPLATE_NAMES[$site_index]}"  "${ALL_SITE_CODES[$site_index]}"

  local UPTIME
  read_uptime_as_integer
  local STEP_UPTIME_BEGIN="$UPTIME"

  {
    finalize_site "${ALL_SITE_RELBRANCHES[$site_index]}" \
                  "${ALL_SITE_TEMPLATE_NAMES[$site_index]}" \
                  "${ALL_SITE_CODES[$site_index]}"
  } 2>&1 | timestamp_lines | tee --append -- "$LOG_FILENAME"

  # Hinter der Pipeline: jetzt schreibt niemand mehr in das Log dieser Domain.
  finish_site_log "${ALL_SITE_TEMPLATE_NAMES[$site_index]}" "${ALL_SITE_CODES[$site_index]}"

  read_uptime_as_integer
  log_build_time finalize "${ALL_SITE_TEMPLATE_NAMES[$site_index]}" "${ALL_SITE_CODES[$site_index]}" "-" "$(( UPTIME - STEP_UPTIME_BEGIN ))"

  state_mark finalize "${ALL_SITE_TEMPLATE_NAMES[$site_index]}" "${ALL_SITE_CODES[$site_index]}"
  drop_target_log_parts "${ALL_SITE_TEMPLATE_NAMES[$site_index]}" "${ALL_SITE_CODES[$site_index]}"
}

run_build_step ()
{
  local -i site_index="$1"
  local -i target_index="$2"

  local SITE_CODE="${ALL_SITE_CODES[$site_index]}"
  local TEMPLATE_NAME="${ALL_SITE_TEMPLATE_NAMES[$site_index]}"
  local TARGET="${TARGETS[target_index]}"

  if state_has build "$TEMPLATE_NAME" "$SITE_CODE" "$TARGET"; then
    echo "Skipping site code $SITE_CODE, target $TARGET: already built in the interrupted run."
    return
  fi

  get_site_log_filename  "$TEMPLATE_NAME"  "$SITE_CODE"  "$TARGET"
  status_set "$BUILD_PHASE" "$TARGET" "$SITE_CODE"

  local UPTIME
  read_uptime_as_integer
  local STEP_UPTIME_BEGIN="$UPTIME"

  {
    build_site_target "${ALL_SITE_RELBRANCHES[$site_index]}" \
                      "${ALL_SITE_TEMPLATE_NAMES[$site_index]}" \
                      "$SITE_CODE" \
                      "$TARGET"
  } 2>&1 | timestamp_lines | tee --append -- "$LOG_FILENAME"

  read_uptime_as_integer
  local -i ELAPSED="$(( UPTIME - STEP_UPTIME_BEGIN ))"


  local ELAPSED_TIME_STR
  get_human_friendly_elapsed_time "$ELAPSED"
  echo "Finished site code $SITE_CODE, target $TARGET. Elapsed time: $ELAPSED_TIME_STR."

  log_build_time build "$TEMPLATE_NAME" "$SITE_CODE" "$TARGET" "$ELAPSED"

  # Erst hier, nach der Pipeline. Mit errexit und pipefail kommt der Ablauf nur
  # bis hierher, wenn make durchgelaufen ist.
  store_target_log "$TEMPLATE_NAME" "$SITE_CODE" "$TARGET"
  state_mark build "$TEMPLATE_NAME" "$SITE_CODE" "$TARGET"

  # Die Bauzeit fuer build-info.txt. Nach state_mark, damit nur gezaehlt wird,
  # was auch als erledigt gilt: ein Abbruch zwischen beiden liesse die Zeit
  # fehlen statt doppelt zaehlen.
  printf '%s/%s\t%s\n' "$TEMPLATE_NAME" "$SITE_CODE" "$ELAPSED" >> "$SITE_SECONDS_FILE"
}

# Targets given on the command line win, otherwise the enabled entries of
# GLUON_TARGETS from the build configuration are used.
#
# Steht vor dem Bau, weil der Fingerabdruck des Laufs die Targetliste enthaelt:
# eine Fortsetzung mit anderer Liste ist keine Fortsetzung.
declare -a BUILD_TARGETS=()


resolve_targets ()
{
  BUILD_TARGETS=("$@")

  if (( ${#BUILD_TARGETS[@]} == 0 )); then
    local -a ENABLED_TARGETS
    get_enabled_targets
    BUILD_TARGETS=( "${ENABLED_TARGETS[@]}" )
    echo "Building the ${#BUILD_TARGETS[@]} targets enabled in the build configuration."
  else
    echo "Building the ${#BUILD_TARGETS[@]} targets given on the command line."
  fi
}

# Meldet, was dieser Prozess gerade tut. Der Collector liest das und ordnet
# jede Probe der Phase zu, in der sie entstand.
#
# Ohne das sieht ein Collector nur Systemlast und kann eine untaetige
# prepare-Phase nicht von einem seriellen Imagebau unterscheiden - genau daran
# ist die erste Lastmessung auf wir-horst gescheitert: sie traf die
# prepare-Phase, und aufgefallen ist das nur, weil die aktiven Kerne nie ueber
# 2,2 stiegen.
#
# Eine Datei je Prozess, benannt nach dem Target des Workers oder "main". Die
# Phasen:
#
#   prepare    Baum vorbereiten (make update, Feeds): gut ein Kern
#   golden     Aufbau des golden tree, also mit Kompilierung: hohe Parallelitaet
#   build      ein Imagebau: ueberwiegend seriell - die Last, um die es geht
#   finalize   Manifest, Signatur, Kopie ins Site-Verzeichnis
#
# Geschrieben ueber eine temporaere Datei und mv: der Collector liest also nie
# eine halb geschriebene.
status_set ()
{
  local PHASE="$1" TARGET="${2:--}" DOMAIN="${3:--}"
  local NAME="${WORKER_TARGET:-main}"

  mkdir -p -- "$STATUS_DIR"
  printf 'phase=%s\ntarget=%s\ndomain=%s\nseit=%s\npid=%s\n' \
         "$PHASE" "$TARGET" "$DOMAIN" "$(date +%s)" "$$" > "$STATUS_DIR/$NAME.tmp"
  mv -f -- "$STATUS_DIR/$NAME.tmp" "$STATUS_DIR/$NAME"
}

# Meldet diesen Prozess ab: er tut nichts mehr, was der Collector zuordnen
# muesste.
status_clear ()
{
  rm -f -- "$STATUS_DIR/${WORKER_TARGET:-main}"
}

# Loest WORKERS=auto auf: die Empfehlung des letzten erfolgreichen Laufs,
# sonst WORKERS_AUTO_START. Danach ist WORKERS in jedem Fall eine Zahl.
resolve_workers ()
{
  if [ "$WORKERS" = auto ]; then
    local EMP="$METRICS_DIR/empfehlung.txt"
    if [ -f "$EMP" ]; then
      WORKERS="$(sed -n 's/^empfohlen=//p' "$EMP")"
      echo "WORKERS=auto: $WORKERS laut letztem Lauf - $(sed -n 's/^begruendung=//p' "$EMP")"
    else
      WORKERS="$WORKERS_AUTO_START"
      echo "WORKERS=auto: noch keine Empfehlung, Startwert $WORKERS (WORKERS_AUTO_START)."
    fi
  fi
  if ! [[ "$WORKERS" =~ ^[0-9]+$ ]] || (( WORKERS < 1 )); then
    abort "WORKERS muss eine Zahl ab 1 oder \"auto\" sein, ist \"$WORKERS\"."
  fi
}

# Startet den Collector im Hintergrund, siehe scripts/buildcollect.py.
collector_start ()
{
  [ "$METRICS" = true ] || return 0
  mkdir -p -- "$METRICS_DIR"
  # Live mitlesbar unter images/running/buildinfo/ (wandert am Ende mit ins
  # images-<ts>): Hardlinks auf CSV und Log, keine zweite Schreibstelle. Die
  # Dateien werden vorher angelegt - der Collector oeffnet mit "w", die Shell
  # mit ">", beides kuerzt dieselbe Inode, die Links bleiben gueltig. Geht das
  # nicht (anderes Dateisystem), gibt es eben nur die Kopie am Ende.
  : > "$METRICS_DIR/$BUILD_RUN_ID.csv"
  : > "$METRICS_DIR/$BUILD_RUN_ID.log"
  local LIVE="$SANDBOX_DIR/images/running/buildinfo"
  if mkdir -p -- "$LIVE" 2>/dev/null; then
    ln -f -- "$METRICS_DIR/$BUILD_RUN_ID.csv" "$LIVE/$BUILD_RUN_ID.metrics.csv" 2>/dev/null || true
    ln -f -- "$METRICS_DIR/$BUILD_RUN_ID.log" "$LIVE/$BUILD_RUN_ID.collector.log" 2>/dev/null || true
  fi
  python3 "$SANDBOX_DIR/scripts/buildcollect.py" \
    "$STATUS_DIR" "$METRICS_DIR/$BUILD_RUN_ID.csv" "$METRICS_DIR/$BUILD_RUN_ID.empfehlung.txt" \
    "$SANDBOX_DIR" "$WORKERS" "$BUILD_RUN_ID" "${#BUILD_TARGETS[@]}" \
    > "$METRICS_DIR/$BUILD_RUN_ID.log" 2>&1 &
  COLLECTOR_PID=$!
  echo "Metriken: $METRICS_DIR/$BUILD_RUN_ID.csv"
}

# Beendet den Collector; er wertet dabei aus. Mit "uebernehmen" wird seine
# Empfehlung zur gueltigen fuer den naechsten Lauf, sonst bleibt sie nur in der
# Datei dieses Laufs.
#
# Nur ein ERFOLGREICHER Lauf darf die Empfehlung setzen. Stirbt ein Lauf etwa
# an Speichermangel, weil zu viele Worker liefen, stammen die Daten davor aus
# der Phase, in der alles noch lief - und die Empfehlung koennte ausgerechnet
# "mehr Worker" lauten.
#
# Idempotent: am normalen Ende und noch einmal im EXIT-Trap gerufen.
collector_stop ()
{
  local UEBERNEHMEN="${1:-}"
  [ -n "$COLLECTOR_PID" ] || return 0
  kill -TERM "$COLLECTOR_PID" 2>/dev/null || true
  wait "$COLLECTOR_PID" 2>/dev/null || true
  COLLECTOR_PID=""
  cat -- "$METRICS_DIR/$BUILD_RUN_ID.log" 2>/dev/null || true
  if [ "$UEBERNEHMEN" = uebernehmen ] && [ -f "$METRICS_DIR/$BUILD_RUN_ID.empfehlung.txt" ]; then
    cp -f -- "$METRICS_DIR/$BUILD_RUN_ID.empfehlung.txt" "$METRICS_DIR/empfehlung.txt"
  fi
}

# Schaetzt vor dem Lauf, ob der Platz reicht, und faellt bei Mangel auf
# weniger Worker oder den seriellen Betrieb zurueck, statt nachts mitten im
# Lauf an einer vollen Platte zu scheitern.
#
# Die Schaetzung, Werte aus build.conf, gemessen am 09./10.09.2026:
#
#   je Domain x Target  SPACE_UNIT_MB   Images (~185 MB im Mittel ueber 22
#                                       Targets), das Paketverzeichnis (je
#                                       site_code, ~35 MB), das gepackte
#                                       Buildlog (~1 MB) und Luft
#   je Target, einmal   SPACE_TARGET_MB die eingesammelten opkg-Feeds
#   je Worker           SPACE_WORKER_BASE_MB + SPACE_WORKER_DOMAIN_MB je
#                                       Domain: das upperdir eines Workers
#                                       (2,8 GB fuer die erste Domain, 0,2 GB
#                                       je weitere)
#   Reserve             SPACE_RESERVE_MB
#
# Reicht es fuer den seriellen Lauf nicht, wird gleich hier abgebrochen - das
# ist der Moment, in dem es nichts kostet. Reicht es seriell, aber nicht fuer
# alle Worker, gibt es so viele Worker, wie passen; unter zwei heisst das
# seriell, mit der BUILD_ORDER aus der Konfiguration. Laut angekuendigt, damit
# niemand am Morgen ueber einen seriellen Lauf staunt.
#
# Bei --resume zaehlen nur die Domains, die noch nicht abgeschlossen sind; der
# Platz der fertigen ist schon belegt. Halb gebaute Domains zaehlen voll -
# lieber zu vorsichtig.
space_check ()
{
  [ "$SPACE_CHECK" = true ] || return 0

  local FREI
  FREI="$(disk_free_mb)"
  if [ -z "$FREI" ]; then
    echo "Platzschaetzung: df liefert fuer $SANDBOX_DIR nichts, wird uebersprungen."
    return 0
  fi

  local -i D=0 i
  local -i T=${#BUILD_TARGETS[@]}
  for (( i=0; i < ${#ALL_SITE_CODES[@]}; i += 1 )); do
    state_has finalize "${ALL_SITE_TEMPLATE_NAMES[$i]}" "${ALL_SITE_CODES[$i]}" || D+=1
  done

  local -i SERIELL=$(( D * T * SPACE_UNIT_MB + T * SPACE_TARGET_MB + SPACE_RESERVE_MB ))
  local -i JE_WORKER=$(( SPACE_WORKER_BASE_MB + D * SPACE_WORKER_DOMAIN_MB ))

  local ZUSATZ=""
  (( WORKERS > 1 )) && ZUSATZ=", dazu ~$(( JE_WORKER / 1024 )) GB je Worker"
  echo "Platz: $(( FREI / 1024 )) GB frei unter $SANDBOX_DIR; gebraucht ~$(( SERIELL / 1024 )) GB fuer $D Domains x $T Targets$ZUSATZ."

  if (( FREI < SERIELL )); then
    abort "Der Platz reicht nicht einmal fuer den seriellen Lauf: $(( FREI / 1024 )) GB frei, ~$(( SERIELL / 1024 )) GB gebraucht. Alte images-* wegraeumen, weniger Domains bauen, oder die Schaetzung in build.conf (SPACE_*) anpassen, falls sie fuer diesen Host zu hoch liegt."
  fi

  (( WORKERS > 1 )) || return 0

  local -i PASSEN=$(( (FREI - SERIELL) / JE_WORKER ))
  (( PASSEN >= WORKERS )) && return 0

  if (( PASSEN >= 2 )); then
    fat_warning "Platz reicht fuer $PASSEN statt $WORKERS Worker - dieser Lauf baut mit WORKERS=$PASSEN."
    DEGRADIERT+=( "WORKERS=$PASSEN statt $WORKERS: Plattenplatz" )
    WORKERS=$PASSEN
  else
    fat_warning "Platz reicht nicht fuer den Parallelbetrieb - dieser Lauf baut SERIELL (WORKERS=1, BUILD_ORDER=$BUILD_ORDER_KONFIG)."
    DEGRADIERT+=( "SERIELL statt mit $WORKERS Workern: Plattenplatz" )
    WORKERS=1
    BUILD_ORDER="$BUILD_ORDER_KONFIG"
  fi
}

# Uebernimmt im Worker den Zustand des Hauptlaufs. Ohne Pruefung und ohne
# Meldung: beides hat der Hauptprozess schon getan (state_init oder
# state_resume), und der Fingerabdruck muss hier nicht erneut verglichen
# werden - der Worker wurde von genau diesem Lauf gestartet.
#
# SBRANCH darf der Worker keinesfalls selbst berechnen: bei SBRANCH_MODE=date
# wechselt er stuendlich, ein Worker, der eine Stunde nach dem Hauptprozess
# startet, stuende sonst mit anderem Releasestring im selben Manifest.
state_attach ()
{
  STATE_FILE="$SANDBOX_DIR/images/running/.build-state"
  [ -f "$STATE_FILE" ] || abort "Worker: keine Zustandsdatei $STATE_FILE - er muss vom Hauptlauf gestartet werden."

  SBRANCH="$(sed -n 's/^sbranch=//p' "$STATE_FILE")"
  DATE_SUFFIX="$(sed -n 's/^date_suffix=//p' "$STATE_FILE")"
  GLUON_SITE_VERSION="$(sed -n 's/^site_version=//p' "$STATE_FILE")"

  # Die Laufkennung kommt ueber die Umgebung, damit die Zeilen des Workers in
  # BUILD_TIMES_FILE demselben Lauf zugeordnet werden wie die des Hauptprozesses.
  : "${BUILD_RUN_ID:?Worker ohne BUILD_RUN_ID - er muss vom Hauptlauf gestartet werden.}"
}

# Bereitet den Gluon-Baum vor und schreibt dabei prepare.log. Aus
# build_all_images herausgezogen, weil der Parallelbetrieb es nur fuer den
# Aufbau des golden tree braucht, und dann mit erzwungenem Reset und Clean.
run_prepare ()
{
  local PREPARE_LOG_FILENAME="$SANDBOX_DIR/assembled/prepare.log"
  echo "Preparing the Gluon tree. The log file is: $PREPARE_LOG_FILENAME"
  status_set prepare

  local UPTIME
  read_uptime_as_integer
  local PREPARE_UPTIME_BEGIN="$UPTIME"

  {
    prepare_gluon_tree "${ALL_SITE_RELBRANCHES[0]}" \
                       "${ALL_SITE_GLUON_BRANCHES[0]}" \
                       "${ALL_SITE_TEMPLATE_NAMES[0]}" \
                       "${ALL_SITE_CODES[0]}"
  } 2>&1 | timestamp_lines | tee -- "$PREPARE_LOG_FILENAME"

  read_uptime_as_integer
  log_build_time prepare "-" "-" "-" "$(( UPTIME - PREPARE_UPTIME_BEGIN ))"
}

# Laeuft IM Worker: baut genau ein Target ueber alle Domains. Was schon
# erledigt ist - im golden-Aufbau die erste Domain, beim --resume alles
# Fertige -, ueberspringt run_build_step selbst anhand der Zustandsdatei.
worker_run ()
{
  local WORKER_TARGET="$1"
  # run_build_step liest das Target ueber TARGETS[target_index]; im Worker
  # gibt es genau eins.
  local -a TARGETS=( "$WORKER_TARGET" )
  local -i site_index

  # Erst jetzt in den Baum wechseln, nicht schon beim Start: der Mount liegt
  # inzwischen darueber, und ein vorher betretenes Verzeichnis zeigte noch auf
  # den golden tree darunter.
  cd -- "$GLUON_DIR"

  for (( site_index=0; site_index < ${#ALL_SITE_RELBRANCHES[@]}; site_index += 1 )); do
    run_build_step "$site_index" 0
  done

  status_clear
}

# Startet einen Worker fuer ein Target, im Hintergrund, in einem frischen
# Overlay. Die Ausgabe geht nach $OVL_DIR/<target>.log - neben dem
# Overlay-Verzeichnis, nicht darin, damit sie das Verwerfen ueberlebt und bei
# einem Fehler noch nachzulesen ist. Die eigentlichen Buildlogs schreibt der
# Worker ohnehin je Domain nach build-<target>.log.
start_worker ()
{
  local TARGET="$1"
  local W="$OVL_DIR/$TARGET"

  ovl_discard_dir "$W"
  mkdir -p -- "$W/lower" "$W/upper" "$W/work"

  echo "Worker startet: $TARGET  (Ausgabe: $W.log)"

  # Aus SANDBOX_DIR heraus, nicht aus dem Gluon-Baum, in dem der Hauptprozess
  # gerade steht: dessen Pfad wird gleich ueberlagert, ein cwd dort saehe den
  # alten Baum statt des Overlays. build.sh verlangt ohnehin sein eigenes
  # Verzeichnis als cwd.
  #
  # Die Targetliste wird vollstaendig durchgereicht, damit BUILD_TARGETS im
  # Worker dieselbe ist - sie geht in das Zusammensetzen der Logs und in die
  # Fingerabdruecke ein.
  (
    cd -- "$SANDBOX_DIR"
    export BUILD_RUN_ID
    # setsid: eigene Prozessgruppe. Ein Signal an den Worker allein erreichte
    # sein make nicht - das ist ein Kind des Workers. An die Gruppe gerichtet
    # trifft es alles, was der Worker gestartet hat, und nicht den Hauptprozess.
    # Ohne fork, weil die Subshell kein Gruppenleiter ist; die PID in $! bleibt
    # also die des Workers, und damit auch die Gruppennummer.
    exec setsid unshare -Urm "$SANDBOX_DIR/scripts/ovl-enter.sh" \
      "$GLUON_DIR" "$W" "$GLUON_DIR" "$(id -u)" "$(id -g)" \
      "$BUILD_SH" "--worker=$TARGET" \
      "$BUILD_CONF_FILE" "$TARGETS_CONF_FILE" "$DOMAINS_CONF_FILE" "${BUILD_TARGETS[@]}"
  ) > "$W.log" 2>&1 &
}

# Der Scheduler: haelt bis zu WORKERS Worker gleichzeitig am Laufen, einen je
# Target, und startet fuer jedes fertige Target das naechste.
#
# Ein Worker je Target statt eines langlebigen Workers, der mehrere Targets
# aus einer Warteschlange nimmt: ein Worker kann sein upperdir nicht verwerfen,
# solange er darin laeuft - es wuechse ueber alle seine Targets. So bleibt
# jedes Delta bei einem Target (gemessen ~2,8 GB plus ~0,2 GB je Domain).
#
# Versetzter Start nur beim Hochfahren: die Last eines Builds ist bimodal,
# gleichzeitig gestartete Worker liefen anfangs synchron durch dieselben
# Phasen und ihre Vollastspitzen kollidierten. Danach driften sie ohnehin
# auseinander, ein Nachruecker startet sofort.
#
# Scheitert ein Worker, werden keine neuen mehr gestartet, die laufenden aber
# zu Ende gebracht: ihre Targets sind dann per state_mark gesichert, und ein
# --resume baut nur noch das Gescheiterte. Sofort alle abzubrechen verwarf
# die Arbeit aller anderen.
# Anfang und Ende der Parallelphase (Epoch), fuer den Worker-Verkehr in
# Erlang im Kasten am Ende, siehe print_run_summary.
PAR_START_EPOCH=""
PAR_END_EPOCH=""

run_parallel ()
{
  local -a WARTESCHLANGE=( "${BUILD_TARGETS[@]}" )
  local -a GESCHEITERT=()
  local -i GESTARTET=0
  local PID TARGET RC

  echo "Parallelbetrieb: ${#WARTESCHLANGE[@]} Targets, bis zu $WORKERS Worker, ${WORKER_START_DELAY}s Versatz beim Hochfahren."
  PAR_START_EPOCH="$(date +%s)"

  while (( ${#WARTESCHLANGE[@]} > 0 || ${#WORKER_LAUFEND[@]} > 0 )); do

    while (( ${#GESCHEITERT[@]} == 0 && ${#WARTESCHLANGE[@]} > 0 && ${#WORKER_LAUFEND[@]} < WORKERS )); do
      if (( GESTARTET > 0 && GESTARTET < WORKERS )); then
        sleep "$WORKER_START_DELAY"
      fi
      TARGET="${WARTESCHLANGE[0]}"
      WARTESCHLANGE=( "${WARTESCHLANGE[@]:1}" )
      start_worker "$TARGET"
      WORKER_LAUFEND[$!]="$TARGET"
      GESTARTET+=1
    done

    (( ${#WORKER_LAUFEND[@]} > 0 )) || break

    # Mit den PIDs, nicht ohne: sonst wartete wait -n auch auf andere
    # Hintergrundprozesse dieses Laufs. Mit errexit fuehrte ein Exitcode
    # ungleich null sofort zum Abbruch - daher das "|| RC=$?".
    RC=0
    wait -n -p PID "${!WORKER_LAUFEND[@]}" || RC=$?
    TARGET="${WORKER_LAUFEND[$PID]}"
    unset "WORKER_LAUFEND[$PID]"

    if (( RC == 0 )); then
      echo "Worker fertig: $TARGET"
      ovl_discard_dir "$OVL_DIR/$TARGET"
    else
      echo "Worker GESCHEITERT: $TARGET (Exitcode $RC) - siehe $OVL_DIR/$TARGET.log. Es werden keine weiteren gestartet, die laufenden ($((${#WORKER_LAUFEND[@]}))) noch zu Ende gebracht." >&2
      # Das Ende seines Logs hierher, damit die Ursache im Hauptlauf steht und
      # nicht nur ein Verweis auf eine Datei, die bei voller Platte leer sein
      # kann. Die ausfuehrlichen Buildlogs liegen je Domain in
      # assembled/<template>/<domain>/build-$TARGET.log.
      echo "  Letzte Zeilen von $OVL_DIR/$TARGET.log:" >&2
      tail -n 25 -- "$OVL_DIR/$TARGET.log" 2>/dev/null | sed 's/^/    | /' >&2 || true
      report_disk_if_full
      GESCHEITERT+=( "$TARGET" )
      # Overlay bewusst stehen lassen: sein upperdir zeigt, wie weit der
      # Worker kam.
    fi
  done

  PAR_END_EPOCH="$(date +%s)"

  if (( ${#GESCHEITERT[@]} > 0 )); then
    abort "${#GESCHEITERT[@]} Target(s) gescheitert: ${GESCHEITERT[*]}. Die uebrigen sind gebaut und gesichert; mit --resume wird nur noch das Gescheiterte gebaut."
  fi
}

# Parallelbetrieb: golden tree sicherstellen, dann alle Targets parallel.
build_parallel ()
{
  local GFP
  GFP="$(golden_fingerprint "${ALL_SITE_GLUON_BRANCHES[0]}")"

  if [ -f "$GOLDEN_FP_FILE" ] && [ "$(cat -- "$GOLDEN_FP_FILE")" = "$GFP" ]; then
    echo "Golden tree ist aktuell (Fingerabdruck ${GFP:0:16}) - prepare entfaellt, der Baum bleibt unberuehrt."
  else
    echo "Golden tree fehlt oder ist veraltet - er wird neu gebaut: prepare mit Reset und Clean, dann die erste Domain seriell ueber alle Targets."

    # Vorher weg, damit ein abgebrochener Aufbau nicht als gueltig gilt.
    rm -f -- "$GOLDEN_FP_FILE"

    # Fuer diesen Aufbau erzwungen, gleich wie konfiguriert: der golden tree
    # ist nur dann ein definierter Stand, wenn er von Grund auf entsteht.
    local GITRESET=true
    local MAKECLEAN=true
    run_prepare

    # Direkt im Baum, ohne Overlay - genau das soll ja im golden tree bleiben.
    # Als "golden" gemeldet: das ist Kompilierung, deren Last der Collector
    # nicht mit der eines Imagebaus vermengen darf.
    local BUILD_PHASE="golden"
    local -a TARGETS=( "${BUILD_TARGETS[@]}" )
    local -i target_index
    for (( target_index=0; target_index < ${#TARGETS[@]}; target_index += 1 )); do
      run_build_step 0 "$target_index"
    done

    mkdir -p -- "$OVL_DIR"
    echo "$GFP" > "$GOLDEN_FP_FILE"
    echo "Golden tree steht (Fingerabdruck ${GFP:0:16})."
  fi

  # Der Hauptprozess wartet jetzt nur noch auf die Worker und meldet sich ab.
  # Blieb seine Statusdatei auf "golden" stehen, verwarf der Collector jede
  # Probe des Parallelbetriebs (Bedingung: niemand in golden/prepare) - im
  # ersten Lauf auf wir-horst gab es so 0 von 6887 Proben mit allen Workern belegt.
  status_clear

  run_parallel
}

# Eckdaten des fertigen Laufs in einem Kasten, als Letztes im Log: Dauer,
# Umfang, Zahl der Images, Groessen, freier Platz. Groessen per du, Images
# ohne die .manifest-Dateien gezaehlt.
print_run_summary ()
{
  local DIR="$1"
  local -i SEK="$2"
  local -i D=${#ALL_SITE_RELBRANCHES[@]} T=${#BUILD_TARGETS[@]}
  # prepare-Zeit dieses Laufs aus der Zeiten-CSV (Spalten: run_id,...,phase
  # an 5., seconds an 9. Stelle)
  local -i PREP=0
  if [ -f "$BUILD_TIMES_FILE" ]; then
    PREP=$(awk -F, -v r="$BUILD_RUN_ID" '$1 == r && $5 == "prepare" { s += $9 } END { print s + 0 }' "$BUILD_TIMES_FILE")
  fi
  local ZEIT
  printf -v ZEIT '%d h %02d min' $(( SEK / 3600 )) $(( SEK % 3600 / 60 ))
  if (( D > 0 )); then
    ZEIT+="  (prepare $(( PREP / 60 )) min, je Domain im Mittel $(( (SEK - PREP) / D / 60 )) min)"
  fi

  local MODUS="seriell, BUILD_ORDER=$BUILD_ORDER"
  (( WORKERS > 1 )) && MODUS="parallel, $WORKERS Worker"

  local -i N_SYS N_FAC N_OTH
  N_SYS=$(find "$DIR" -path '*/sysupgrade/*' -type f ! -name '*.manifest*' 2>/dev/null | wc -l)
  N_FAC=$(find "$DIR" -path '*/factory/*' -type f 2>/dev/null | wc -l)
  N_OTH=$(find "$DIR" -path '*/other/*' -type f 2>/dev/null | wc -l)

  # Groessen in KB: gesamt, Pakete, opkg-Feeds, Logs; Images = der Rest
  local -i KB_ALL KB_PKG=0 KB_OPKG=0 KB_LOG
  KB_ALL=$(du -sk "$DIR" 2>/dev/null | cut -f1)
  [ -d "$DIR/packages" ] && KB_PKG=$(du -sk "$DIR/packages" | cut -f1)
  local O
  for O in "$DIR"/opkg-*; do
    [ -d "$O" ] && KB_OPKG+=$(du -sk "$O" | cut -f1)
  done
  KB_LOG=$(find "$DIR" -name '*.log*' -type f -printf '%s\n' 2>/dev/null | awk '{ s += $1 } END { print int(s / 1024) }')
  local -i KB_IMG=$(( KB_ALL - KB_PKG - KB_OPKG - KB_LOG ))
  kb () { awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.1f GB", k / 1048576; else if (k >= 1024) printf "%.0f MB", k / 1024; else printf "%d KB", k }'; }

  # Worker-Verkehr in Erlang: Summe der Schrittzeiten, die in der
  # Parallelphase fertig wurden (strikt nach ihrem Beginn - der letzte Schritt
  # des golden tree endet oft in derselben Sekunde), durch deren Wandzeit - die mittlere Zahl
  # gleichzeitig belegter Worker (A. K. Erlang, Telefonvermittlung).
  # Ein Worker je Target: mehr als T laufen nie gleichzeitig.
  local ERL="" WIRKSAM_TXT=""
  local -i WIRKSAM=$(( WORKERS < T ? WORKERS : T ))
  (( WIRKSAM < WORKERS )) && WIRKSAM_TXT=", $WORKERS konfiguriert"
  if [ -n "$PAR_START_EPOCH" ] && [ -n "$PAR_END_EPOCH" ] && [ -f "$BUILD_TIMES_FILE" ] \
     && (( PAR_END_EPOCH > PAR_START_EPOCH )); then
    ERL=$(awk -F, -v r="$BUILD_RUN_ID" -v a="$PAR_START_EPOCH" -v w="$(( PAR_END_EPOCH - PAR_START_EPOCH ))" -v n="$WIRKSAM" -v x="$WIRKSAM_TXT" \
      '$1 == r && $5 == "build" && $3 > a { s += $9; k++ }
       END { if (k) printf "%.1f Erl von %d%s  (Parallelphase %d min, %d Bauschritte)", s / w, n, x, w / 60, k }' "$BUILD_TIMES_FILE")
  fi

  local FREI
  FREI="$(disk_free_mb)"

  local BALKEN="=============================================================================="
  echo
  echo "$BALKEN"
  printf ' %-8s %s\n' "Lauf" "$SBRANCH -> images/${DIR##*/}  ($MODUS)"
  printf ' %-8s %s\n' "Dauer" "$ZEIT"
  printf ' %-8s %s\n' "Umfang" "$D Domains x $T Targets = $(( D * T )) Bauschritte"
  [ -n "$ERL" ] && printf ' %-8s %s\n' "Worker" "$ERL"
  printf ' %-8s %s\n' "Images" "$(( N_SYS + N_FAC + N_OTH )) (sysupgrade $N_SYS, factory $N_FAC, other $N_OTH)"
  printf ' %-8s %s\n' "Groesse" "$(kb "$KB_ALL"): Images $(kb "$KB_IMG"), Pakete $(kb "$KB_PKG"), opkg $(kb "$KB_OPKG"), Logs $(kb "$KB_LOG")"
  [ -n "$FREI" ] && printf ' %-8s %s\n' "Platte" "$(( FREI / 1024 )) GB frei unter $SANDBOX_DIR"
  echo "$BALKEN"
}

# Vervollstaendigt <images-dir>/buildinfo/: was man braucht, um einen Lauf zu
# beurteilen, ohne auf dem Buildhost suchen zu muessen. Waehrend des Laufs
# liegen dort schon CSV und Log des Collectors (live, siehe collector_start).
# Alles klein (KB):
#   <lauf>.empfehlung.txt   Empfehlung und Kennzahlen des Collectors
#   <lauf>.collector.log    seine Ergebniszeile
#   <lauf>.metrics.csv.gz   die 1-s-Proben (CPU, iowait, Platte, steal, Phasen)
#   <lauf>.build-times.csv  die Schrittzeiten dieses Laufs aus BUILD_TIMES_FILE
#   <lauf>.summary.txt      der Kasten vom Laufende (schreibt der Aufrufer)
write_buildinfo ()
{
  # Nichts davon darf den fertigen Lauf noch scheitern lassen (errexit,
  # pipefail): jeder Schritt ist optional.
  local BI="$1/buildinfo" ID="$BUILD_RUN_ID"
  mkdir -p -- "$BI" || return 0
  if [ "$METRICS" = true ]; then
    if [ -f "$METRICS_DIR/$ID.empfehlung.txt" ]; then cp -f -- "$METRICS_DIR/$ID.empfehlung.txt" "$BI/" || true; fi
    # Log und CSV sind waehrend des Laufs als Hardlink schon da (collector_start).
    if [ -f "$METRICS_DIR/$ID.log" ] && ! [ "$METRICS_DIR/$ID.log" -ef "$BI/$ID.collector.log" ]; then
      cp -f -- "$METRICS_DIR/$ID.log" "$BI/$ID.collector.log" || true
    fi
    if [ -f "$METRICS_DIR/$ID.csv" ] && gzip -9c -- "$METRICS_DIR/$ID.csv" > "$BI/$ID.metrics.csv.gz"; then
      rm -f -- "$BI/$ID.metrics.csv"
    fi
  fi
  if [ -f "$BUILD_TIMES_FILE" ]; then
    { head -n 1 -- "$BUILD_TIMES_FILE"; grep -- "^$ID," "$BUILD_TIMES_FILE" || true; } > "$BI/$ID.build-times.csv" || true
  fi
  return 0
}

build_all_images ()
{
  local -a TARGETS=( "${BUILD_TARGETS[@]}" )

  # Opened before the fetch, so that a run that already fails there is recorded.
  # RUN_UPTIME_BEGIN is deliberately global: the EXIT trap still needs it after
  # this function has returned.
  open_build_times_file "${#ALL_SITE_RELBRANCHES[@]}" "${#TARGETS[@]}"
  echo "The build timings are appended to: $BUILD_TIMES_FILE (run id $BUILD_RUN_ID)"

  # Nach open_build_times_file, das BUILD_RUN_ID setzt, und vor allem Bauen.
  collector_start

  pushd "$GLUON_DIR" >/dev/null
  echo "Git fetching..."
  git fetch --all

  local UPTIME
  local -i site_index
  local -i target_index

  if (( WORKERS > 1 )); then
    # Golden tree sicherstellen, dann alle Targets parallel. prepare laeuft
    # dort nur, wenn der golden tree neu gebaut werden muss.
    build_parallel
  else

  # Der serielle Zweig baut direkt im Gluon-Baum - im Parallelbetrieb ist das
  # der golden tree. Mit Reset oder Clean wird er gleich umgebaut; bricht der
  # Lauf dabei ab, laege sonst ein halber Baum unter einem Fingerabdruck, der
  # "aktuell" behauptet, und der naechste Parallellauf nahme ihn ungeprueft
  # als lowerdir. Kommt zum Tragen, wenn space_check auf seriell zurueckfaellt.
  if [ "$MAKECLEAN" = true ] || [ "$GITRESET" = true ]; then
    rm -f -- "$GOLDEN_FP_FILE"
  fi

  # Prepare the Gluon tree once, before the first domain. All domains are then
  # built against this state, without resetting or patching again.
  run_prepare

  # The unit of work is one domain x one target. BUILD_ORDER only decides in
  # which order those units are visited, so that both orders can be compared
  # against each other with the timings in BUILD_TIMES_FILE.
  case "$BUILD_ORDER" in

    domain)
      echo "Build order: all targets of a domain, then the next domain."
      for (( site_index=0; site_index < ${#ALL_SITE_RELBRANCHES[@]}; site_index += 1 )); do
        # Nach einem make clean kompiliert die erste Domain alles neu - fuer den
        # Collector ist das "golden", nicht "build", sonst vermengte sich die
        # hochparallele Kompilierung mit den seriellen Imagebauten danach.
        if (( site_index == 0 )) && [ "$MAKECLEAN" = true ]; then BUILD_PHASE=golden; else BUILD_PHASE=build; fi
        for (( target_index=0; target_index < ${#TARGETS[@]}; target_index += 1 )); do
          run_build_step "$site_index" "$target_index"
        done
        # In dieser Reihenfolge ist die Domain hier fertig - alle ihre Targets
        # sind gebaut. Also gleich abschliessen, statt bis zum Ende des ganzen
        # Laufs zu warten: Manifest, Signatur und Site-Verzeichnis liegen dann
        # schon vor, waehrend die naechsten Domains noch bauen. Unter
        # BUILD_ORDER=target geht das nicht, dort ist eine Domain erst nach dem
        # letzten Target vollstaendig.
        run_finalize_step "$site_index"
      done
      ;;

    target)
      echo "Build order: all domains of a target, then the next target."
      for (( target_index=0; target_index < ${#TARGETS[@]}; target_index += 1 )); do
        for (( site_index=0; site_index < ${#ALL_SITE_RELBRANCHES[@]}; site_index += 1 )); do
          # Hier kompiliert je Target die erste Domain, siehe oben.
          if (( site_index == 0 )) && [ "$MAKECLEAN" = true ]; then BUILD_PHASE=golden; else BUILD_PHASE=build; fi
          run_build_step "$site_index" "$target_index"
        done
      done
      ;;

    *)
      abort "Invalid BUILD_ORDER \"$BUILD_ORDER\". Valid values are: domain, target."
      ;;

  esac

  fi

  # Manifest, signature and site copy need all targets of a domain to be built,
  # which under BUILD_ORDER=target is only the case once everything is done.
  for (( site_index=0; site_index < ${#ALL_SITE_RELBRANCHES[@]}; site_index += 1 )); do
    run_finalize_step "$site_index"
  done

  read_uptime_as_integer
  # The total is not recorded here: the EXIT trap writes the closing run_end
  # record, so that an aborted run gets one too.
  local ELAPSED_TIME_STR
  get_human_friendly_elapsed_time "$(( UPTIME - RUN_UPTIME_BEGIN ))"
  echo "Total build time with BUILD_ORDER=$BUILD_ORDER: $ELAPSED_TIME_STR."
  local -i RUN_SECONDS=$(( UPTIME - RUN_UPTIME_BEGIN ))

  popd >/dev/null

  # Gebaut und abgeschlossen, der Lauf ist erfolgreich - seine Empfehlung gilt.
  status_clear
  collector_stop uebernehmen

  compress_build_logs

  # Der Lauf ist durch, die Zustandsdatei hat ihren Zweck erfuellt. Sie wird
  # geloescht, bevor das Verzeichnis seinen endgueltigen Namen bekommt: ein
  # images-<datum> mit .build-state darin saehe aus wie ein halber Lauf.
  rm -f "$SANDBOX_DIR/images/running/.build-state" "$SITE_SECONDS_FILE"
  rm -rf -- "$STATUS_DIR"

  # rename output to images with timestamp
  mv "./images/running" "./images/images-$DATE_SUFFIX"

  echo "Finished building images:"
  echo "- Images  dir: images-$DATE_SUFFIX"
  # Die Pakete sind mit dem Umbenennen oben schon mitgewandert, siehe
  # GLUON_PACKAGEDIR in build_make_args. (Die Meldung nannte hier frueher
  # "modules-<ts>/packages", obwohl das Verzeichnis images-<ts> heisst.)
  if [ -d "./images/images-$DATE_SUFFIX/packages" ]; then
    echo "- Packages dir: images-$DATE_SUFFIX/packages"
  fi

  write_buildinfo "./images/images-$DATE_SUFFIX"
  # Kasten auch nach buildinfo/; scheitert das Schreiben, bleibt er auf dem Schirm.
  print_run_summary "./images/images-$DATE_SUFFIX" "$RUN_SECONDS" \
    | { tee "./images/images-$DATE_SUFFIX/buildinfo/$BUILD_RUN_ID.summary.txt" 2>/dev/null || cat; }
  if (( ${#DEGRADIERT[@]} > 0 )); then
    fat_warning "Dieser Lauf lief NICHT wie konfiguriert:" "${DEGRADIERT[@]}"
  fi
}


declare -a ALL_SITE_RELBRANCHES=()
declare -a ALL_SITE_GLUON_BRANCHES=()
declare -a ALL_SITE_TEMPLATE_NAMES=()
declare -a ALL_SITE_CODES=()
declare -a ALL_SITE_DOMAIN_NRS=()
declare -a ALL_SITE_SITE_SMALLS=()
declare -a ALL_SITE_SITE_BIGS=()
declare -a ALL_SITE_FF_PREFIXS=()
declare -a ALL_SITE_META_PREFIXS=()
declare -a ALL_SITE_MESH_SSIDS=()
declare -a ALL_SITE_DOMAIN_NAMES=()
declare -a ALL_SITE_SUPERNODE_DEFAULTS=()
declare -a ALL_SITE_V4_PREFIXS=()
declare -a ALL_SITE_V6_PREFIXS=()
declare -a ALL_SITE_WIFICH_24S=()
declare -a ALL_SITE_WIFICH_5S=()
declare -a ALL_SITE_MAP_LATS=()
declare -a ALL_SITE_MAP_LONS=()
declare -a ALL_SITE_MAP_ZOOMS=()
declare -a ALL_SITE_DOMAIN_HASHS=()
declare -a ALL_SITE_META_NAMES=()
declare -a ALL_SITE_META_WEBSITES=()
declare -a ALL_SITE_MAP_WEBSITES=()
declare -a ALL_SITE_FWWEBSITE_HOSTS=()
declare -a ALL_SITE_FWWEBSITE_TLDS=()
declare -a ALL_SITE_OPKG_FQDNS=()
declare -a ALL_SITE_SUPERNODE_TLDS=()
declare -a ALL_SITE_DOMAIN_REGION_DES=()
declare -a ALL_SITE_DOMAIN_REGION_ENS=()
declare -a ALL_SITE_SETUP_SKIPS=()
declare -a ALL_SITE_KEY_FILE_SIGNS=()
declare -a ALL_SITE_KEY_FILE_SSHS=()
declare -a ALL_SITE_DOMAIN_LONGNAMES=()

# Every template name the sites file contains, regardless of the selection.
# Used to detect typos in the domain configuration.
declare -a ALL_TEMPLATE_NAMES_IN_FILE=()

parse_sites_file ()
{
  local FILENAME="$1"

  local LINE
  local COMPONENTS
  local -a SELECTED_LINES=()
  local -a SELECTED_TEMPLATES=()

  # Erster Durchgang: lesen und die ausgewaehlten Zeilen einsammeln. Ausgewertet
  # werden sie erst im zweiten Durchgang - dazwischen wird die Reihenfolge
  # festgelegt, und die kommt aus DOMAINS_INCLUDE und nicht aus dieser Datei.
  while read -r LINE; do

    # We could allow comments in the file. Here we would remove them.

    if [ -z "$LINE" ] || [ "$(echo $LINE|cut -c1)" == "#" ] ; then
      continue
    fi

    IFS=$' \t'  read -r -a COMPONENTS <<< "$(echo $LINE|tr -s '\t')"

    if (( ${#COMPONENTS[@]} != 33 )); then
      abort "Syntax error parsing this line: $LINE"
    fi

    ALL_TEMPLATE_NAMES_IN_FILE+=( "${COMPONENTS[2]}" )

    # Domains that the domain configuration does not select are skipped here,
    # so that the parallel ALL_SITE_* arrays never contain them in the first
    # place. Skipping a domain no longer means commenting it out in this file.
    if ! domain_is_selected "${COMPONENTS[2]}"; then
      continue
    fi

    SELECTED_LINES+=( "$LINE" )
    SELECTED_TEMPLATES+=( "${COMPONENTS[2]}" )

  done < "$FILENAME"

  if (( ${#ALL_TEMPLATE_NAMES_IN_FILE[@]} == 0 )); then
    abort "Could not read any sites from the sites file."
  fi

  check_domain_selection

  if (( ${#SELECTED_LINES[@]} == 0 )); then
    abort "The domain configuration selects none of the ${#ALL_TEMPLATE_NAMES_IN_FILE[@]} domains in \"$FILENAME\"."
  fi

  # Die Bauabfolge steht in DOMAINS_INCLUDE. Vorher war es die Zeilenfolge der
  # Sites-Datei, und die ist nach ganz anderen Gesichtspunkten sortiert - wer
  # steuern wollte, welche Domain zuerst fertig wird, musste dort umsortieren.
  # "all" steht fuer alles noch nicht Genannte und behaelt dafuer die
  # Dateireihenfolge bei, damit ( all ) sich verhaelt wie bisher. Gemischt ist
  # ebenfalls sinnvoll: ( 21_dias all ) baut Dias zuerst, den Rest wie gehabt.
  local -a ORDER=()
  local -a TAKEN=()
  local ENTRY
  local i

  for (( i = 0; i < ${#SELECTED_LINES[@]}; i++ )); do
    TAKEN[$i]=false
  done

  for ENTRY in "${DOMAINS_INCLUDE[@]}"; do
    for (( i = 0; i < ${#SELECTED_LINES[@]}; i++ )); do
      if [[ ${TAKEN[$i]} == true ]]; then
        continue
      fi
      if [[ $ENTRY == all || $ENTRY == "${SELECTED_TEMPLATES[$i]}" ]]; then
        ORDER+=( "$i" )
        TAKEN[$i]=true
      fi
    done
  done

  # Sicherheitsnetz. Hier darf nichts uebrig bleiben - ausgewaehlt wurde eine
  # Zeile ja nur, weil DOMAINS_INCLUDE sie nennt. Bliebe doch etwas liegen,
  # wird es angehaengt statt still weggelassen.
  for (( i = 0; i < ${#SELECTED_LINES[@]}; i++ )); do
    if [[ ${TAKEN[$i]} != true ]]; then
      ORDER+=( "$i" )
    fi
  done

  # Zweiter Durchgang: in der festgelegten Reihenfolge auswerten.
  for i in "${ORDER[@]}"; do

    IFS=$' \t'  read -r -a COMPONENTS <<< "$(echo ${SELECTED_LINES[$i]}|tr -s '\t')"

    ALL_SITE_RELBRANCHES+=( "${COMPONENTS[0]}" )
    ALL_SITE_GLUON_BRANCHES+=( "${COMPONENTS[1]}" )
    ALL_SITE_TEMPLATE_NAMES+=( "${COMPONENTS[2]}" )
    ALL_SITE_CODES+=( "${COMPONENTS[3]}" )
    ALL_SITE_DOMAIN_NRS+=( "${COMPONENTS[4]}" )
    ALL_SITE_SITE_SMALLS+=( "${COMPONENTS[5]}" )
    ALL_SITE_SITE_BIGS+=( "${COMPONENTS[6]}" )
    ALL_SITE_FF_PREFIXS+=( "${COMPONENTS[7]}" )
    ALL_SITE_META_PREFIXS+=( "${COMPONENTS[8]}" )
    ALL_SITE_MESH_SSIDS+=( "${COMPONENTS[9]}" )
    ALL_SITE_DOMAIN_NAMES+=( "${COMPONENTS[10]}" )
    ALL_SITE_SUPERNODE_DEFAULTS+=( "${COMPONENTS[11]}" )
    ALL_SITE_V4_PREFIXS+=( "${COMPONENTS[12]}" )
    ALL_SITE_V6_PREFIXS+=( "${COMPONENTS[13]}" )
    ALL_SITE_WIFICH_24S+=( "${COMPONENTS[14]}" )
    ALL_SITE_WIFICH_5S+=( "${COMPONENTS[15]}" )
    ALL_SITE_MAP_LATS+=( "${COMPONENTS[16]}" )
    ALL_SITE_MAP_LONS+=( "${COMPONENTS[17]}" )
    ALL_SITE_MAP_ZOOMS+=( "${COMPONENTS[18]}" )
    ALL_SITE_DOMAIN_HASHS+=( "${COMPONENTS[19]}" )
    ALL_SITE_META_NAMES+=( "${COMPONENTS[20]}" )
    ALL_SITE_META_WEBSITES+=( "${COMPONENTS[21]}" )
    ALL_SITE_MAP_WEBSITES+=( "${COMPONENTS[22]}" )
    ALL_SITE_FWWEBSITE_HOSTS+=( "${COMPONENTS[23]}" )
    ALL_SITE_FWWEBSITE_TLDS+=( "${COMPONENTS[24]}" )
    ALL_SITE_OPKG_FQDNS+=( "${COMPONENTS[25]}" )
    ALL_SITE_SUPERNODE_TLDS+=( "${COMPONENTS[26]}" )
    ALL_SITE_DOMAIN_REGION_DES+=( "${COMPONENTS[27]}" )
    ALL_SITE_DOMAIN_REGION_ENS+=( "${COMPONENTS[28]}" )
    ALL_SITE_SETUP_SKIPS+=( "${COMPONENTS[29]}" )
    ALL_SITE_KEY_FILE_SIGNS+=( "${COMPONENTS[30]}" )
    ALL_SITE_KEY_FILE_SSHS+=( "${COMPONENTS[31]}" )
    ALL_SITE_DOMAIN_LONGNAMES+=( "${COMPONENTS[32]}" )

  done

  echo "Building ${#ALL_SITE_RELBRANCHES[@]} of ${#ALL_TEMPLATE_NAMES_IN_FILE[@]} domains from \"$FILENAME\"."
  echo "Build order: ${ALL_SITE_TEMPLATE_NAMES[*]}"
}


# Sagt, was in einem liegengebliebenen Lauf steckt. Wird sowohl vor dem
# Wegwerfen (--restart) als auch beim Abbruch ohne Option aufgerufen: in beiden
# Faellen will man wissen, wieviel Arbeit da liegt, bevor man entscheidet.
report_discarded_run ()
{
  local RUNNING_DIR="$1"
  local ZUSTAND="$RUNNING_DIR/.build-state"

  if [ ! -f "$ZUSTAND" ]; then
    echo "There is a left-over \"$RUNNING_DIR\" without a state file (from an older build.sh)."
    return
  fi

  local -i FERTIGE_BAUTEN FERTIGE_DOMAINS
  FERTIGE_BAUTEN="$(  grep -c "^build	"    "$ZUSTAND" || true )"
  FERTIGE_DOMAINS="$( grep -c "^finalize	" "$ZUSTAND" || true )"

  echo "A previous run is still lying in \"$RUNNING_DIR\":"
  echo "  Started:      $(sed -n 's/^started=//p' "$ZUSTAND")"
  echo "  Release:      $(sed -n 's/^sbranch=//p' "$ZUSTAND")"
  echo "  Already done: $FERTIGE_BAUTEN domain x target units, $FERTIGE_DOMAINS domains finalized"
}


# --------------------------------------------------------------------------
# Entscheidet, ob dieser Lauf neu anfaengt oder einen abgebrochenen fortsetzt.
#
# Muss vor generate_all_site_configs stehen: SBRANCH wird dort in die
# site.conf hineingeschrieben, ein spaeter uebernommener kaeme zu spaet.
prepare_run_state ()
{
  local RUNNING_DIR="$SANDBOX_DIR/images/running"

  if [ "$RESUME" = true ] && [ "$RESTART" = true ]; then
    abort "--resume and --restart contradict each other: one continues the interrupted run, the other throws it away."
  fi

  if [ "$RESUME" = true ]; then
    if [ ! -d "$RUNNING_DIR" ]; then
      abort "--resume was given, but \"$RUNNING_DIR\" does not exist. There is no interrupted run to resume; without --resume build.sh starts afresh."
    fi
    state_resume
    return
  fi

  if [ "$RESTART" = true ]; then
    if [ -d "$RUNNING_DIR" ]; then
      # Sagen, was weggeworfen wird, bevor es weg ist. Ein Lauf, der schon
      # zwanzig Domains fertig hatte, ist mehrere Stunden Arbeit - wer sich in
      # der Option vergreift, soll das im Log wiederfinden.
      report_discarded_run "$RUNNING_DIR"
      echo "Removing \"$RUNNING_DIR\" and starting afresh (--restart)."
      rm -rf -- "$RUNNING_DIR"
    else
      echo "--restart was given, but there is no left-over run; starting afresh anyway."
    fi
    state_init
    return
  fi

  if [ -d "$RUNNING_DIR" ]; then
    report_discarded_run "$RUNNING_DIR"
    abort "\"$RUNNING_DIR\" is still there, so an earlier run did not complete. Continue it with --resume, throw it away with --restart, or remove the directory by hand. (Building into it is not an option: everything in it would be renamed together at the end, putting images of two runs with different release strings under one manifest.)"
  fi

  state_init
}


# ----------- Entry point -----------

# Optionen von den Stellungsargumenten trennen, damit --resume vor wie hinter
# den drei Konfigurationsdateien stehen darf.
RESUME=false
RESTART=false
# Intern: build.sh startet sich im Parallelbetrieb selbst als Worker fuer ein
# Target, siehe start_worker. Nicht fuer den Aufruf von Hand gedacht.
WORKER_TARGET=""

declare -a POSITIONAL_ARGS=()
for ARG in "$@"; do
  case "$ARG" in
    --resume)   RESUME=true ;;
    --restart)  RESTART=true ;;
    --worker=*) WORKER_TARGET="${ARG#--worker=}" ;;
    *)          POSITIONAL_ARGS+=( "$ARG" ) ;;
  esac
done
set -- ${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}

if (( $# < 3 )); then
  echo "Usage: build.sh <build.conf> <targets.conf> <domains.conf> [target1] [target2] [...]"
  echo
  echo "  build.conf    how to build: version, cleaning, parallelism, build order,"
  echo "                Gluon options. Settings in build.local.conf, if present,"
  echo "                override it."
  echo "  targets.conf  which hardware to build: GLUON_TARGETS."
  echo "  domains.conf  which domains to build: SITES_FILE plus DOMAINS_INCLUDE"
  echo "                and DOMAINS_EXCLUDE."
  echo
  echo "Targets given after the three files override GLUON_TARGETS and are meant"
  echo "for individual test builds."
  echo
  echo "  --resume      Resumes an interrupted run: builds only what is still"
  echo "                missing and keeps that run's release string and output"
  echo "                directory. An interrupted run is recognised by a"
  echo "                left-over images/running directory."
  echo "  --restart     Throws a left-over run away and starts from scratch:"
  echo "                images/running is removed, and release string and output"
  echo "                directory are formed anew. What the old run had already"
  echo "                built is reported before it is deleted."
  echo
  echo "Example: ./build.sh build.conf targets.conf domains.conf"
  exit 0
fi

SANDBOX_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Die Datei, die gerade laeuft. Ein Worker muss genau diese starten und nicht
# stur "build.sh": laeuft eine Kopie oder eine umbenannte Fassung, bekaeme er
# sonst eine andere Version - im schlimmsten Fall eine ohne --worker.
BUILD_SH="$SANDBOX_DIR/$(basename -- "${BASH_SOURCE[0]}")"

# Bauzeit je Domain, eine Zeile "<template>/<site_code><TAB><sekunden>" je
# erledigtem Bauschritt. Schluessel mit Template, weil key- und nokeys-Variante
# denselben site_code tragen.
#
# Eine Datei statt eines Arrays: im Parallelbetrieb ist jeder Worker ein
# eigener Prozess, und dessen Array saehe der Hauptprozess, der
# write_build_info ausfuehrt, nie. Das Anhaengen einer kurzen Zeile ist
# atomar (O_APPEND, unter PIPE_BUF), mehrere Worker koennen gleichzeitig
# schreiben.
SITE_SECONDS_FILE="$SANDBOX_DIR/images/running/.site-seconds"

# Arbeitsverzeichnisse der Worker-Overlays: je Worker lower (Bind-Mount des
# golden tree), upper (was der Worker schreibt) und work (fuer overlayfs).
# Neben dem Gluon-Baum, nicht darin - sonst saehe jedes Overlay die anderen als
# Teil seines lowerdir.
OVL_DIR="$SANDBOX_DIR/.overlays"

# Fingerabdruck des golden tree, siehe golden_fingerprint. Geschrieben erst,
# wenn der golden tree vollstaendig gebaut ist - ein abgebrochener Aufbau
# hinterlaesst also keinen, und der naechste Lauf baut ihn neu.
GOLDEN_FP_FILE="$OVL_DIR/golden.fingerprint"

# Statusdateien der Prozesse dieses Laufs, siehe status_set. Im Laufverzeichnis,
# wie .build-state; vor dem Umbenennen weggeraeumt.
STATUS_DIR="$SANDBOX_DIR/images/running/.status"

# Phase fuer run_build_step: "build", im Aufbau des golden tree "golden". Als
# Variable statt als Argument, weil run_build_step an mehreren Stellen gerufen
# wird und nur build_parallel den Unterschied kennt.
BUILD_PHASE="build"

# Metriken der Laeufe, samt der Empfehlung fuer den naechsten. Ausserhalb von
# images/, damit sie Laeufe ueberdauern: der naechste Lauf soll die Empfehlung
# des letzten lesen koennen.
METRICS_DIR="$SANDBOX_DIR/metrics"
COLLECTOR_PID=""

# Laufende Worker, PID -> Target. Global statt lokal in run_parallel, damit der
# EXIT-Trap sie bei einem Abbruch des Hauptprozesses beenden kann.
declare -A WORKER_LAUFEND=()

# Fuer build-info.txt: Startzeitpunkt und Aufruf festhalten, bevor die
# Argumente durch "shift" verlorengehen.
BUILD_START_EPOCH="$(date +%s)"
printf -v BUILD_COMMAND_LINE "%q " "$0" "$@"
BUILD_COMMAND_LINE="${BUILD_COMMAND_LINE% }"

# generate_site_config still works with paths relative to the current directory
# ("templates/...", "assembled/...", "buildkeys/..."), so build.sh has to be
# started from its own directory. Saying so plainly beats failing later with a
# puzzling "cp: cannot stat 'templates/...'".
if [ "$PWD" != "$SANDBOX_DIR" ]; then
  abort "build.sh has to be started from its own directory ($SANDBOX_DIR), the current one is $PWD."
fi

# The three paths are made absolute right away: the build runs with the Gluon
# directory as its working directory, so a relative path would stop resolving
# once finalize_site copies the configuration next to the images.
BUILD_CONF_FILE="$(to_absolute_path "$1")"
TARGETS_CONF_FILE="$(to_absolute_path "$2")"
DOMAINS_CONF_FILE="$(to_absolute_path "$3")"
shift 3

load_build_config   "$BUILD_CONF_FILE"
load_targets_config "$TARGETS_CONF_FILE"
load_domains_config "$DOMAINS_CONF_FILE"

resolve_workers

# Im Parallelbetrieb baut jeder Worker ein Target ueber alle Domains - die
# Reihenfolge ist also immer targetweise, BUILD_ORDER aus der Konfiguration
# gilt dort nicht. Fuer Hauptprozess UND Worker gesetzt, damit ihre Zeilen in
# BUILD_TIMES_FILE einheitlich als "parallel" erscheinen; sonst stuenden die
# Worker, die build.conf selbst lesen, unter "domain".
# Die konfigurierte Reihenfolge merken: faellt space_check spaeter auf den
# seriellen Betrieb zurueck, gilt wieder sie.
BUILD_ORDER_KONFIG="$BUILD_ORDER"
if (( WORKERS > 1 )); then
  BUILD_ORDER="parallel"
fi

# Worker: nur das Noetigste und dann das eine Target bauen. Alles, was einmal
# je Lauf geschieht - Vorabpruefung, Site-Pruefung, SBRANCH berechnen,
# assembled/ erzeugen, Zustand anlegen -, hat der Hauptprozess schon getan.
# Insbesondere darf der Worker assembled/ nicht neu erzeugen: das raeumt mit
# rm -rf auf, waehrend andere Worker daraus lesen.
if [ -n "$WORKER_TARGET" ]; then
  state_attach
  detect_timestamp_awk
  sanitize_path
  parse_sites_file "$SITES_FILE"
  resolve_targets "$@"
  GLUON_DIR="$SANDBOX_DIR/gluon"
  worker_run "$WORKER_TARGET"
  exit 0
fi

# Nach den Konfigurationsdateien, weil die Pruefung von deren Werten abhaengt
# (SIGNKEY_FILE), und vor allem anderen, damit ein Mangel nichts mehr kostet.
preflight_check

# Syntaxcheck der Lua-Dateien in den Templates, dauert zwei Sekunden. Ein
# Tippfehler in der site.conf faellt damit hier auf und nicht erst nach
# "make update" - Gluons eigene, semantische Pruefung (CheckSite) laeuft erst
# dort. "--optional": fehlt auf dem Host ein Lua, wird gewarnt statt
# abgebrochen.
"$SANDBOX_DIR/tests/check-site-conf.sh" --optional

detect_timestamp_awk

sanitize_path

determine_sbranch "$SITES_FILE"

parse_sites_file "$SITES_FILE"

# Vor prepare_run_state, denn beides geht in den Fingerabdruck des Laufs ein.
resolve_targets "$@"

DATE_SUFFIX="$(date "$DATE_SUFFIX_FORMAT")"

prepare_run_state

# Nach prepare_run_state: erst jetzt sind Domains und Targets bekannt, ein
# --restart hat den alten Lauf schon weggeraeumt, und ein --resume weiss aus
# der Zustandsdatei, was fertig ist.
space_check

generate_all_site_configs

GLUON_DIR="$SANDBOX_DIR/gluon"

build_all_images
