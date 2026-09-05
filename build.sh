#!/bin/bash

# Copyright (c) 2018 R. Diez - Licensed under the GNU AGPLv3

set -o errexit
set -o nounset
set -o pipefail

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


get_site_log_filename ()
{
  local TEMPLATE_NAME="$1"
  local SITE_CODE="$2"

  LOG_FILENAME="$SANDBOX_DIR/assembled/$TEMPLATE_NAME/$SITE_CODE/build.log"
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
  GLUON_SITE_VERSION="$(date +%Y%m%d)"
  GLUONDEVICES=""
  SIGNKEY_FILE="untrustworthy-buildbot-signkey.priv"

  BUILD_ORDER="domain"
  BUILD_TIMES_FILE="$SANDBOX_DIR/build-times.csv"

  DATE_SUFFIX_FORMAT="+%s"
  SITE_COPY_EXCLUDES=( '*.old' '*.backup' '*~' '*.nonworking' )
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
      RELBRANCH_PREFIX="$(grep -v -e '^#' -e '^[[:space:]]*$' -- "$SITES_FILE" | head -1 | cut -c1-3)"
      SBRANCH="$(date +%y%m%d%H)$RELBRANCH_PREFIX"
      ;;

    datetime)
      SBRANCH="$(date +%Y%m%d%H%M)"
      ;;

    *)
      abort "Invalid SBRANCH_MODE \"$SBRANCH_MODE\". Valid values are: fixed, date, datetime."
      ;;

  esac

  echo "Firmware version (SBRANCH): $SBRANCH"
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
  append_quoted_arg  ARGS  GLUON_MODULEDIR  "$SANDBOX_DIR/gluon/output/modules"
  append_quoted_arg  ARGS  GLUON_PACKAGEDIR "$SANDBOX_DIR/gluon/output/packages"
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
    # Note: this only restores tracked files. Patches that add new files leave
    # them behind; "git clean -fd" would be needed for those, but not -x, which
    # would also discard the openwrt tree and the build cache.
    git reset --hard "origin/$GLUONBRANCH"
    git submodule foreach --recursive git reset --hard

    if [ -d "openwrt" ]; then
      pushd openwrt >/dev/null
      git reset --hard
      git submodule foreach --recursive git reset --hard
      popd >/dev/null
    fi
  fi

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

  # prepare.sh applies the patches from patches/ and has to run last: some of
  # them patch openwrt/ (see add-cudy-3000.sh), and "make update" overwrites
  # local changes in the external repositories.
  # It takes no arguments; the target and device list it used to be passed were
  # never read.
  echo "Applying the patches from patches/ ..."
  "$SANDBOX_DIR/assembled/$TEMPLATE_NAME/$SITE_CODE/prepare.sh"
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
    MAKE_CMD+=" GLUON_DEVICES=$GLUONDEVICES "
    echo "for GLUONDEVICEs $GLUONDEVICES"
  fi
  echo "$MAKE_CMD"
  eval "$MAKE_CMD"
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

  rsync --archive "$SANDBOX_DIR/assembled/$TEMPLATE_NAME/$SITE_CODE/" "${RSYNC_EXCLUDE_ARGS[@]}" "$SITE_IMAGE_DIR"

  # Keep the build script and all three configurations next to the images, so
  # that it stays visible with which settings they were built.
  cp -- "$SANDBOX_DIR/build.sh" "$SITE_IMAGE_DIR/"
  cp -- "$BUILD_CONF_FILE" "$TARGETS_CONF_FILE" "$DOMAINS_CONF_FILE" "$SITE_IMAGE_DIR/"
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
run_build_step ()
{
  local -i site_index="$1"
  local -i target_index="$2"

  local SITE_CODE="${ALL_SITE_CODES[$site_index]}"
  local TARGET="${TARGETS[target_index]}"

  get_site_log_filename  "${ALL_SITE_TEMPLATE_NAMES[$site_index]}"  "$SITE_CODE"

  local UPTIME
  read_uptime_as_integer
  local STEP_UPTIME_BEGIN="$UPTIME"

  {
    build_site_target "${ALL_SITE_RELBRANCHES[$site_index]}" \
                      "${ALL_SITE_TEMPLATE_NAMES[$site_index]}" \
                      "$SITE_CODE" \
                      "$TARGET"
  } 2>&1 | tee --append -- "$LOG_FILENAME"

  read_uptime_as_integer
  local -i ELAPSED="$(( UPTIME - STEP_UPTIME_BEGIN ))"

  local ELAPSED_TIME_STR
  get_human_friendly_elapsed_time "$ELAPSED"
  echo "Finished site code $SITE_CODE, target $TARGET. Elapsed time: $ELAPSED_TIME_STR."

  log_build_time build "${ALL_SITE_TEMPLATE_NAMES[$site_index]}" "$SITE_CODE" "$TARGET" "$ELAPSED"
}

