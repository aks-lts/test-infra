# This script automates generation of LTS release changelog for an aks-lts fork of the kubernetes repository.
#
# High-level behavior:
#  - Accepts inputs (see usage() below) including --version-count, optional
#    --local-repo-path, optional --cve and --cve-pr lists, and --dry-run.
#  - If --local-repo-path is not provided, attempts to clone https://github.com/aks-lts/kubernetes.git into $HOME/aks-lts/kubernetes.
#  - Resolves the most recent N LTS minor versions (based on --version-count).
#  - For each minor version:
#      * Generate source archives for the current tag and computes SHA512 checksums.
#      * Generates list of pull requests between the two tags.
#      * Optionally generates CVE sections when CVE/PR mappings are provided.
#      * Builds a changelog Markdown snippet and inserts it into CHANGELOG/CHANGELOG-<minor>.md
#      * Updates the changelog TOC, commits to a new branch, and (unless --dry-run)
#        pushes the branch to the local repo's origin.
#
# Assumptions and requirements:
#  - The LTS tags we are creating the change logs are already published in the aks-lts/kubernetes repo.
#  - The repository layout follows kubernetes upstream (CHANGELOG/CHANGELOG-<minor>.md files).
#
# Safety:
#  - By default the script will create branches and push changes. Use --dry-run to
#    run without pushing.
#
# Example:
#  ./updateChangeLog.sh --version-count 3 --local-repo-path ~/src/my-org/kubernetes \
#    --cve CVE-2025-5187 --cve-pr 133470 --dry-run
#
# See the usage() function below for full option details.

#!/usr/bin/env bash


# parse args and usage
usage() {
  cat <<EOF
Usage: $0 --version-count <count> [--local-repo-path <path>] 

  --version-count     Number of most recent minor versions for we will create the changelog for (required)
  --local-repo-path   Local path to your fork of k/k repo (optional; will try to clone to home if omitted)
  --cve               CVE ID(s) to include in the changelog, separated by commas (optional)
  --cve-pr            K/K Pull request number(s) for the CVE(s), separated by commas, should match the order of CVEs (optional)
  --dry-run           Enable dry run mode, will not push the change to remote branch.

Example:
  $0 \
    --version-count 3 \
    --local-repo-path ~/src/my-org/kubernetes \
    --cve CVE-2025-5187 \
    --cve-pr 133470 \
    --dry-run 
EOF
  exit 2
}

# Initialize
GITHUB_ORG_NAME="aks-lts"
LOCAL_REPO_PATH=""
LOCAL_KK=""
TARGET_VERSION_COUNT=""
CVE_LIST=()
CVE_PR_LIST=()
DRY_RUN=false

# Parse long options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-repo-path)
      LOCAL_REPO_PATH="$2"
      shift 2
      ;;
    --version-count)
      TARGET_VERSION_COUNT="$2"
      shift 2
      ;;
    --cve)
      IFS=',' read -r -a CVE_LIST <<< "$2"
      shift 2
      ;;
    --cve-pr)
      IFS=',' read -r -a CVE_PR_LIST <<< "$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift 1
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Basic validation
if [[ -z "$TARGET_VERSION_COUNT" ]]; then
  echo "Error: missing required argument(s)."
  usage
fi

# If local repo path not provided, try clone to home
if [[ -z "$LOCAL_REPO_PATH" ]]; then
    TARGET="$HOME/${GITHUB_ORG_NAME}/kubernetes"
    echo "Local repo for '${LOCAL_REPO_PATH}' not found. Attempting to clone to '${TARGET}'..."
    mkdir -p "$(dirname "$TARGET")"
    if git clone "https://github.com/${GITHUB_ORG_NAME}/kubernetes.git" "$TARGET"; then
        LOCAL_REPO_PATH="$TARGET"
        echo "Cloned repository to '${LOCAL_REPO_PATH}'."
    else
        echo "Warning: failed to clone https://github.com/${GITHUB_ORG_NAME}/kubernetes.git"
    fi
fi

if [[ -z "$LOCAL_REPO_PATH" ]]; then
  echo "Error: could not find local repo '${LOCAL_REPO_PATH}'. Please provide --local-repo-path."
  usage
fi

# Create a CVE-PR mapping
declare -A CVE_PR_MAP
for i in "${!CVE_LIST[@]}"; do
  cve_id="${CVE_LIST[$i]}"
  pr_num="${CVE_PR_LIST[$i]:-}"
  # Basic validation of CVE pattern; warn if malformed (e.g. user typo VE-...)
  if [[ -n "$cve_id" && ! "$cve_id" =~ ^CVE-[0-9]{4}-[0-9]{4,}$ ]]; then
    echo "Warning: CVE id '$cve_id' does not match expected pattern CVE-YYYY-NNNN+ (will still attempt)."
  fi
  CVE_PR_MAP["$cve_id"]="$pr_num"
