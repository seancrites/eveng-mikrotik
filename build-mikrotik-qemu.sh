#!/usr/bin/env bash
# =============================================================================
# build-mikrotik-qemu.sh - Download MikroTik CHR and create Eve-NG templates
#
# PURPOSE:   Download a MikroTik CHR image, create a QEMU directory,
#            generate an architecture-specific Eve-NG template for the
#            specified model and version, and optionally patch the image
#            with model-specific RouterOS configuration.
# AUTHOR:    Sean Crites
# VERSION:   1.0.0
# DATE:      2026-06-20
# LICENSE:   GNU General Public License v3.0 (GPL-3.0)
#
# DEPENDENCIES:
#   - curl, jq, unzip, grep, awk, sed, mkdir, mv, diff, qemu-system-x86_64,
#     expect, nc (latter three required only when patching)
#
# USAGE:
#   ./build-mikrotik-qemu.sh MODEL VERSION [OPTIONS]
#
# Options:
#   -h, --help             Show this help message and exit
#   --verbose              Show detailed step-by-step progress
#   --force                Overwrite existing files/directories without prompting
#   --no-patch, -n         Skip the QEMU patching step (build only)
#   --monitor-port N       Use explicit monitor port (serial = N+1)
#   --serial-port N        Use explicit serial port (monitor = N-1)
#   --debug               Preserve generated /tmp debug files with a shared random prefix
#   --log                 Write output to /tmp/build-mikrotik-qemu-YYYYMMSS-HHMMSS.log
#
# EXAMPLE:
#   ./build-mikrotik-qemu.sh crs309 7.22.1 --debug --verbose
#   ./build-mikrotik-qemu.sh crs309 7.22.1 --no-patch   # build only, no patching
#

# Proxy configuration (edit if needed; leave empty to disable)
PROXY=""

# Port range for random selection (edit if needed)
PORT_RANGE_MIN=5000
PORT_RANGE_MAX=9999

VERBOSE=false
FORCE=false
NO_PATCH=false
DEBUG=false
DEBUG_PREFIX=""
LOG=false
LOG_FILE=""
MODEL=""
VERSION=""
TPL_SUBDIR=""
HTML_BASE=""
INCLUDES_DIR=""
QEMU_BASE=""
TEMPLATES_BASE=""
CUSTOM_YML=""
DESCRIPTION=""
NUM_CPU=""
RAM=""
ETHER_PORTS=""
DIR_PREFIX=""
QEMU_DIR=""
MONITOR_PORT=""
SERIAL_PORT=""
INFO_DEBUG_FILE=""
PATCH_SUMMARY_FILE=""
CACHE_DIR=""

# ---------------------------------------------------------------------------
# sanitize_name - Replace characters that cause issues in EveNG filesystem names
#                 Currently: '+' -> 'plus'
# ---------------------------------------------------------------------------
sanitize_name() {
   local name="$1"
   printf '%s' "$name" | sed 's/+/plus/g'
}

# ---------------------------------------------------------------------------
# check_dependencies - Verify all required CLI tools are available
# ---------------------------------------------------------------------------
check_dependencies() {
   local deps="curl jq unzip grep awk sed mkdir mv diff sha256sum"
   for dep in $deps; do
      if ! command -v "$dep" >/dev/null 2>&1; then
         echo "Error: Required dependency '$dep' is not available. Please install it."
         exit 1
      fi
   done
}

# ---------------------------------------------------------------------------
# show_help - Print usage information and exit
# ---------------------------------------------------------------------------
show_help() {
   echo "Usage: $0 MODEL VERSION [OPTIONS]"
   echo ""
   echo "Creates MikroTik CHR model template for Eve-NG."
   echo ""
   echo "Options:"
   echo "  --help             Show this help"
   echo "  --verbose          Show detailed step-by-step progress"
   echo "  --force            Overwrite existing files/directories without prompting"
   echo "  --no-patch, -n     Skip the QEMU patching step (build only)"
   echo "  --monitor-port N   Use explicit monitor port (serial = N+1)"
   echo "  --serial-port N    Use explicit serial port (monitor = N-1)"
   echo "  --debug            Preserve generated /tmp debug files with a shared random prefix"
   echo "  --log              Write output to /tmp/build-mikrotik-qemu-YYYYMMSS-HHMMSS.log"
   exit 0
}

