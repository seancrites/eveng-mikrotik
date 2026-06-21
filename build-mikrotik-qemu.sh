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

# ---------------------------------------------------------------------------
# check_dependencies - Verify all required CLI tools are available
# ---------------------------------------------------------------------------
check_dependencies() {
   local deps="curl jq unzip grep awk sed mkdir mv diff"
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
      LOG_FILE="/tmp/build-mikrotik-qemu-${timestamp}.log"
      exec > >(tee -a "$LOG_FILE") 2>&1
      echo "Logging output to $LOG_FILE"
   fi
}

# ---------------------------------------------------------------------------
# generate_debug_prefix - Create a random prefix for debug artifacts
# ---------------------------------------------------------------------------
generate_debug_prefix() {
   if [ "$DEBUG" = true ]; then
      DEBUG_PREFIX="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 4)"
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
   [ "$DEBUG" = true ] && patch_sh_cmd="$patch_sh_cmd --rnd-prefix ${DEBUG_PREFIX}"

   local patch_exp_cmd
   patch_exp_cmd="$(dirname "$0")/patch-qcow2.exp ${MODEL} ${SERIAL_PORT} ${MONITOR_PORT} /tmp/${DEBUG_PREFIX:+${DEBUG_PREFIX}-}${MODEL}.rsc"

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

   if [ "$VERBOSE" = true ]; then
      echo "Detected architecture: $TPL_SUBDIR"
   fi
}

# ---------------------------------------------------------------------------
# setup_paths - Set all directory and file paths for Eve-NG
# ---------------------------------------------------------------------------
setup_paths() {
   HTML_BASE="/opt/unetlab/html"
   INCLUDES_DIR="${HTML_BASE}/includes"
   QEMU_BASE="/opt/unetlab/addons/qemu"
   TEMPLATES_BASE="${HTML_BASE}/${TPL_SUBDIR}_templates"
   CUSTOM_YML="${INCLUDES_DIR}/custom_templates.yml"
}

# ---------------------------------------------------------------------------
# load_model_config - Validate model JSON exists and extract fields
# ---------------------------------------------------------------------------
load_model_config() {
   local JSON_FILE="templates/${MODEL}.json"

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
   DIR_PREFIX="mikrotik-${MODEL}"

   if [ "$VERBOSE" = true ]; then
      echo "Model: $DESCRIPTION (prefix: $DIR_PREFIX)"
   fi
}

# ---------------------------------------------------------------------------
# create_qemu_directory - Create the model/version QEMU directory with prompt
# ---------------------------------------------------------------------------
create_qemu_directory() {
   QEMU_DIR="${QEMU_BASE}/mikrotik-${MODEL}-${VERSION}"

   if [ -d "$QEMU_DIR" ] && [ "$FORCE" = false ]; then
      echo "Warning: Directory $QEMU_DIR already exists."
      read -p "Overwrite existing files? (y/N): " confirm
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
# download_image - Download CHR image, unzip, and place as hda.qcow2
# ---------------------------------------------------------------------------
download_image() {
   local ZIP_FILE="/tmp/chr-${VERSION}.img.zip"
   local IMG_NAME="chr-${VERSION}.img"
   local URL="https://download.mikrotik.com/routeros/${VERSION}/chr-${VERSION}.img.zip"

   if [ "$VERBOSE" = true ]; then
      echo "Downloading from $URL..."
   fi

   if [ -n "${PROXY:-}" ]; then
      curl -fL --proxy "$PROXY" -o "$ZIP_FILE" "$URL"
   else
      curl -fL -o "$ZIP_FILE" "$URL"
   fi

   if [ ! -f "$ZIP_FILE" ]; then
      echo "Error: Download failed."
      exit 1
   fi

   unzip -o "$ZIP_FILE" -d /tmp/
   if [ ! -f "/tmp/$IMG_NAME" ]; then
      echo "Error: Unzip failed to produce $IMG_NAME"
      exit 1
   fi

   mv "/tmp/$IMG_NAME" "${QEMU_DIR}/hda.qcow2"

   if [ "$VERBOSE" = true ]; then
      echo "Image placed as ${QEMU_DIR}/hda.qcow2"
   fi

   rm -f "$ZIP_FILE"
}

# ---------------------------------------------------------------------------
# generate_template - Substitute placeholders, write template with smart diff
# ---------------------------------------------------------------------------
generate_template() {
   local TEMPLATE_SRC="templates/mikrotik-template-${TPL_SUBDIR}.yml"
   local TPL_OUT="${TEMPLATES_BASE}/${DIR_PREFIX}.yml"
   local TMP_MERGED="/tmp/merged_${DIR_PREFIX}.yml"
   local ETH_LIST_TMP="/tmp/eth_list.txt"

   if [ -n "$DEBUG_PREFIX" ]; then
      TMP_MERGED="/tmp/${DEBUG_PREFIX}-merged-${DIR_PREFIX}.yml"
   fi

   jq -r '.ether_names | map("  - " + .) | join("\n")' "templates/${MODEL}.json" > "$ETH_LIST_TMP"

   awk -v desc="$DESCRIPTION" \
       -v prefix="$DIR_PREFIX" \
       -v cpu="$NUM_CPU" \
       -v ram="$RAM" \
       -v ethp="$ETHER_PORTS" '
       /@@DESCRIPTION@@/ { gsub(/@@DESCRIPTION@@/, desc); print; next }
       /@@DIR-PREFIX@@/ { gsub(/@@DIR-PREFIX@@/, prefix); print; next }
       /@@NUM_CPU@@/ { gsub(/@@NUM_CPU@@/, cpu); print; next }
       /@@RAM@@/ { gsub(/@@RAM@@/, ram); print; next }
       /@@ETHER_PORTS@@/ { gsub(/@@ETHER_PORTS@@/, ethp); print; next }
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
         read -p "Overwrite with the new version? (y/N): " confirm
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
   [ "$DEBUG" = true ] && PATCH_ARGS="$PATCH_ARGS --rnd-prefix ${DEBUG_PREFIX}"

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
}

# ---------------------------------------------------------------------------
# print_summary - Display success message with QEMU image and template paths
# ---------------------------------------------------------------------------
print_summary() {
   echo ""
   echo "Success! MikroTik $DESCRIPTION ($VERSION) has been added to Eve-NG."
   echo "QEMU image: $QEMU_DIR/hda.qcow2"
   echo "Template: ${TEMPLATES_BASE}/${DIR_PREFIX}.yml"
   if [ "$NO_PATCH" = false ]; then
      echo "Image has been patched with model-specific RouterOS configuration."
   else
      echo "NOTE: Patching was skipped (--no-patch). Image has NOT been configured."
   fi

   echo "You can now add the node in Eve-NG using the template name '$DIR_PREFIX'."
   if [ "$LOG" = true ] && [ -n "$LOG_FILE" ]; then
      echo "Log file: $LOG_FILE"
   fi
   if [ "$DEBUG" = true ]; then
      echo "Debug files preserved under /tmp with prefix '$DEBUG_PREFIX-'."
      if [ -n "$INFO_DEBUG_FILE" ]; then
         echo "Debug summary: $INFO_DEBUG_FILE"
      fi
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
   setup_log_file
   detect_architecture
   setup_paths
   load_model_config
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
}

main "$@"
