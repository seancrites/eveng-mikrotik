#!/usr/bin/env bash
# patch-qcow2.sh
# Copyright (C) 2026 Sean Crites
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Purpose: Boot CHR image, run initial config via serial console, then shutdown.

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

# Generate a per-model RSC file on the fly from the JSON definition and template.
# Returns the path to the generated RSC file.
generate_rsc() {
   local model="$1"
   local json_file="templates/${model}.json"
   local template_file="templates/mikrotik-template.rsc"
   local output_file="/tmp/${model}.rsc"

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
      echo "Usage: $0 <hda.qcow2 path> [--monitor-port N] [--serial-port N] [--verbose]"
      exit 1
   fi

   QCOW2="$(realpath "$1")"

   # Auto-detect model from path: expects .../mikrotik-<model>-<version>/hda.qcow2
   PARENT_DIR="$(basename "$(dirname "$QCOW2")")"
   if [[ "$PARENT_DIR" =~ ^mikrotik-(.+)-[0-9] ]]; then
      MODEL="${BASH_REMATCH[1]}"
   else
      echo "Error: Could not auto-detect model from path '$QCOW2'."
      echo "Expected directory name pattern: mikrotik-<model>-<version>"
      exit 1
   fi
   MONITOR_PORT=6000
   SERIAL_PORT=6001
   VERBOSE=false

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
         --verbose)
            VERBOSE=true
            shift
            ;;
         *)
            echo "Unknown option: ${2:-}"
            echo "Usage: $0 <hda.qcow2 path> [--monitor-port N] [--serial-port N] [--verbose]"
            exit 1
            ;;
      esac
   done

   # Generate the per-model RSC from JSON + template
   RSC_GENERATED="$(generate_rsc "$MODEL")"

   if [ "$VERBOSE" = true ]; then
      log "Starting QEMU for $MODEL patching..."
      log "  QCOW2:    $QCOW2"
      log "  Monitor:  telnet 127.0.0.1:$MONITOR_PORT"
      log "  Serial:   telnet 127.0.0.1:$SERIAL_PORT"
      log "  RSC:      $RSC_GENERATED"
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

   log "Serial port ready. Running expect script..."

   expect "$(dirname "$0")/patch-qcow2.exp" "$MODEL" "$SERIAL_PORT" "$MONITOR_PORT" "$RSC_GENERATED"
   EXPECT_EXIT=$?

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

   log "Patching complete."
   exit 0
}

MAIN "$@"