# ---------------------------------------------------------------------------
# parse_args - Parse command-line arguments, set MODEL, VERSION, and flags
# ---------------------------------------------------------------------------
parse_args() {
   while [ $# -gt 0 ]; do
      case "$1" in
         --help|-h)
            show_help
            ;;
         --verbose)
            VERBOSE=true
            ;;
         --force)
            FORCE=true
            ;;
         --no-patch|-n)
            NO_PATCH=true
            ;;
         --debug|-d)
            DEBUG=true
            ;;
         --log|-l)
            LOG=true
            ;;
         --monitor-port)
            MONITOR_PORT="${2:?--monitor-port requires a value}"
            shift
            ;;
         --serial-port)
            SERIAL_PORT="${2:?--serial-port requires a value}"
            shift
            ;;
         *)
            if [ -z "$MODEL" ]; then
               MODEL="$1"
            elif [ -z "$VERSION" ]; then
               VERSION="$1"
            else
               echo "Error: Unexpected argument '$1'"
               show_help
            fi
            ;;
      esac
      shift
   done

   if [ -z "$MODEL" ] || [ -z "$VERSION" ]; then
      echo "Error: MODEL and VERSION are required."
      show_help
   fi
}

# ---------------------------------------------------------------------------
# setup_log_file - Create log file path and redirect shell output if requested
# ---------------------------------------------------------------------------
setup_log_file() {
   if [ "$LOG" = true ]; then
      local timestamp
      timestamp="$(date '+%Y%m%d-%H%M%S')"
      if [ "$DEBUG" = true ] && [ -n "$DEBUG_PREFIX" ]; then
         LOG_FILE="/tmp/${DEBUG_PREFIX}-build-mikrotik-qemu-${timestamp}.log"
      else
         LOG_FILE="/tmp/build-mikrotik-qemu-${timestamp}.log"
      fi
      exec > >(tee -a "$LOG_FILE") 2>&1
      echo "Logging output to $LOG_FILE"
   fi
}

# ---------------------------------------------------------------------------
# generate_debug_prefix - Create a random prefix for debug artifacts
# ---------------------------------------------------------------------------
generate_debug_prefix() {
   if [ "$DEBUG" = true ]; then
      DEBUG_PREFIX="$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)"
      if [ "$VERBOSE" = true ]; then
         echo "Debug prefix: $DEBUG_PREFIX"
      fi
   fi
}

