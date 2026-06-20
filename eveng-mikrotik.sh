#!/usr/bin/env bash
# eveng-mikrotik.sh
# Copyright (C) 2026 Sean Crites
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# Purpose: Download MikroTik CHR and create Eve-NG templates for specific models.
# Dependencies: curl, jq, unzip, grep, awk, sed, mkdir, mv, diff
# Usage: ./eveng-mikrotik.sh MODEL VERSION [--verbose] [--force] [--dev]
# Example: ./eveng-mikrotik.sh crs309 7.22.1 --dev --verbose

# Proxy configuration (edit if needed; leave empty to disable)
# PROXY="http://your-proxy:port"

check_dependencies() {
   local deps="curl jq unzip grep awk sed mkdir mv diff"
   for dep in $deps; do
      if ! command -v "$dep" >/dev/null 2>&1; then
         echo "Error: Required dependency '$dep' is not available. Please install it."
         exit 1
      fi
   done
}

show_help() {
   echo "Usage: $0 MODEL VERSION [OPTIONS]"
   echo ""
   echo "Creates MikroTik CHR model template for Eve-NG."
   echo ""
   echo "Options:"
   echo "  --help     Show this help"
   echo "  --verbose  Show detailed step-by-step progress"
   echo "  --force    Overwrite existing files/directories without prompting"
   echo "  --dev      Use abbreviated dev directory structure for local testing"
   exit 0
}

main() {
   # Preflight
   check_dependencies

   VERBOSE=false
   FORCE=false
   DEV_MODE=false
   MODEL=""
   VERSION=""

   # Parse arguments
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
         --dev)
            DEV_MODE=true
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

   if [ "$VERBOSE" = true ]; then
      echo "=== Starting Eve-NG MikroTik CHR setup for model '$MODEL' version '$VERSION' ==="
   fi

   # Host architecture (needed early for dev paths)
   if grep -qi amd /proc/cpuinfo; then
      TPL_SUBDIR="amd"
   else
      TPL_SUBDIR="intel"
   fi

   if [ "$VERBOSE" = true ]; then
      echo "Detected architecture: $TPL_SUBDIR"
   fi

   # Path configuration (dev mode for local testing)
   if [ "$DEV_MODE" = true ]; then
      HTML_BASE="./dev_html"
      INCLUDES_DIR="./dev_html_includes"
      QEMU_BASE="./dev_qemu"
      TEMPLATES_BASE="./dev_html_${TPL_SUBDIR}_templates"
      if [ "$VERBOSE" = true ]; then
         echo "Dev mode enabled: using abbreviated paths (dev_* directories)"
      fi
   else
      HTML_BASE="/opt/unetlab/html"
      INCLUDES_DIR="${HTML_BASE}/includes"
      QEMU_BASE="/opt/unetlab/addons/qemu"
      TEMPLATES_BASE="${HTML_BASE}/${TPL_SUBDIR}_templates"
   fi

   CUSTOM_YML="${INCLUDES_DIR}/custom_templates.yml"

   if [ "$VERBOSE" = true ]; then
      echo "Loading model data from templates/${MODEL}.json..."
   fi

   # JSON check
   JSON_FILE="templates/${MODEL}.json"
   if [ ! -f "$JSON_FILE" ]; then
      echo "Error: Model '$MODEL' not supported. JSON file '$JSON_FILE' is missing."
      echo "Add the JSON file to the templates/ directory to support this model."
      exit 1
   fi

   # Load JSON values
   DESCRIPTION=$(jq -r '.description' "$JSON_FILE")
   NUM_CPU=$(jq -r '.num_cpu' "$JSON_FILE")
   RAM=$(jq -r '.ram' "$JSON_FILE")
   ETHER_PORTS=$(jq -r '.ether_ports' "$JSON_FILE")
   DIR_PREFIX="mikrotik-${MODEL}"

   if [ "$VERBOSE" = true ]; then
      echo "Model: $DESCRIPTION (prefix: $DIR_PREFIX)"
   fi

   # Qemu directory (script only creates this one, per requirements)
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

   # Download (always run for new versions)
   ZIP_FILE="/tmp/chr-${VERSION}.img.zip"
   IMG_NAME="chr-${VERSION}.img"
   URL="https://download.mikrotik.com/routeros/${VERSION}/chr-${VERSION}.img.zip"

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

   # Unzip and move
   unzip -o "$ZIP_FILE" -d /tmp/
   if [ ! -f "/tmp/$IMG_NAME" ]; then
      echo "Error: Unzip failed to produce $IMG_NAME"
      exit 1
   fi

   mv "/tmp/$IMG_NAME" "${QEMU_DIR}/hda.qcow2"

   if [ "$VERBOSE" = true ]; then
      echo "Image placed as ${QEMU_DIR}/hda.qcow2"
   fi

   # Generate template candidate
   TEMPLATE_SRC="templates/mikrotik-template.yml"
   TPL_OUT="${TEMPLATES_BASE}/${DIR_PREFIX}.yml"
   TMP_MERGED="/tmp/merged_${DIR_PREFIX}.yml"
   ETH_LIST_TMP="/tmp/eth_list.txt"

   jq -r '.ether_names | map("  - " + .) | join("\n")' "$JSON_FILE" > "$ETH_LIST_TMP"

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
      # Do NOT create templates dir in dev mode (user must pre-create dev dirs)
      if [ "$DEV_MODE" = false ]; then
         mkdir -p "/opt/unetlab/html/templates/${TPL_SUBDIR}"
      fi
      cp "$TMP_MERGED" "$TPL_OUT"
      if [ "$VERBOSE" = true ]; then
         echo "Template created at $TPL_OUT"
      fi
   fi

   # Update custom_templates.yml
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

   # Cleanup
   rm -f "$ZIP_FILE" "$ETH_LIST_TMP" "$TMP_MERGED" 2>/dev/null || true

   echo ""
   echo "Success! MikroTik $DESCRIPTION ($VERSION) has been added to Eve-NG."
   echo "QEMU image: $QEMU_DIR/hda.qcow2"
   echo "Template: $TPL_OUT"
   echo "You can now add the node in Eve-NG using the template name '$DIR_PREFIX'."
}

main "$@"