done
# Print mapping preserving input order so user can verify alignment
if [[ ${#CVE_LIST[@]} -gt 0 ]]; then
  echo "CVE PR MAP:"
  for i in "${!CVE_LIST[@]}"; do
    cve_id="${CVE_LIST[$i]}"
    pr_num="${CVE_PR_MAP[$cve_id]}"
    if [[ -n "$pr_num" ]]; then
      printf '  %s -> #%s\n' "$cve_id" "$pr_num"
    else
      printf '  %s -> (none)\n' "$cve_id"
    fi
  done
fi

# Setup Temporary directory
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP_DIR="$SCRIPT_DIR/../tmp"
mkdir -p "$TMP_DIR"

# Resolve absolute path for local k/k
if ! LOCAL_KK_ABS=$(cd "${LOCAL_REPO_PATH}" >/dev/null 2>&1 && pwd); then
  echo "Error: local k/k path '${LOCAL_REPO_PATH}' does not exist or is not accessible."
  exit 1
fi
LOCAL_KK="${LOCAL_KK_ABS}"

TOC_END_MARKER='<!-- END MUNGE: GENERATED_TOC -->'
CHANGELOG_TMP=$(cat <<'EOF'
# v${CURRENT_VERSION}

## Downloads for v${CURRENT_VERSION}
### Source Code
${SOURCE_TABLE}

## Changelog since v${PREVIOUS_VERSION}

## Important Security Information

This release contains changes that address the following vulnerabilities:

${CVE_SECTIONS}

## Changes by Kind
### Bug or Regression

${PR_LIST}

EOF
)

# Load helpers
source "${SCRIPT_DIR}/tag_utils.sh"
source "${SCRIPT_DIR}/cve_utils.sh"
source "${SCRIPT_DIR}/pr_utils.sh"
source "${SCRIPT_DIR}/toc_utils.sh"
TS=$(date +%Y%m%d%H%M) # timestamp for branch name

#
# cd to local-kk
#
cd "${LOCAL_KK}" || { echo "Failed to cd to '${LOCAL_KK}'"; exit 1; }
# check if "git remote show https://github.com/${GITHUB_ORG_NAME}/kubernetes.git" output contains "not found"
if ! git remote show https://github.com/${GITHUB_ORG_NAME}/kubernetes.git | grep -q "not found"; then
  echo "Add remote connection for repo https://github.com/${GITHUB_ORG_NAME}/kubernetes.git"
  git remote add ${GITHUB_ORG_NAME} https://github.com/${GITHUB_ORG_NAME}/kubernetes.git
fi
git remote -v
git fetch -v --all

#
# Get LTS Versions and most recent 2 tags
#
AKS_LTS_TAG_MAP=$(load_aks_lts_tags_into_shell $TARGET_VERSION_COUNT)
echo ""
echo "AKS LTS tag map: ${AKS_LTS_TAG_MAP}"

#
# Retrieve CVE Info
#
echo ""
latestMinorVersion=$(echo "$AKS_LTS_TAG_MAP" | jq -r "keys[$TARGET_VERSION_COUNT-1]")
if [[ ${#CVE_PR_MAP[@]} -gt 0 ]]; then
  CVE_SECTIONS=$(get_cve_sections "$latestMinorVersion" "$TMP_DIR" CVE_PR_MAP)
else
  CVE_SECTIONS=""
fi

#   
# Update Change Log each Minor Version
#
for minorVer in $(echo "${AKS_LTS_TAG_MAP}" | jq -r 'keys[]'); do
  mapfile -t tags < <(echo "${AKS_LTS_TAG_MAP}" | jq -r ".\"${minorVer}\"[]")
  if [[ ${#tags[@]} -lt 2 ]]; then
    echo "Warning: expected at least 2 tags for ${minorVer}, got ${#tags[@]}: ${tags[*]}"
    continue
  fi
  CURRENT_VERSION=${tags[0]}
  PREVIOUS_VERSION=${tags[1]}
  echo ""
  echo "Processing Release: ${minorVer} with Current: ${CURRENT_VERSION}, Previous: ${PREVIOUS_VERSION}"
  CHANGELOG_FINAL="$CHANGELOG_TMP"

  #
  # Update Source Code section in ChangeLog
  #

  ZIP_URL="https://github.com/${GITHUB_ORG_NAME}/kubernetes/archive/refs/tags/v${CURRENT_VERSION}.zip"
  TAR_URL="https://github.com/${GITHUB_ORG_NAME}/kubernetes/archive/refs/tags/v${CURRENT_VERSION}.tar.gz"
  TAR_FILE="$TMP_DIR/kubernetes-${CURRENT_VERSION}.tar.gz"
  ZIP_FILE="$TMP_DIR/kubernetes-${CURRENT_VERSION}.zip"
  
  if [[ -f "$TAR_FILE" && -f "$ZIP_FILE" ]]; then
    echo "  Source archives for ${CURRENT_VERSION} already exist; skipping download."
  else 
    echo "  Downloading source archives for ${CURRENT_VERSION}..."
    if ! curl -fLSs -o "$TAR_FILE" "$TAR_URL"; then
        echo "Error: failed to download ${TAR_URL}" >&2
        exit 1
    fi
    if ! curl -fLSs -o "$ZIP_FILE" "$ZIP_URL"; then
      echo "Error: failed to download ${ZIP_URL}" >&2
      exit 1
    fi
  fi

  # Compute SHA512 checksums
  if command -v sha512sum >/dev/null 2>&1; then
    TAR_SHA512=$(sha512sum "$TAR_FILE" | awk '{print $1}')
    ZIP_SHA512=$(sha512sum "$ZIP_FILE" | awk '{print $1}')
  else
    TAR_SHA512=$(shasum -a 512 "$TAR_FILE" | awk '{print $1}')
    ZIP_SHA512=$(shasum -a 512 "$ZIP_FILE" | awk '{print $1}')
  fi

  # Build Source Code table (no leading indentation)
  SOURCE_TABLE=$(cat <<EOF
filename | sha512 hash
-------- | -----------
[kubernetes.tar.gz](${TAR_URL}) | ${TAR_SHA512}
[kubernetes.zip](${ZIP_URL}) | ${ZIP_SHA512}
EOF
  )

  #
  # Generate PR List
  #
  
  git checkout "release-${minorVer}-lts" >/dev/null
  git pull --ff-only >/dev/null
  PR_LIST=$(generate_pr_list_md "$LOCAL_KK" "v${CURRENT_VERSION}" "v${PREVIOUS_VERSION}")
  [[ -z "$PR_LIST" ]] && PR_LIST="(No PRs in this range)"

  # Update CHANGELOG sections
  CHANGELOG_FINAL="${CHANGELOG_FINAL//\$\{CURRENT_VERSION\}/$CURRENT_VERSION}"
  CHANGELOG_FINAL="${CHANGELOG_FINAL//\$\{PREVIOUS_VERSION\}/$PREVIOUS_VERSION}"
  CHANGELOG_FINAL="${CHANGELOG_FINAL//\$\{SOURCE_TABLE\}/$SOURCE_TABLE}"
  CHANGELOG_FINAL="${CHANGELOG_FINAL//\$\{CVE_SECTIONS\}/$CVE_SECTIONS}"
  CHANGELOG_FINAL="${CHANGELOG_FINAL//\$\{PR_LIST\}/$PR_LIST}"


  BRANCH_NAME="release-${CURRENT_VERSION}-lts-changelog-${TS}"
  git checkout -b "$BRANCH_NAME" >/dev/null || {
    echo "Failed to create branch $BRANCH_NAME" >&2; exit 1; }

  # Insert generated section into upstream CHANGELOG file after marker
  
  CHANGELOG_FILE="${LOCAL_KK}/CHANGELOG/CHANGELOG-${minorVer}.md"
  if [[ ! -f "$CHANGELOG_FILE" ]]; then
    echo "Warning: $CHANGELOG_FILE not found; skipping file insertion for ${minorVer}." >&2
    continue
  fi
  TMP_OUT="${TMP_DIR}/CHANGELOG-${minorVer}.md.inserting"
  if grep -q "$TOC_END_MARKER" "$CHANGELOG_FILE"; then
    awk -v insert="$CHANGELOG_FINAL" -v marker="$TOC_END_MARKER" '
      BEGIN{done=0}
      index($0, marker)>0 && !done {
        print $0; print ""; print insert; print ""; done=1; next
      }
      { print }
      END { if(!done){ print ""; print insert } }
    ' "$CHANGELOG_FILE" > "$TMP_OUT"
  else
    printf '%s\n\n%s\n' "$(cat "$CHANGELOG_FILE")" "$CHANGELOG_FINAL" > "$TMP_OUT"
  fi
  mv "$TMP_OUT" "$CHANGELOG_FILE"
  echo "Updated ${CHANGELOG_FILE} with new section for v${CURRENT_VERSION}."

  update_changelog_toc "$CHANGELOG_FILE"

  git add "$CHANGELOG_FILE" >/dev/null
  git commit -m "CHANGELOG: Update directory for v${CURRENT_VERSION} release" || echo "No changes to commit for ${minorVer}."
  echo "Changelog changes staged on branch $BRANCH_NAME"

  if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run mode enabled, will not push the branch to the remote repo.
  else
    git push origin "$BRANCH_NAME"
  fi

done