# ---------------------------------------------------------------------------
# expand_debug_info - Read info.debug, expand placeholders, write to /tmp
# ---------------------------------------------------------------------------
expand_debug_info() {
   local info_src="templates/info.debug"
   local build_cmd="$0 ${MODEL} ${VERSION}"
   [ "$VERBOSE" = true ] && build_cmd="$build_cmd --verbose"
   [ "$FORCE" = true ] && build_cmd="$build_cmd --force"
   [ "$DEBUG" = true ] && build_cmd="$build_cmd --debug"
   [ "$NO_PATCH" = true ] && build_cmd="$build_cmd --no-patch"
   [ -n "$MONITOR_PORT" ] && build_cmd="$build_cmd --monitor-port $MONITOR_PORT"
   [ -n "$SERIAL_PORT" ] && build_cmd="$build_cmd --serial-port $SERIAL_PORT"
   [ "$LOG" = true ] && build_cmd="$build_cmd --log"

   local date_time
   date_time="$(date '+%Y-%m-%d %H:%M:%S')"
   local user="${USER:-unknown}"
   local git_tag
   git_tag="$(git describe --tags --always --dirty 2>/dev/null || echo "unknown")"

   local eve_ng_version
   if command -v apt >/dev/null 2>&1; then
      eve_ng_version="$(apt list --installed 2>/dev/null | grep 'eve-ng' | head -1 | awk '{print $2}')"
   fi
   if [ -z "$eve_ng_version" ]; then
      eve_ng_version="Not Installed"
   fi

   local prefix
   if [ -n "$DEBUG_PREFIX" ]; then
      prefix="$DEBUG_PREFIX-"
   else
      prefix=""
   fi

   INFO_DEBUG_FILE="/tmp/${prefix}info.debug"

   sed -e "s/@@DATE_TIME@@/${date_time}/g" \
       -e "s/@@USER@@/${user}/g" \
       -e "s/@@GIT_TAG@@/${git_tag}/g" \
       -e "s|@@EVE-NG_VERSION@@|${eve_ng_version}|g" \
       -e "s|@@BUILD_MIKROTIK_QEMU_CMD@@|${build_cmd}|g" \
       -e "s|@@PATCH_QCOW2_SH_CMD@@|@@PATCH_QCOW2_SH_CMD@@|g" \
       -e "s|@@PATCH_QCOW2_EXP_CMD@@|@@PATCH_QCOW2_EXP_CMD@@|g" \
       "$info_src" > "$INFO_DEBUG_FILE"

   if [ "$VERBOSE" = true ]; then
      echo "Expanded debug info: $INFO_DEBUG_FILE"
   fi
}

# ---------------------------------------------------------------------------
# update_patch_cmds_in_info - Fill in the patch command placeholders
#                             (called after ports are resolved)
# ---------------------------------------------------------------------------
update_patch_cmds_in_info() {
   if [ -z "$INFO_DEBUG_FILE" ] || [ ! -f "$INFO_DEBUG_FILE" ]; then
      return
   fi

   local patch_sh_cmd
   patch_sh_cmd="$(dirname "$0")/patch-qcow2.sh ${QEMU_DIR}/hda.qcow2 --monitor-port ${MONITOR_PORT} --serial-port ${SERIAL_PORT}"
   [ "$VERBOSE" = true ] && patch_sh_cmd="$patch_sh_cmd --verbose"
   [ "$DEBUG" = true ] && patch_sh_cmd="$patch_sh_cmd --debug --rnd-prefix ${DEBUG_PREFIX}"

   local patch_exp_cmd
   patch_exp_cmd="$(dirname "$0")/patch-qcow2.exp ${MODEL} ${SERIAL_PORT} ${MONITOR_PORT} /tmp/${DEBUG_PREFIX:+${DEBUG_PREFIX}-}${MODEL}.rsc"
   [ "$VERBOSE" = true ] && patch_exp_cmd="$patch_exp_cmd --verbose"
   [ "$DEBUG" = true ] && patch_exp_cmd="$patch_exp_cmd --debug"

   sed -i "s|@@PATCH_QCOW2_SH_CMD@@|${patch_sh_cmd}|g" "$INFO_DEBUG_FILE"
   sed -i "s|@@PATCH_QCOW2_EXP_CMD@@|${patch_exp_cmd}|g" "$INFO_DEBUG_FILE"
}

# ---------------------------------------------------------------------------
# resolve_ports - Pick random ports or use explicit ones
# ---------------------------------------------------------------------------
resolve_ports() {
   # If both monitor-port and serial-port are given, use as-is
   if [ -n "$MONITOR_PORT" ] && [ -n "$SERIAL_PORT" ]; then
      # Both specified - use them directly
      :
   elif [ -n "$MONITOR_PORT" ]; then
      # Only monitor specified - derive serial
      SERIAL_PORT=$((MONITOR_PORT + 1))
   elif [ -n "$SERIAL_PORT" ]; then
      # Only serial specified - derive monitor
      MONITOR_PORT=$((SERIAL_PORT - 1))
   else
      # Pick random sequential ports in range
      local max_start=$((PORT_RANGE_MAX - 1))
      MONITOR_PORT=$((RANDOM % (max_start - PORT_RANGE_MIN + 1) + PORT_RANGE_MIN))
      SERIAL_PORT=$((MONITOR_PORT + 1))
   fi

   if [ "$VERBOSE" = true ]; then
      echo "Ports: monitor=$MONITOR_PORT  serial=$SERIAL_PORT"
   fi
}

