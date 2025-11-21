#!/usr/bin/env bash

# generate_pr_list_md <repo_path> <current_tag> <previous_tag>
# Output: markdown bullet list of PRs between previous_tag (exclusive) and current_tag (inclusive)
# Format per line: - PR_TITLE ([#PR_NUMBER](PR_LINK))
# Notes:
#  - Attempts to extract PR numbers from commit subjects in the given range.
#  - Supports squash merge subjects '(#12345)', merge commits 'Merge pull request #12345', and generic '#12345'.
#  - De-duplicates PR numbers preserving first-seen order.
#  - If GITHUB_TOKEN is present, fetches canonical title from GitHub API; else derives from commit subject.

generate_pr_list_md() {
  local repo_path="$1" current_tag="$2" previous_tag="$3"
  if [[ -z "$repo_path" || -z "$current_tag" || -z "$previous_tag" ]]; then
    echo ""; return 0
  fi
  if [[ ! -d "$repo_path/.git" ]]; then
    echo ""; return 0
  fi

  local org="${GITHUB_ORG_NAME:-aks-lts}" repo_name="kubernetes" range="${previous_tag}..${current_tag}"

  # Use --reverse to list commits oldest -> newest so output PR list follows chronological order
  mapfile -t _subjects < <(git -C "$repo_path" log --reverse --pretty=format:'%s' "$range" 2>/dev/null | grep -E '#[0-9]+' || true)
  if [[ ${#_subjects[@]} -eq 0 ]]; then
    echo ""; return 0
  fi

  declare -A _seen
  local pr_numbers=()
  local s pr
  for s in "${_subjects[@]}"; do
    # Only treat as merged PR (no token fallback) if it's an explicit merge commit or a squash merge marker '(#123)'
    if [[ $s =~ Merge[[:space:]]pull[[:space:]]request[[:space:]]#([0-9]+) ]]; then
      pr="${BASH_REMATCH[1]}"
    elif [[ $s =~ \(#([0-9]+)\) ]]; then
      pr="${BASH_REMATCH[1]}"
    else
      pr=""
    fi
    [[ -z $pr ]] && continue
    if [[ -z "${_seen[$pr]}" ]]; then
      _seen[$pr]=1
      pr_numbers+=("$pr")
    fi
  done

  if [[ ${#pr_numbers[@]} -eq 0 ]]; then
    echo ""; return 0
  fi

  local have_token=0
  [[ -n "$GITHUB_TOKEN" ]] && have_token=1
  local md_lines=() pr title api_url pr_json
  for pr in "${pr_numbers[@]}"; do
    title=""
    if (( have_token )); then
      api_url="https://api.github.com/repos/${org}/${repo_name}/pulls/${pr}"
      pr_json=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" "$api_url")
      merged_at=$(echo "$pr_json" | jq -r '.merged_at // empty')
      [[ -z $merged_at ]] && continue  # skip unmerged PRs
      title=$(echo "$pr_json" | jq -r '.title // empty')
    fi
    if [[ -z $title ]]; then
      for s in "${_subjects[@]}"; do
        if [[ $s =~ \(#${pr}\) ]] || [[ $s =~ pull[[:space:]]request[[:space:]]#${pr} ]]; then
          title="$s"
          title=${title//Merge pull request #${pr}/}
          title=$(echo "$title" | sed -E "s/\s*\(#${pr}\)//; s/#${pr}//; s/from [^ ]+//; s/^[-: ]+//; s/[[:space:]]+$//")
          break
        fi
      done
      [[ -z $title ]] && title="PR ${pr}"
    fi
    # Skip titles starting with CHANGELOG (case-insensitive)
    if [[ "${title,,}" =~ ^[[:space:]]*changelog ]]; then
      continue
    fi
    md_lines+=("- ${title} ([#${pr}](https://github.com/${org}/${repo_name}/pull/${pr}))")
  done

  printf '%s\n' "${md_lines[@]}"
}
