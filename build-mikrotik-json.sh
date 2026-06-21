#!/usr/bin/env bash
# =============================================================================
# build-mikrotik-json.sh - Generate MikroTik device interface JSON from model name
#
# PURPOSE:   Take a MikroTik model name, decode its port specification,
#            and generate a JSON file with the correct interface names in
#            alphabetical sort order. Port specifications are extracted from
#            the model name (e.g., XS, XQ, S+, G, C) and translated to the
#            corresponding RouterOS interface names.
#
# AUTHOR:    Sean Crites
# VERSION:   1.0.0
# DATE:      2026-06-20
# LICENSE:   GNU General Public License v3.0 (GPL-3.0)
#
# DEPENDENCIES:
#   - bash, sed, sort, jq, tr, awk
#
# USAGE:
#   ./build-mikrotik-json.sh MODEL
#
# MODEL should be a MikroTik model name with port specifications, such as:
#   crs510-8xs-2xq
#   CRS326-24G-2S+IN
#   crs305-1gf-16x
#
# WARNING:   This script is still in development. Use with caution and
#            verify output before relying on it.
#
# Variant suffixes (-IN, -RM, -OUT) are stripped automatically. Only the
# base model name is used for the output filename.
#
# EXAMPLE:
#   ./build-mikrotik-json.sh crs510-8xs-2xq
#   ./build-mikrotik-json.sh CRS326-24G-2S+IN
#   ./build-mikrotik-json.sh ccr2004
#
# OUTPUT:
#   templates/MODEL.json  (e.g., templates/crs510.json)
#

# ---------------------------------------------------------------------------
# Global variables - clear all at the top
# ---------------------------------------------------------------------------
MODEL_INPUT=""
MODEL_BASE=""
MODEL_JSON=""
INTERFACE_LIST=""
INTERFACE_TYPE_SUMMARY=""

# ---------------------------------------------------------------------------
# abbr_to_root - Map a port abbreviation to its RouterOS interface root name
#
# Cross-reference (as specified in task):
#   etherX  -> F, Fi, Fp, Fr, G, P, G+, P+, XG, XP
#   sfp28-X -> XS
#   qsfp28-X-X -> XQ
#   comboX  -> C, C+
# ---------------------------------------------------------------------------
abbr_to_root() {
   local abbr="$1"
   case "$abbr" in
      xs)   echo "sfp28"     ;;
      xq)   echo "qsfp28"    ;;
      s+)   echo "sfp-sfpplus" ;;
      gf|g+|p+|xg|xp|fi|fr|fp|f|g|p|x)
             echo "ether"     ;;
      c|c+) echo "combo"     ;;
      q+)   echo "qsfpplus"     ;;
      *)    echo "unknown"   ;;
   esac
}