# ---------------------------------------------------------------------------
# detect_architecture - Set TPL_SUBDIR based on host CPU architecture
# ---------------------------------------------------------------------------
detect_architecture() {
   if grep -qi amd /proc/cpuinfo; then
      TPL_SUBDIR="amd"
   else
      TPL_SUBDIR="intel"
   fi

   QEMU_OPTIONS=$(get_qemu_options "$TPL_SUBDIR")

   if [ "$VERBOSE" = true ]; then
      echo "Detected architecture: $TPL_SUBDIR"
   fi
}

# ---------------------------------------------------------------------------
# get_qemu_options - Return architecture-specific QEMU options string
#                   (single lookup point for future CPU-specific changes)
# ---------------------------------------------------------------------------
get_qemu_options() {
   local arch="$1"
   case "$arch" in
      amd)
         echo "-machine type=pc,accel=kvm -serial mon:stdio -nographic -no-user-config -nodefaults -display none -vga std -rtc base=utc"
         ;;
      intel|*)
         echo "-machine type=pc,accel=kvm -serial mon:stdio -nographic -no-user-config -nodefaults -display none -vga std -rtc base=utc"
         ;;
   esac
}

# ---------------------------------------------------------------------------
# setup_paths - Set all directory and file paths for Eve-NG
# ---------------------------------------------------------------------------
setup_paths() {
   HTML_BASE="/opt/unetlab/html"
   INCLUDES_DIR="${HTML_BASE}/includes"
   QEMU_BASE="/opt/unetlab/addons/qemu"
   TEMPLATES_BASE="${HTML_BASE}/templates/${TPL_SUBDIR}"
   CUSTOM_YML="${INCLUDES_DIR}/custom_templates.yml"
   # QEMU_DIR is recomputed in load_model_config after sanitization
}

# ---------------------------------------------------------------------------
# load_model_config - Validate model JSON exists and extract fields
# ---------------------------------------------------------------------------
load_model_config() {
   # Use sanitized name for all filesystem paths (+ -> plus)
   local MODEL_SANITIZED
   MODEL_SANITIZED="$(sanitize_name "$MODEL")"
   local JSON_FILE="templates/${MODEL_SANITIZED}.json"

   if [ "$VERBOSE" = true ]; then
      echo "Loading model data from ${JSON_FILE}..."
   fi

   if [ ! -f "$JSON_FILE" ]; then
      echo "Error: Model '$MODEL' not supported. JSON file '$JSON_FILE' is missing."
      echo "Add the JSON file to the templates/ directory to support this model."
      exit 1
   fi

   DESCRIPTION=$(jq -r '.description' "$JSON_FILE")
   NUM_CPU=$(jq -r '.num_cpu' "$JSON_FILE")
   RAM=$(jq -r '.ram' "$JSON_FILE")
   ETHER_PORTS=$(jq -r '.ether_ports' "$JSON_FILE")
   # Use the sanitized (case-preserved) name for all EveNG paths
   DIR_PREFIX="mikrotik-${MODEL_SANITIZED}"
   QEMU_DIR="${QEMU_BASE}/mikrotik-${MODEL_SANITIZED}-${VERSION}"

   if [ "$VERBOSE" = true ]; then
      echo "Model: $DESCRIPTION (prefix: $DIR_PREFIX)"
   fi
}