build_all_images ()
{
  # Targets given on the command line win, otherwise the enabled entries of
  # GLUON_TARGETS from the build configuration are used.
  local -a TARGETS=("$@")

  if (( ${#TARGETS[@]} == 0 )); then
    local -a ENABLED_TARGETS
    get_enabled_targets
    TARGETS=( "${ENABLED_TARGETS[@]}" )
    echo "Building the ${#TARGETS[@]} targets enabled in the build configuration."
  else
    echo "Building the ${#TARGETS[@]} targets given on the command line."
  fi

  # Opened before the fetch, so that a run that already fails there is recorded.
  # RUN_UPTIME_BEGIN is deliberately global: the EXIT trap still needs it after
  # this function has returned.
  open_build_times_file "${#ALL_SITE_RELBRANCHES[@]}" "${#TARGETS[@]}"
  echo "The build timings are appended to: $BUILD_TIMES_FILE (run id $BUILD_RUN_ID)"

  pushd "$GLUON_DIR" >/dev/null
  echo "Git fetching..."
  git fetch --all

  # Prepare the Gluon tree once, before the first domain. All domains are then
  # built against this state, without resetting or patching again.
  local PREPARE_LOG_FILENAME="$SANDBOX_DIR/assembled/prepare.log"
  echo "Preparing the Gluon tree. The log file is: $PREPARE_LOG_FILENAME"

  local UPTIME
  read_uptime_as_integer
  local PREPARE_UPTIME_BEGIN="$UPTIME"

  {
    prepare_gluon_tree "${ALL_SITE_RELBRANCHES[0]}" \
                       "${ALL_SITE_GLUON_BRANCHES[0]}" \
                       "${ALL_SITE_TEMPLATE_NAMES[0]}" \
                       "${ALL_SITE_CODES[0]}"
  } 2>&1 | tee -- "$PREPARE_LOG_FILENAME"

  read_uptime_as_integer
  log_build_time prepare "-" "-" "-" "$(( UPTIME - PREPARE_UPTIME_BEGIN ))"

  local -i site_index
  local -i target_index

  # The unit of work is one domain x one target. BUILD_ORDER only decides in
  # which order those units are visited, so that both orders can be compared
  # against each other with the timings in BUILD_TIMES_FILE.
  case "$BUILD_ORDER" in

    domain)
      echo "Build order: all targets of a domain, then the next domain."
      for (( site_index=0; site_index < ${#ALL_SITE_RELBRANCHES[@]}; site_index += 1 )); do
        for (( target_index=0; target_index < ${#TARGETS[@]}; target_index += 1 )); do
          run_build_step "$site_index" "$target_index"
        done
      done
      ;;

    target)
      echo "Build order: all domains of a target, then the next target."
      for (( target_index=0; target_index < ${#TARGETS[@]}; target_index += 1 )); do
        for (( site_index=0; site_index < ${#ALL_SITE_RELBRANCHES[@]}; site_index += 1 )); do
          run_build_step "$site_index" "$target_index"
        done
      done
      ;;

    *)
      abort "Invalid BUILD_ORDER \"$BUILD_ORDER\". Valid values are: domain, target."
      ;;

  esac

  # Manifest, signature and site copy need all targets of a domain to be built,
  # which under BUILD_ORDER=target is only the case once everything is done.
  for (( site_index=0; site_index < ${#ALL_SITE_RELBRANCHES[@]}; site_index += 1 )); do

    get_site_log_filename  "${ALL_SITE_TEMPLATE_NAMES[$site_index]}"  "${ALL_SITE_CODES[$site_index]}"

    local UPTIME
    read_uptime_as_integer
    local STEP_UPTIME_BEGIN="$UPTIME"

    {
      finalize_site "${ALL_SITE_RELBRANCHES[$site_index]}" \
                    "${ALL_SITE_TEMPLATE_NAMES[$site_index]}" \
                    "${ALL_SITE_CODES[$site_index]}"
    } 2>&1 | tee --append -- "$LOG_FILENAME"

    read_uptime_as_integer
    log_build_time finalize "${ALL_SITE_TEMPLATE_NAMES[$site_index]}" "${ALL_SITE_CODES[$site_index]}" "-" "$(( UPTIME - STEP_UPTIME_BEGIN ))"
  done

  read_uptime_as_integer
  # The total is not recorded here: the EXIT trap writes the closing run_end
  # record, so that an aborted run gets one too.
  local ELAPSED_TIME_STR
  get_human_friendly_elapsed_time "$(( UPTIME - RUN_UPTIME_BEGIN ))"
  echo "Total build time with BUILD_ORDER=$BUILD_ORDER: $ELAPSED_TIME_STR."

  popd >/dev/null

  # rename output to images with timestamp
  mv "./images/running" "./images/images-$DATE_SUFFIX"

  # I do not think that we build any modules yet.
  # echo check for modules
  # if [ -d "./gluon/output/modules" ]; then
  #   ARE_THERE_MODULES=true
  # else
  #   ARE_THERE_MODULES=false
  # fi
  # if $ARE_THERE_MODULES; then
  #   echo moving modules-dir $SANDBOX_DIR/gluon/output/modules
  #   mv "$SANDBOX_DIR/gluon/output/modules" "$SANDBOX_DIR/images-$DATE_SUFFIX/."
  # fi

  echo check for packages wich are actual modules
  if [ -d "./gluon/output/packages" ]; then
    ARE_THERE_PACKAGES=true
  else
    ARE_THERE_PACKAGES=false
  fi
  if $ARE_THERE_PACKAGES; then
    echo moving packages-dir $SANDBOX_DIR/gluon/output/packages
    mv "$SANDBOX_DIR/gluon/output/packages" "$SANDBOX_DIR/images/images-$DATE_SUFFIX/."
  fi

  echo "Finished building images:"
  echo "- Images  dir: images-$DATE_SUFFIX"
  # if $ARE_THERE_MODULES; then
  #   echo "- Modules dir: modules-$DATE_SUFFIX/modules"
  # fi
  if $ARE_THERE_PACKAGES; then
    echo "- Packages dir: modules-$DATE_SUFFIX/packages"
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

  done < "$FILENAME"

  if (( ${#ALL_TEMPLATE_NAMES_IN_FILE[@]} == 0 )); then
    abort "Could not read any sites from the sites file."
  fi

  check_domain_selection

  if (( ${#ALL_SITE_RELBRANCHES[@]} == 0 )); then
    abort "The domain configuration selects none of the ${#ALL_TEMPLATE_NAMES_IN_FILE[@]} domains in \"$FILENAME\"."
  fi

  echo "Building ${#ALL_SITE_RELBRANCHES[@]} of ${#ALL_TEMPLATE_NAMES_IN_FILE[@]} domains from \"$FILENAME\"."
}


# ----------- Entry point -----------

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
  echo "Example: ./build.sh build.conf targets.conf domains.conf"
  exit 0
fi

SANDBOX_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

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

determine_sbranch "$SITES_FILE"

parse_sites_file "$SITES_FILE"

generate_all_site_configs

GLUON_DIR="$SANDBOX_DIR/gluon"

DATE_SUFFIX="$(date "$DATE_SUFFIX_FORMAT")"

build_all_images "$@"