# ---------------------------------------------------------------------------
# parse_model - Convert input model name into base name and port segments
# ---------------------------------------------------------------------------
parse_model() {
   local input_lower
   input_lower="$(printf '%s' "$MODEL_INPUT" | tr '[:upper:]' '[:lower:]')"

   # Base model is the first dash-separated component
   MODEL_BASE="$(printf '%s' "$input_lower" | cut -d'-' -f1)"

   if [ -z "$MODEL_BASE" ]; then
      echo "Error: Could not determine model base name from '$MODEL_INPUT'." >&2
      exit 1
   fi

   # Everything after the first dash is port specification.
   local raw_rest
   raw_rest="$(printf '%s' "$input_lower" | cut -d'-' -f2-)"
   [ -z "$raw_rest" ] && return

   # ------------------------------------------------------------------
   # Step 1: Normalise '+' between port specs into a dash so that
   #         dash-splitting covers both separators.
   #         "12xs+2xs" -> "12xs-2xs", while "s+" stays intact because
   #         the '+' is not followed by a digit.
   local rest
   rest="$(printf '%s' "$raw_rest" | sed -E 's/\+([0-9])/-\1/g')"

   # ------------------------------------------------------------------
   # Step 2: Expand port spec segments into a local array.
   #   - Split on dashes.
   #   - Within each batch, a '+' is a separator only when BOTH sides
   #     start with digits (e.g. "12xs+2xs" -> "12xs","2xs").
   # ------------------------------------------------------------------
   local -a segments=()
   local batch
   for batch in $(printf '%s' "$rest" | tr '-' '\n'); do
      [ -z "$batch" ] && continue
      if printf '%s' "$batch" | grep -qE '\+'; then
         local rawSegs="$batch"
         while [[ "$rawSegs" =~ ^([0-9]+[a-z]*\+[0-9]+[a-z]*)(.*)$ ]]; do
            segments+=("${BASH_REMATCH[1]}")
            rawSegs="${BASH_REMATCH[2]}"
         done
         [ -n "$rawSegs" ] && segments+=("$rawSegs")
      else
         segments+=("$batch")
      fi
   done

   local segment count abbr
   for segment in "${segments[@]}"; do
      [ -z "$segment" ] && continue

      # Strip per-segment variant suffix (in|rm|out) at end.
      # The suffix is appended directly after the port code, no separator:
      #   "2s+in" -> "2s+",  "2sin" -> "2s+",  "24g-in" -> "24g"
      if printf '%s' "$segment" | grep -qE '(in|rm|out)$'; then
         segment="$(printf '%s' "$segment" | sed -E 's/(in|rm|out)$//')"
      fi
      [ -z "$segment" ] && continue

      # Split leading digits from the code
      if [[ "$segment" =~ ^([0-9]+)(.+)$ ]]; then
         count="${BASH_REMATCH[1]}"
         abbr="$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')"
      else
         echo "Warning: Ignoring unrecognized segment '$segment' in model '$MODEL_INPUT'." >&2
         continue
      fi

      local root
      root="$(abbr_to_root "$abbr")"
      if [ -z "$root" ] || [ "$root" = "unknown" ]; then
         echo "Warning: Unknown port abbreviation '$abbr', skipping segment '$segment'." >&2
         continue
      fi

      # Quad interfaces (qsfp28 / XQ) have sub-lanes; only list lane 1 since
      # we cannot emulate channelized optics in Eve-NG.
      if [ "$root" = "qsfp28" ]; then
         local j
         for (( j=1; j<=count; j++ )); do
            printf 'qsfp28-%d-1\n' "$j"
         done
         continue
      fi

      local i
      for (( i=1; i<=count; i++ )); do
         # Rule: if root name ends in a digit, insert a dash before the index
         if printf '%s' "$root" | grep -qE '[0-9]$'; then
            printf '%s-%d\n' "$root" "$i"
         else
            printf '%s%d\n' "$root" "$i"
         fi
      done
   done | sort -V > "/tmp/${MODEL_BASE}_ifaces.txt"

   # Deduplicate while preserving the version-sort order (sort -u re-sorts
   # lexicographically, which would break numeric ordering).
   local -a unique=()
   local prev=""
   while IFS= read -r line; do
      [ "$line" != "$prev" ] && unique+=("$line")
      prev="$line"
   done < "/tmp/${MODEL_BASE}_ifaces.txt"
   rm -f "/tmp/${MODEL_BASE}_ifaces.txt"

   INTERFACE_LIST=""
   local iface
   for iface in "${unique[@]}"; do
      INTERFACE_LIST+="$iface "
   done
   INTERFACE_LIST="$(printf '%s' "$INTERFACE_LIST" | xargs)"

   # Build interface type summary by matching known root prefixes
   # against each interface name.  This preserves multi-digit roots
   # like "qsfp28" and "sfp-sfpplus" correctly.
   if [ -n "$INTERFACE_LIST" ]; then
      INTERFACE_TYPE_SUMMARY="$(printf '%s\n' "$INTERFACE_LIST" | tr ' ' '\n' | awk '
         {
            name = $0
            # Check known roots, longest first to avoid partial matches
            if      (index(name, "qsfp28") == 1)     { counts["qsfp28"]++ }
            else if (index(name, "sfp-sfpplus") == 1) { counts["sfp-sfpplus"]++ }
            else if (index(name, "sfp28") == 1)      { counts["sfp28"]++ }
            else if (index(name, "ether") == 1)      { counts["ether"]++ }
            else if (index(name, "combo") == 1)      { counts["combo"]++ }
            else if (index(name, "qsfpplus") == 1)   { counts["qsfpplus"]++ }
            else { counts["unknown"]++ }
         }
         END {
            # Sort keys manually for POSIX compatibility
            n = 0
            for (k in counts) {
               n++
               keys[n] = k
            }
            for (i = 1; i <= n; i++) {
               for (j = i + 1; j <= n; j++) {
                  if (keys[i] > keys[j]) {
                     tmp = keys[i]; keys[i] = keys[j]; keys[j] = tmp
                  }
               }
            }
            for (i = 1; i <= n; i++) {
               printf "%s: %d\n", keys[i], counts[keys[i]]
            }
         }
      ')"
   else
      INTERFACE_TYPE_SUMMARY=""
   fi
}