# ---------------------------------------------------------------------------
# create_qemu_directory - Create the model/version QEMU directory with prompt
# ---------------------------------------------------------------------------
create_qemu_directory() {
   # QEMU_DIR was already set by load_model_config with sanitized name
   if [ -d "$QEMU_DIR" ] && [ "$FORCE" = false ]; then
      echo "Warning: Directory $QEMU_DIR already exists."
      read -rp "Overwrite existing files? (y/N): " confirm
      if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
         echo "Aborted."
         exit 0
      fi
   fi
   mkdir -p "$QEMU_DIR"

   if [ "$VERBOSE" = true ]; then
      echo "Created/using qemu directory: $QEMU_DIR"
   fi
}

# ---------------------------------------------------------------------------
# download_image - Download CHR image (with cache + checksum), unzip, place
# ---------------------------------------------------------------------------
download_image() {
   local CACHED_ZIP="${CACHE_DIR}/chr-${VERSION}.img.zip"
   local CACHED_SHA="${CACHE_DIR}/chr-${VERSION}.img.zip.sha256"
   local IMG_NAME="chr-${VERSION}.img"
   local URL="https://download.mikrotik.com/routeros/${VERSION}/chr-${VERSION}.img.zip"
   local SHA_URL="${URL}.sha256"
   local TMP_ZIP="/tmp/chr-${VERSION}.img.zip"

   # If download or checksum fails after the QEMU dir was created, clean it
   # up so the user isn't left with a leftover directory that triggers an
   # overwrite prompt on retry.
   local _download_failed=false
   cleanup_on_error() { _download_failed=true; }
   trap cleanup_on_error EXIT

   # If cached zip already exists and checksum is valid, skip download
   if [ -f "$CACHED_ZIP" ]; then
       echo "Found cached image: $CACHED_ZIP"

      # Ensure the matching sha256 file is available for verification
      if [ ! -f "$CACHED_SHA" ]; then
         if [ "$VERBOSE" = true ]; then
            echo "Downloading sha256 checksum for verification..."
         fi
         if [ -n "${PROXY:-}" ]; then
            curl -fL --proxy "$PROXY" -o "$CACHED_SHA" "$SHA_URL"
         else
            curl -fL -o "$CACHED_SHA" "$SHA_URL"
         fi
      fi

      pushd "$CACHE_DIR" >/dev/null
      if sha256sum -c "$(basename "$CACHED_SHA")" >/dev/null 2>&1; then
         if [ "$VERBOSE" = true ]; then
            echo "Cached image checksum is valid. Skipping download."
         fi
         popd >/dev/null
      else
         echo "Warning: Cached image checksum mismatch for $CACHED_ZIP."
         if [ "$FORCE" = false ]; then
            read -rp "Re-download? (y/N): " confirm
            if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
               echo "Aborted."
               exit 0
            fi
         fi
         popd >/dev/null
         CACHED_ZIP=""  # force re-download
      fi
   fi

   # Download if not cached or was invalidated
   if [ -z "${CACHED_ZIP:-}" ] || [ ! -f "${CACHED_ZIP:-}" ]; then
      # Download sha256 first if not already present
      if [ ! -f "$CACHED_SHA" ]; then
         if [ "$VERBOSE" = true ]; then
            echo "Downloading sha256 checksum from $SHA_URL..."
         fi
         if [ -n "${PROXY:-}" ]; then
            curl -fL --proxy "$PROXY" -o "$CACHED_SHA" "$SHA_URL"
         else
            curl -fL -o "$CACHED_SHA" "$SHA_URL"
         fi
         if [ ! -f "$CACHED_SHA" ]; then
            echo "Error: Failed to download sha256 checksum."
            exit 1
         fi
      fi

      if [ "$VERBOSE" = true ]; then
         echo "Downloading CHR image from $URL..."
      fi

      # Check if cached zip already exists and prompt for overwrite
      if [ -f "$CACHED_ZIP" ]; then
         if [ "$FORCE" = false ]; then
            read -rp "Cache file $(basename "$CACHED_ZIP") already exists. Overwrite? (y/N): " confirm
            if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
               echo "Aborted."
               exit 0
            fi
         fi
      fi

      if [ -n "${PROXY:-}" ]; then
         curl -fL --proxy "$PROXY" -o "$CACHED_ZIP" "$URL"
      else
         curl -fL -o "$CACHED_ZIP" "$URL"
      fi

      if [ ! -f "$CACHED_ZIP" ]; then
         echo "Error: Download failed."
         exit 1
      fi

      # Verify checksum
      pushd "$CACHE_DIR" >/dev/null
      if ! sha256sum -c "$(basename "$CACHED_SHA")" >/dev/null 2>&1; then
         echo "Error: Checksum verification failed for $(basename "$CACHED_ZIP")."
         popd >/dev/null
         exit 1
      fi
      if [ "$VERBOSE" = true ]; then
         echo "Checksum verified."
      fi
      popd >/dev/null
   fi

   # Unzip to /tmp and move into place
   cp "$CACHED_ZIP" "$TMP_ZIP"
   unzip -o "$TMP_ZIP" -d /tmp/
   rm -f "$TMP_ZIP"

   if [ ! -f "/tmp/$IMG_NAME" ]; then
      echo "Error: Unzip failed to produce $IMG_NAME"
      exit 1
   fi

   mkdir -p "$QEMU_DIR"
   mv "/tmp/$IMG_NAME" "${QEMU_DIR}/hda.qcow2"

   # Success: clear the error trap so cleanup doesn't fire
   trap - EXIT

   if [ "$VERBOSE" = true ]; then
      echo "Image placed as ${QEMU_DIR}/hda.qcow2"
   fi
}

