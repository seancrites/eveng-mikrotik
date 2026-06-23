#!/usr/bin/env bash
# =============================================================================
# patch-qcow2.sh - Boot CHR image, apply RouterOS config, then shutdown
#
# PURPOSE:   Boot a MikroTik CHR qcow2 image with QEMU, connect via serial
#            console, apply per-model RouterOS configuration (interface
#            renaming, identity, etc.), then cleanly shut down the guest.
# AUTHOR:    Sean Crites
# VERSION:   1.0.0
# DATE:      2026-06-20
# LICENSE:   GNU General Public License v3.0 (GPL-3.0)
#
# DEPENDENCIES:
#   - qemu-system-x86_64, expect, nc, jq
#
# USAGE:
#   ./patch-qcow2.sh <hda.qcow2 path> [OPTIONS]
#
# Options:
#   -h, --help          Show this help message and exit
#   --monitor-port N    QEMU monitor port (default: 6000)
#   --serial-port  N    Serial console port (default: 6001)
#   --rnd-prefix   S    4-char random prefix for temp files (default: none)
#   --verbose           Show detailed progress
#   --debug             Enable debug output from the expect script
#
# EXAMPLE:
#   ./patch-qcow2.sh /opt/unetlab/addons/qemu/mikrotik-crs309-7.22.1/hda.qcow2 --verbose
#


set -euo pipefail

check_dependencies() {
   local deps="qemu-system-x86_64 expect nc jq"
   for dep in $deps; do
      if ! command -v "$dep" >/dev/null 2>&1; then
         echo "Error: Required dependency '$dep' is not available. Please install it."
         exit 1
      fi
   done
}

log() {
   echo "[$(date '+%H:%M:%S')] $1" >&2
}

# ---------------------------------------------------------------------------
# sanitize_name - Replace characters that cause issues in EveNG filesystem names
#                 Currently: '+' -> 'plus'
# ---------------------------------------------------------------------------
sanitize_name() {
   local name="$1"
   printf '%s' "$name" | sed 's/+/plus/g'
}

# Generate a per-model RSC file on the fly from the JSON definition and template.
# Returns the path to the generated RSC file.
generate_rsc() {
   local model_raw="$1"
   local model_sanitized
   model_sanitized="$(sanitize_name "$model_raw")"
   local model
   model="$(echo "$model_sanitized" | tr '[:upper:]' '[:lower:]')"
   local rnd_prefix="$2"
   local json_file="templates/${model}.json"
   local template_file="templates/mikrotik-template.rsc"

   if [ -n "$rnd_prefix" ]; then
      local output_file="/tmp/${rnd_prefix}-${model}.rsc"
   else
      local output_file="/tmp/${model}.rsc"
   fi

   if [ ! -f "$json_file" ]; then
      echo "Error: Model JSON file not found: $json_file"
      exit 1
   fi

   if [ ! -f "$template_file" ]; then
      echo "Error: RSC template file not found: $template_file"
      exit 1
   fi

   local name
   name="$(jq -r '.name' "$json_file")"
   local name_upper
   name_upper="$(echo "$name" | tr '[:lower:]' '[:upper:]')"

   local ether_ports
   ether_ports="$(jq -r '.ether_names | length' "$json_file")"

   # Copy template and do simple placeholder replacements
   cp "$template_file" "$output_file"
   sed -i "s/@@ETHER_PORTS@@/${ether_ports}/g" "$output_file"
   sed -i "s/@@NAME@@/${name_upper}/g" "$output_file"

   # Generate interface rename lines into a temp file
   local rename_tmp
   rename_tmp="$(mktemp /tmp/${model}_rename_XXXXXXXX.tmp)"
   jq -r '.ether_names[]' "$json_file" | awk '{
       printf "            set [find default-name=ether%d] disable-running-check=no name=%s\n", NR, $0
   }' > "$rename_tmp"

   # Replace @@ETHER_NAMES_RENAME@@ placeholder line with generated content
   sed -i "/@@ETHER_NAMES_RENAME@@/{
       r ${rename_tmp}
       d
   }" "$output_file"

    rm -f "$rename_tmp"

    log "Generated RSC: $output_file (${ether_ports} ports)"
   echo "$output_file"
}