# ---------------------------------------------------------------------------
# generate_json - Write JSON with interface names to templates/MODEL_BASE.json
# ---------------------------------------------------------------------------
generate_json() {
   MODEL_JSON="templates/${MODEL_BASE}.json"

   # Ensure destination directory exists
   mkdir -p "templates"

   # Build JSON array of interface names
   local iface_json
   if [ -n "$INTERFACE_LIST" ]; then
      iface_json="$(printf '%s\n' "$INTERFACE_LIST" | tr ' ' '\n' | jq -R . | jq -s .)"
   else
      iface_json="[]"
   fi

   # Compute total interface count
   local port_count
   port_count="$(printf '%s' "$INTERFACE_LIST" | wc -w)"

   # Assemble JSON document
   local new_json
   new_json="$(jq -n \
      --arg name "$MODEL_BASE" \
      --arg model "$MODEL_INPUT" \
      --arg description "MikroTik ${MODEL_BASE^^}" \
      --argjson num_cpu 1 \
      --argjson ram 256 \
      --argjson ether_ports "$port_count" \
      --argjson ether_names "$iface_json" \
      '{
         name: $name,
         model: $model,
         description: $description,
         num_cpu: $num_cpu,
         ram: $ram,
         ether_ports: $ether_ports,
         ether_names: $ether_names
      }')"

   # If the JSON file already exists, show Current/New summaries and
   # prompt before overwriting.
   if [ -f "$MODEL_JSON" ]; then
      local old_count
      old_count="$(jq '.ether_ports' "$MODEL_JSON")"

      # Build interface type summary for the existing file
      local existing_summary=""
      local existing_names
      existing_names="$(jq -r '.ether_names[]' "$MODEL_JSON")"
      if [ -n "$existing_names" ]; then
         existing_summary="$(printf '%s\n' "$existing_names" | awk '
            {
               name = $0
               if      (index(name, "qsfp28") == 1)     { counts["qsfp28"]++ }
               else if (index(name, "sfp-sfpplus") == 1) { counts["sfp-sfpplus"]++ }
               else if (index(name, "sfp28") == 1)      { counts["sfp28"]++ }
               else if (index(name, "ether") == 1)      { counts["ether"]++ }
               else if (index(name, "combo") == 1)      { counts["combo"]++ }
               else { counts["unknown"]++ }
            }
            END {
               n = 0
               for (k in counts) { n++; keys[n] = k }
               for (i = 1; i <= n; i++) {
                  for (j = i + 1; j <= n; j++) {
                     if (keys[i] > keys[j]) { tmp = keys[i]; keys[i] = keys[j]; keys[j] = tmp }
                  }
               }
               for (i = 1; i <= n; i++) { printf "%s: %d\n", keys[i], counts[keys[i]] }
            }
         ')"
      fi

      echo ""
      echo "WARNING: $MODEL_JSON already exists."
      echo "Current:"
      if [ -n "$existing_summary" ]; then
         while IFS= read -r line; do
            [ -n "$line" ] && echo "  $line"
         done <<< "$existing_summary"
      else
         echo "  (no interfaces)"
      fi
      echo ""
      echo "New:"
      if [ -n "$INTERFACE_TYPE_SUMMARY" ]; then
         while IFS= read -r line; do
            [ -n "$line" ] && echo "  $line"
         done <<< "$INTERFACE_TYPE_SUMMARY"
      else
         echo "  (no interfaces)"
      fi
      echo ""
      read -rp "Overwrite existing file? (y/N): " confirm
      if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
         echo "Skipped overwrite. JSON file left unchanged."
         return
      fi
   fi

   printf '%s\n' "$new_json" > "$MODEL_JSON"
}

# ---------------------------------------------------------------------------
# main - Entry point
# ---------------------------------------------------------------------------
main() {
   if [ -z "${1:-}" ]; then
      echo "Error: A MikroTik model name is required."
      echo "Usage: $0 MODEL"
      echo "Example: $0 crs510-8xs-2xq"
      exit 1
   fi

   MODEL_INPUT="$1"
   parse_model
   generate_json

   printf '\nInterface list for %s:\n' "${MODEL_BASE^^}"
   if [ -n "$INTERFACE_LIST" ]; then
      printf '%s\n' "$INTERFACE_LIST" | tr ' ' '\n'
   else
      echo "  (no ports detected)"
   fi

   # Print a summary of interface type counts
   if [ -n "$INTERFACE_TYPE_SUMMARY" ]; then
      printf '\nInterface type summary for %s:\n' "${MODEL_BASE^^}"
      while IFS= read -r line; do
         [ -n "$line" ] && printf '  %s\n' "$line"
      done <<< "$INTERFACE_TYPE_SUMMARY"
   fi

   printf '\nJSON written to: %s\n' "$MODEL_JSON"
}

main "$@"