# ---------------------------------------------------------------------------
# get_icon - Return icon filename based on MikroTik model prefix
#           CCR = Router, CRS = Switch, default = Router
# ---------------------------------------------------------------------------
get_icon() {
   local model="$1"
   case "$model" in
      ccr*)
         echo "Router-2D-Gen-White-S.svg"
         ;;
      crs*)
         echo "Switch-2D-HUB-White-S.svg"
         ;;
      *)
         echo "Router-2D-Gen-White-S.svg"
         ;;
   esac
}

# ---------------------------------------------------------------------------
# generate_template - Substitute placeholders, write template with smart diff
# ---------------------------------------------------------------------------
generate_template() {
   local TEMPLATE_SRC="templates/mikrotik-template.yml"
   local TPL_OUT="${TEMPLATES_BASE}/${DIR_PREFIX}.yml"
   local ICON
   ICON=$(get_icon "$MODEL")
   local TMP_MERGED="/tmp/merged_${DIR_PREFIX}.yml"
   local ETH_LIST_TMP="/tmp/eth_list.txt"

   if [ -n "$DEBUG_PREFIX" ]; then
      TMP_MERGED="/tmp/${DEBUG_PREFIX}-merged-${DIR_PREFIX}.yml"
   fi

   local MODEL_SANITIZED
   MODEL_SANITIZED="$(sanitize_name "$MODEL")"
   jq -r '.ether_names | map("  - " + .) | join("\n")' "templates/${MODEL_SANITIZED}.json" > "$ETH_LIST_TMP"

   awk -v desc="$DESCRIPTION" \
       -v prefix="$DIR_PREFIX" \
       -v cpu="$NUM_CPU" \
       -v ram="$RAM" \
       -v ethp="$ETHER_PORTS" \
       -v icon="$ICON" \
       -v qemu_opt="$QEMU_OPTIONS" '
       /@@DESCRIPTION@@/ { gsub(/@@DESCRIPTION@@/, desc); print; next }
       /@@DIR-PREFIX@@/ { gsub(/@@DIR-PREFIX@@/, prefix); print; next }
       /@@NUM_CPU@@/ { gsub(/@@NUM_CPU@@/, cpu); print; next }
       /@@RAM@@/ { gsub(/@@RAM@@/, ram); print; next }
       /@@ETHER_PORTS@@/ { gsub(/@@ETHER_PORTS@@/, ethp); print; next }
       /@@ICON@@/ { gsub(/@@ICON@@/, icon); print; next }
       /@@QEMU_OPTIONS@@/ { gsub(/@@QEMU_OPTIONS@@/, qemu_opt); print; next }
       /@@INTERFACE_LIST@@/ {
           while ((getline line < "'"$ETH_LIST_TMP"'") > 0) print line
           close("'"$ETH_LIST_TMP"'")
           next
       }
       { print }
   ' "$TEMPLATE_SRC" > "$TMP_MERGED"

   # Smart overwrite logic for template
   if [ -f "$TPL_OUT" ] && [ "$FORCE" = false ]; then
      if diff -q "$TPL_OUT" "$TMP_MERGED" >/dev/null 2>&1; then
         if [ "$VERBOSE" = true ]; then
            echo "Template is up-to-date (no changes), skipping."
         fi
      else
         echo "Warning: Template file $TPL_OUT already exists and differs from the new version."
         echo "Differences:"
         diff -u "$TPL_OUT" "$TMP_MERGED"
         read -rp "Overwrite with the new version? (y/N): " confirm
         if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "Aborted."
            exit 0
         fi
         cp "$TMP_MERGED" "$TPL_OUT"
         if [ "$VERBOSE" = true ]; then
            echo "Template updated at $TPL_OUT"
         fi
      fi
   else
      mkdir -p "$TEMPLATES_BASE"
      cp "$TMP_MERGED" "$TPL_OUT"
      if [ "$VERBOSE" = true ]; then
         echo "Template created at $TPL_OUT"
      fi
   fi

   rm -f "$ETH_LIST_TMP" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# register_custom_template - Add model entry to custom_templates.yml if new
# ---------------------------------------------------------------------------
register_custom_template() {
   if [ ! -f "$CUSTOM_YML" ]; then
      echo "custom_templates:" > "$CUSTOM_YML"
   fi

   if ! grep -q "name: \"${DIR_PREFIX}\"" "$CUSTOM_YML" && \
      ! grep -q "listname: \"${DESCRIPTION}\"" "$CUSTOM_YML"; then
      {
         echo "  - name: \"${DIR_PREFIX}\""
         echo "    listname: \"${DESCRIPTION}\""
      } >> "$CUSTOM_YML"
      if [ "$VERBOSE" = true ]; then
         echo "Added entry to $CUSTOM_YML"
      fi
   else
      if [ "$VERBOSE" = true ]; then
         echo "Template already registered in custom_templates.yml (skipped)"
      fi
   fi
}

# ---------------------------------------------------------------------------
# run_patch - Boot the CHR image, apply RouterOS config, then shutdown
# ---------------------------------------------------------------------------
run_patch() {
   local PATCH_SCRIPT
   PATCH_SCRIPT="$(dirname "$0")/patch-qcow2.sh"

   if [ ! -f "$PATCH_SCRIPT" ]; then
      echo "Warning: patch-qcow2.sh not found at $PATCH_SCRIPT. Skipping patching."
      return
   fi

   local PATCH_ARGS=""
   PATCH_ARGS="--monitor-port ${MONITOR_PORT} --serial-port ${SERIAL_PORT}"
   [ "$VERBOSE" = true ] && PATCH_ARGS="$PATCH_ARGS --verbose"
   [ "$DEBUG" = true ] && PATCH_ARGS="$PATCH_ARGS --debug --rnd-prefix ${DEBUG_PREFIX}"

   echo ""
   echo "=== Starting QEMU image patching ($MODEL) ==="
   [ "$VERBOSE" = true ] && echo "Running: $PATCH_SCRIPT ${QEMU_DIR}/hda.qcow2 $PATCH_ARGS"

   "$PATCH_SCRIPT" "${QEMU_DIR}/hda.qcow2" $PATCH_ARGS
   local PATCH_EXIT=$?

   if [ "$PATCH_EXIT" -ne 0 ]; then
      echo ""
      echo "ERROR: Patching failed with exit code $PATCH_EXIT."
      exit "$PATCH_EXIT"
   fi

    echo "=== Patching complete ==="

    if [ -n "$DEBUG_PREFIX" ]; then
       PATCH_SUMMARY_FILE="/tmp/${DEBUG_PREFIX}-${MODEL}-patch-summary.txt"
    else
       PATCH_SUMMARY_FILE="/tmp/${MODEL}-patch-summary.txt"
    fi
}

# ---------------------------------------------------------------------------
# print_summary - Display success message with QEMU image and template paths
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "Success! MikroTik $DESCRIPTION ($VERSION) has been added to Eve-NG."
    echo "QEMU image: $QEMU_DIR/hda.qcow2"
    echo "Template: ${TEMPLATES_BASE}/${DIR_PREFIX}.yml"
    if [ "$NO_PATCH" = false ] && [ -f "${PATCH_SUMMARY_FILE:-}" ]; then
       cat "$PATCH_SUMMARY_FILE"
    elif [ "$NO_PATCH" = true ]; then
       echo "NOTE: Patching was skipped (--no-patch). Image has NOT been configured."
    fi

   echo "You can now add the node in Eve-NG using the template name '$DIR_PREFIX'."
   if [ "$LOG" = true ] && [ -n "$LOG_FILE" ]; then
      echo "Log file: $LOG_FILE"
   fi
   if [ "$DEBUG" = true ]; then
      local debug_glob="/tmp/${DEBUG_PREFIX:+${DEBUG_PREFIX}-}*"
      if ls -1 $debug_glob >/dev/null 2>&1; then
         echo "Debug files preserved under /tmp with prefix '$DEBUG_PREFIX-':"
         ls -1 $debug_glob
      else
         echo "No preserved debug files found under /tmp matching prefix '$DEBUG_PREFIX-'."
      fi
      # if [ -n "$INFO_DEBUG_FILE" ]; then
      #    echo "Debug summary: $INFO_DEBUG_FILE"
      # fi
   fi
}

