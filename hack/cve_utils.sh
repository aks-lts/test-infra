#!/usr/bin/env bash

# Helper for retrieving CVE sections from upstream Kubernetes CHANGELOG files.
## get_cve_sections
# Usage: get_cve_sections <major_minor_version> <tmp_dir> <cve_var_name> [max_search]
#   <major_minor_version>  e.g. 1.29 (the base version whose later minors will be scanned)
#   <tmp_dir>              directory used to store downloaded CHANGELOG-* files
#   <cve_var_name>         name of a variable in the caller's scope which is either:
#                            - indexed array of CVE IDs (e.g. (CVE-2025-5187 CVE-2025-0426)) OR
#                            - associative array/map (declare -A CVE_PR_MAP) mapping CVE ID -> upstream PR number
#   [max_search]           optional count of subsequent minor versions to inspect (default: 3)
# Behaviour:
#   - Scans CHANGELOG-<major>.<minor+1..minor+max_search>.md until all CVEs found or range exhausted.
#   - Extracts the markdown section whose heading contains the CVE ID (case-insensitive) per CVE.
#   - Normalizes excess blank lines.
#   - If the input was an associative map and a PR number is present, appends an "upstream tracking" link line.
#   - For an indexed array input, the array is mutated (found CVEs removed). For an associative map input, the map
#     is left intact (not mutated) because removing keys would also discard PR metadata.
# Output:
#   Echoes concatenated sections separated by a single blank line.
# Requirements: bash 4+, curl, jq (only for caller normally), awk, grep, sed.

get_cve_sections() {
  local major_minor="$1"
  local tmp_dir="$2"
  local cve_var_name="$3"
  local max_search="${4:-3}"

  if [[ -z "$major_minor" || -z "$tmp_dir" || -z "$cve_var_name" ]]; then
    echo ""; return 0
  fi

  # Nameref to caller variable (could be indexed or associative)
  local -n _input_ref="${cve_var_name}"

  # Determine if associative map (CVE->PR) or plain list
  local is_assoc=0
  if declare -p "$cve_var_name" 2>/dev/null | grep -q 'declare -A'; then
    is_assoc=1
  fi

  # Working list of CVE IDs we still need to find
  local cve_ids=()
  # Optional lookup map CVE->PR
  declare -A cve_to_pr
  if (( is_assoc )); then
    local k
    for k in "${!_input_ref[@]}"; do
      cve_ids+=("$k")
      cve_to_pr["$k"]="${_input_ref[$k]}"
    done
  else
    cve_ids=("${_input_ref[@]}")
  fi

  local major="${major_minor%%.*}"
  local minor="${major_minor#*.}"
  local cve_sections=""

  # Iterate through next minor versions up to max_search
  local i
  for (( i=minor+1; i<=minor+max_search; i++ )); do
    # Stop if all CVEs found
    if [[ ${#cve_ids[@]} -eq 0 ]]; then
      break
    fi

    local ver="${major}.${i}"
    local upstream_raw="https://raw.githubusercontent.com/kubernetes/kubernetes/master/CHANGELOG/CHANGELOG-${ver}.md"
    local tmp_changelog="${tmp_dir}/CHANGELOG-${ver}.md"

    if ! curl -fLSs -o "${tmp_changelog}" "${upstream_raw}"; then
      continue
    fi

  local cve_found=()
  local cve
  for cve in "${cve_ids[@]}"; do
      [[ -z "$cve" ]] && continue
      echo "Searching for $cve from ${ver}..." >&2
      if grep -qi "$cve" "$tmp_changelog"; then
        local cve_lc section
        cve_lc=$(echo "$cve" | tr '[:upper:]' '[:lower:]')
        section=$(awk -v pat="$cve_lc" '
          BEGIN { IGNORECASE=1; in_match=0; section="" }
          /^##+[[:space:]]/ {
            if (in_match) { exit }
            line_lc=tolower($0)
            if (line_lc ~ pat) { in_match=1; section=$0 "\n" }
            next
          }
          { if (in_match) { section = section $0 "\n" } }
          END { if (in_match) { printf "%s", section } }
        ' "$tmp_changelog")
        
        if [[ -n "$section" ]]; then
          section=$(printf '%s' "$section" | tr -d '\r' | sed -E ':a;N;$!ba; s/\n{3,}/\n\n/g')

          # Remove **Affected Versions** and **Fixed Versions** blocks (heading + subsequent non-blank lines)
          section=$(printf '%s' "$section" | awk '
            BEGIN{drop=0}
            /^[[:space:]]*\*\*Affected Versions\*\*:/ {drop=1; next}
            /^[[:space:]]*\*\*Fixed Versions\*\*:/ {drop=1; next}
            drop && /^$/ {drop=0; next}
            drop {next}
            {print}
          ')

          # Standardized upstream PR annotation (always append one informative line)
          pr_ref="${cve_to_pr[$cve]}"
          if (( is_assoc )) && [[ -n "$pr_ref" ]]; then
            section+=$'\n\n'
            section+="Upstream tracking: [kubernetes/kubernetes#${pr_ref}](https://github.com/kubernetes/kubernetes/pull/${pr_ref})"
          fi

          if [[ -n "$cve_sections" ]]; then
            cve_sections+=$'\n\n'
          fi
          
          cve_sections+="$section"
          echo "Found $cve in CHANGELOG-${ver}.md" >&2
          cve_found+=("$cve")
        fi
      fi

      
    done

    # Remove found CVEs from working list (and mutate caller's indexed array if applicable)
    if [[ ${#cve_found[@]} -gt 0 ]]; then
      mapfile -t cve_ids < <(printf '%s\n' "${cve_ids[@]}" | grep -xvFf <(printf '%s\n' "${cve_found[@]}") | sed '/^$/d')
      if (( ! is_assoc )); then
        # Mutate caller's original indexed array by name
        _input_ref=("${cve_ids[@]}")
      fi
    fi

    rm -f "$tmp_changelog"
  done

  printf '%s' "$cve_sections"
}