MAIN() {
   check_dependencies

   if [ $# -lt 1 ]; then
      echo "Usage: $0 <hda.qcow2 path> [--monitor-port N] [--serial-port N] [--rnd-prefix S] [--verbose] [--debug]"
      exit 1
   fi

   QCOW2="$(realpath "$1")"

   # Auto-detect model from path: expects .../mikrotik-<model>-<version>/hda.qcow2
   PARENT_DIR="$(basename "$(dirname "$QCOW2")")"
   if [[ "$PARENT_DIR" =~ ^mikrotik-(.+)-([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
      MODEL="${BASH_REMATCH[1]}"
   else
      echo "Error: Could not auto-detect model from path '$QCOW2'."
      echo "Expected directory name pattern: mikrotik-<model>-<version>"
      exit 1
   fi
   MONITOR_PORT=6000
   SERIAL_PORT=6001
   VERBOSE=false
   DEBUG=false
   RND_PREFIX=""
   EXPECT_ARGS=()

   while [ $# -gt 1 ]; do
      case "${2:-}" in
         --monitor-port)
            MONITOR_PORT="${3:?--monitor-port requires a value}"
            shift 2
            ;;
         --serial-port)
            SERIAL_PORT="${3:?--serial-port requires a value}"
            shift 2
            ;;
         --rnd-prefix)
            RND_PREFIX="${3:?--rnd-prefix requires a value}"
            shift 2
            ;;
         --verbose)
            VERBOSE=true
            EXPECT_ARGS+=(--verbose)
            shift
            ;;
         --debug)
            DEBUG=true
            EXPECT_ARGS+=(--debug)
            shift
            ;;
         *)
            echo "Unknown option: ${2:-}"
            echo "Usage: $0 <hda.qcow2 path> [--monitor-port N] [--serial-port N] [--rnd-prefix S] [--verbose] [--debug]"
            exit 1
            ;;
      esac
   done

   # Generate the per-model RSC from JSON + template
   RSC_GENERATED="$(generate_rsc "$MODEL" "$RND_PREFIX")"

   if [ "$VERBOSE" = true ]; then
      log "Starting QEMU for $MODEL patching..."
      log "  QCOW2:    $QCOW2"
      log "  Monitor:  telnet 127.0.0.1:$MONITOR_PORT"
      log "  Serial:   telnet 127.0.0.1:$SERIAL_PORT"
      log "  RSC:      $RSC_GENERATED"
      log "  Command:"
      log "    nohup qemu-system-x86_64 \\"
      log "      -machine type=pc,accel=kvm \\"
      log "      -smp 2 -m 1024 \\"
      log "      -drive file=$QCOW2,format=raw,if=ide \\"
      log "      -nographic -no-user-config -nodefaults \\"
      log "      -display none -vga std -rtc base=utc \\"
      log "      -monitor telnet:127.0.0.1:$MONITOR_PORT,server,nowait \\"
      log "      -serial telnet:127.0.0.1:$SERIAL_PORT,server,nowait \\"
      log "      >/dev/null 2>&1 &"
   fi

   nohup qemu-system-x86_64 \
      -machine type=pc,accel=kvm \
      -smp 2 -m 1024 \
      -drive file="$QCOW2",format=raw,if=ide \
      -nographic -no-user-config -nodefaults \
      -display none -vga std -rtc base=utc \
      -monitor telnet:127.0.0.1:$MONITOR_PORT,server,nowait \
      -serial telnet:127.0.0.1:$SERIAL_PORT,server,nowait \
      >/dev/null 2>&1 &

   log "QEMU daemon started. Waiting for guest boot..."

   # Poll for QEMU to be ready (telnet accepts connections) — up to 15s
   READY=false
   for i in $(seq 1 8); do
      if (echo >/dev/tcp/127.0.0.1/$SERIAL_PORT) 2>/dev/null; then
         READY=true
         break
      fi
      sleep 2
   done

   if [ "$READY" != true ]; then
      log "ERROR: Serial port $SERIAL_PORT not reachable after 15s"
      exit 1
   fi

   log "Serial port ready. Running expect script...(Can take ~30s to complete)"
   [ "$VERBOSE" = true ] && log "  Command: expect $(dirname "$0")/patch-qcow2.exp $MODEL $SERIAL_PORT $MONITOR_PORT $RSC_GENERATED ${EXPECT_ARGS[*]}"

   EXPECT_OUT="/tmp/${RND_PREFIX:+${RND_PREFIX}-}${MODEL}-expect-output.txt"
   if [ "$VERBOSE" = true ]; then
      expect "$(dirname "$0")/patch-qcow2.exp" "$MODEL" "$SERIAL_PORT" "$MONITOR_PORT" "$RSC_GENERATED" "${EXPECT_ARGS[@]}" 2>&1 | tee "$EXPECT_OUT"
      EXPECT_EXIT=${PIPESTATUS[0]}
   else
      expect "$(dirname "$0")/patch-qcow2.exp" "$MODEL" "$SERIAL_PORT" "$MONITOR_PORT" "$RSC_GENERATED" "${EXPECT_ARGS[@]}" > "$EXPECT_OUT" 2>&1
      EXPECT_EXIT=$?
   fi

   # Poll for QEMU process to exit (every 2s up to ~60s)
   QEMU_GONE=false
   for i in $(seq 1 30); do
      if ! pgrep -x qemu-system-x86_64 >/dev/null 2>&1; then
         QEMU_GONE=true
         break
      fi
      sleep 2
   done

   if [ "$QEMU_GONE" != true ]; then
      log "WARN: QEMU still running after expect completed; sending quit to monitor..."
      echo -e "quit" | nc -w 2 127.0.0.1 "$MONITOR_PORT" 2>/dev/null || true
      sleep 3
      if pgrep -x qemu-system-x86_64 >/dev/null 2>&1; then
         log "ERROR: QEMU still running after monitor quit."
         log "Monitor: telnet 127.0.0.1:$MONITOR_PORT"
         exit 1
      fi
   fi

   if [ "$EXPECT_EXIT" -ne 0 ]; then
      log "ERROR: expect script failed with exit code $EXPECT_EXIT"
      exit "$EXPECT_EXIT"
   fi

   # Write summary file for build script by extracting relevant lines from expect output
   SUMFILE="/tmp/${RND_PREFIX:+${RND_PREFIX}-}${MODEL}-patch-summary.txt"
   grep -E "^Image has been patched|^Additional patches:|^  templates/" "$EXPECT_OUT" > "$SUMFILE" 2>/dev/null || true

   log "Patching complete."
   exit 0
}

MAIN "$@"