# ---------------------------------------------------------------------------
# cleanup_temp_files - Remove temporary files unless debug mode is enabled
# ---------------------------------------------------------------------------
cleanup_temp_files() {
   if [ "$DEBUG" != true ]; then
      # Clean up generated RSC file in /tmp
      rm -f "/tmp/${DEBUG_PREFIX:+${DEBUG_PREFIX}-}${MODEL}.rsc" 2>/dev/null || true

      # Clean up merged template if one was created
      rm -f "/tmp/${DEBUG_PREFIX:+${DEBUG_PREFIX}-}merged-${DIR_PREFIX}.yml" 2>/dev/null || true

      # Clean up info debug file
      if [ -n "$INFO_DEBUG_FILE" ] && [ -f "$INFO_DEBUG_FILE" ]; then
         rm -f "$INFO_DEBUG_FILE" 2>/dev/null || true
      fi
   fi
}

# ---------------------------------------------------------------------------
# main - Orchestrate the full build process
# ---------------------------------------------------------------------------
main() {
   check_dependencies
   parse_args "$@"
   generate_debug_prefix
   CACHE_DIR="./cache"
   setup_log_file
   detect_architecture
   setup_paths
   load_model_config
   mkdir -p "$CACHE_DIR"
   create_qemu_directory
   download_image
   resolve_ports
   if [ "$DEBUG" = true ]; then
      expand_debug_info
      update_patch_cmds_in_info
   fi
   generate_template
   register_custom_template
   if [ "$NO_PATCH" = false ]; then
      run_patch
   fi
   print_summary
   cleanup_temp_files
   /opt/unetlab/wrappers/unl_wrapper -a fixpermissions
}

main "$@"
