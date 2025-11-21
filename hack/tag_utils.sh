#!/usr/bin/env bash

# Helper functions for querying AKS LTS related tags from the kubernetes repo.
# Exposed API:
#   get_aks_lts_tags_json [max_pages]
#     -> Emits JSON map of minor version to an array of the newest two tags for that minor
#        ONLY for minors where at least one of the two tags has the "-akslts" suffix.
#        Example:
#        {
#          "1.30": ["1.30.100-akslts", "1.30.14"],
#          "1.29": ["1.29.101-akslts", "1.29.100-akslts"]
#        }
# Implementation details:
#   - Pages through the GitHub tags API (newest first) collecting up to 2 tags per minor.
#   - A tag's leading 'v' (if any) is stripped.
#   - Requires 'jq'.
#   - Authorization header added only if GITHUB_TOKEN is set (for higher rate limits).

get_aks_lts_tags_json() {
  local max_pages=${1:-5}
  local page=1
  local org=${GITHUB_ORG_NAME:-aks-lts}

  declare -A minor_tags      # space-delimited collected tags per <major>.<minor>
  declare -A minor_counts    # count of collected tags per minor
  declare -A minor_has_lts   # presence flag if any collected tag contains -akslts
  declare -A seen_tag        # de-dup across pages

  while (( page <= max_pages )); do
    local url="https://api.github.com/repos/${org}/kubernetes/tags?per_page=100&page=${page}"
    local resp
    resp=$(curl -s -H "Accept: application/vnd.github+json" \
                 ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
                 -H "X-GitHub-Api-Version: 2022-11-28" \
                 "$url")

    # Break on empty / invalid response
    if [[ -z "$resp" ]] || [[ $(echo "$resp" | jq 'length') -eq 0 ]]; then
      break
    fi

    mapfile -t names < <(echo "$resp" | jq -r '.[].name' | sed 's/^v//')
    ((${#names[@]} == 0)) && break

    for tag in "${names[@]}"; do
      [[ -n "${seen_tag[$tag]}" ]] && continue
      seen_tag[$tag]=1
      # Match semantic pattern X.Y.Z (allow suffix after patch)
      if [[ $tag =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)([-].*)?$ ]]; then
        local mm="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
        local count=${minor_counts[$mm]:-0}
        if (( count < 2 )); then
          if [[ -z "${minor_tags[$mm]}" ]]; then
            minor_tags[$mm]="$tag"
          else
            minor_tags[$mm]+=" $tag"
          fi
          minor_counts[$mm]=$((count+1))
          [[ $tag == *-akslts* ]] && minor_has_lts[$mm]=1
        fi
      fi
    done

    page=$((page+1))
  done

  # Collect eligible minor keys
  local eligible=()
  for mm in "${!minor_tags[@]}"; do
    if (( ${minor_counts[$mm]:-0} >= 2 )) && [[ -n "${minor_has_lts[$mm]}" ]]; then
      eligible+=("$mm")
    fi
  done

  # Sort keys descending (newest major.minor first)
  if ((${#eligible[@]})); then
    mapfile -t eligible < <(printf '%s\n' "${eligible[@]}" | sort -r -V)
  fi

  # Emit JSON map in sorted order
  local first_minor=1
  echo "{" 
  for mm in "${eligible[@]}"; do
    local arr_json=""
    for t in ${minor_tags[$mm]}; do
      arr_json+="${arr_json:+,}\"$t\""
    done
    if (( ! first_minor )); then
      echo ","
    fi
    echo -n "  \"$mm\": [$arr_json]"
    first_minor=0
  done
  echo
  echo "}"
}

# Convenience loader: populate arrays for shell usage, with optional limit.
# Usage:
#   load_aks_lts_tags_into_shell [N] [max_pages]
#     N          = optional integer number of most recent minor versions to load (default: all)
#     max_pages  = optional pages to scan via GitHub API (default: 5)
# Effect:
#   Sets AKS_LTS_MINOR_KEYS (ordered newest->oldest, truncated to N if provided)
#   Sets AKS_LTS_MAP_<major>_<minor> variables (dots replaced by _), each containing the two tags (space separated)
#   Prints the JSON (subset if N provided)
load_aks_lts_tags_into_shell() {
  local first_arg="$1"
  local limit=0
  if [[ "$first_arg" =~ ^[0-9]+$ ]]; then
    limit=$first_arg
    shift
  fi
  local max_pages=${1:-5}

  local full_json
  full_json=$(get_aks_lts_tags_json "$max_pages") || return 1

  # All keys in existing (already sorted) order
  # Extract keys from original JSON keeping their order by re-sorting descending (matches producer)
  mapfile -t all_keys < <(echo "$full_json" | jq -r 'keys[]' | sort -r -V)
  AKS_LTS_MINOR_KEYS=()

  if (( limit > 0 )) && (( limit < ${#all_keys[@]} )); then
    AKS_LTS_MINOR_KEYS=("${all_keys[@]:0:limit}")
  else
    AKS_LTS_MINOR_KEYS=("${all_keys[@]}")
  fi

  # Build subset JSON if limiting
  local json_out
  if (( limit > 0 )) && (( limit < ${#all_keys[@]} )); then
    json_out="{"
    local first=1
    for mm in "${AKS_LTS_MINOR_KEYS[@]}"; do
      # Build array JSON for this minor
      local arr_items
      mapfile -t arr_items < <(echo "$full_json" | jq -r --arg mm "$mm" '.[$mm][]')
      local arr_json=""
      local idx=0
      for t in "${arr_items[@]}"; do
        if (( idx > 0 )); then
          arr_json+=","
        fi
        arr_json+="\"$t\""
        idx=$((idx+1))
      done
      if (( first )); then
        json_out+=$'\n'
        first=0
      else
        json_out+=$',\n'
      fi
      json_out+="  \"$mm\": [$arr_json]"
    done
    json_out+=$'\n}'
  else
    json_out="$full_json"
  fi

  # Populate per-minor variables
  for mm in "${AKS_LTS_MINOR_KEYS[@]}"; do
    local var_name="AKS_LTS_MAP_${mm//./_}"
    read -r "$var_name" < <(echo "$full_json" | jq -r --arg mm "$mm" '.[$mm][]' | paste -sd' ' -)
  done

  echo "$json_out"
}
