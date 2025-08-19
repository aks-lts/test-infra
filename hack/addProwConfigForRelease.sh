# the bash script to take in version number and URL to the upstream config file
# and generate the new Prow config file for the LTS release branch jobs

#!/usr/bin/env bash

# Add a samepl usage if we don't have enought input param
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <version> <upstream_config_url>"
    echo "Example:"
    echo "$0 1.30 https://raw.githubusercontent.com/kubernetes/test-infra/master/config/jobs/kubernetes/sig-release/release-branch-jobs/1.30.yaml"
    exit 1
fi

set -euo pipefail

VERSION=$1
UPSTREAM_CONFIG_URL=$2

# Ensure that we are in the root directory of the repository
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Add a new line to the `Create job configs step` in `.github/workflows/deploy-lts-prow.yaml` 
# (follow the existing pattern, i.e. `envsubst < config/prow/release-branch-jobs/<version>.yaml >> cm.yaml`)
echo "Updating deploy-lts-prow.yaml for version ${VERSION}..."
WORKFLOW_FILE=".github/workflows/deploy-lts-prow.yaml"
NEW_LINE="          envsubst < config/prow/release-branch-jobs/${VERSION}.yaml >> cm.yaml"

# Check if the file exists
if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "Error: Workflow file $WORKFLOW_FILE not found"
    exit 1
fi
# Check if the line already exists
if grep -q "config/prow/release-branch-jobs/${VERSION}.yaml" "$WORKFLOW_FILE"; then
    echo "✅ Job config step for version ${VERSION} already exists in $WORKFLOW_FILE"
else 
    # Find the line number of the last envsubst command in the 'Create job configs' section
    LAST_ENVSUBST_LINE=$(grep -n "envsubst < config/prow/release-branch-jobs/.*\.yaml >> cm.yaml" "$WORKFLOW_FILE" | tail -1 | cut -d: -f1)

    if [ -z "$LAST_ENVSUBST_LINE" ]; then
        echo "Error: Could not find existing envsubst lines in $WORKFLOW_FILE"
        exit 1
    fi

    # Insert the new line after the last envsubst line
    sed -i "${LAST_ENVSUBST_LINE}a\\${NEW_LINE}" "$WORKFLOW_FILE"

    echo "✅ Added line for version ${VERSION} to $WORKFLOW_FILE"
    echo "   Line added: $NEW_LINE"

    # Show the context of what was added
    echo ""
    echo "Updated section:"
    grep -A 2 -B 2 "config/prow/release-branch-jobs/${VERSION}.yaml" "$WORKFLOW_FILE"
fi

echo ""

# Create the new config file
NEW_CONFIG_FILE="config/prow/release-branch-jobs/${VERSION}.yaml"
touch "${NEW_CONFIG_FILE}"
echo "Add PROW config file ${NEW_CONFIG_FILE}..."

# Fetch the upstream config file
echo "Processing upstream config file: ${UPSTREAM_CONFIG_URL}..."
TMP_UPSTREAM_CONFIG_FILE="tmp/${VERSION}.yaml"
mkdir -p "$(dirname "${TMP_UPSTREAM_CONFIG_FILE}")"
curl -s "${UPSTREAM_CONFIG_URL}" -o "${TMP_UPSTREAM_CONFIG_FILE}"

# Run python code to process the new config file using raw text so we preserve original formatting
python3 - <<PYEOF
import re, sys, os
version = "${VERSION}"
raw_path = "${UPSTREAM_CONFIG_URL}"
in_file = "${TMP_UPSTREAM_CONFIG_FILE}"
out_file = "${NEW_CONFIG_FILE}"

with open(in_file,'r') as f:
    lines = f.readlines()

# Locate presubmits -> kubernetes/kubernetes section
presubmits_start = None
kk_start = None
for i,l in enumerate(lines):
    if presubmits_start is None and re.match(r'^\s*presubmits:\s*$', l):
        presubmits_start = i
    if presubmits_start is not None and kk_start is None and re.match(r'^\s*kubernetes/kubernetes:\s*$', l):
        kk_start = i
        break

if kk_start is None:
    print('ERROR: Could not find presubmits.kubernetes/kubernetes in upstream config', file=sys.stderr)
    sys.exit(1)

# Collect block lines until another repo key at same indent or end of file
block_lines = []
base_indent_match = re.match(r'^(\s*)kubernetes/kubernetes:', lines[kk_start])
base_indent = base_indent_match.group(1) if base_indent_match else '  '
for l in lines[kk_start+1:]:
    if re.match(r'^%s[^\s-][^:]*:' % base_indent, l) and not l.lstrip().startswith('- '):
        # another repo key at same level
        break
    block_lines.append(l)

# Split jobs: jobs start with base_indent + '-'
jobs = []
current = []
for l in block_lines:
    if re.match(r'^%s\s' % re.escape(base_indent + '-'), l):  # handle '- ' immediately after base indent
        if current:
            jobs.append(current)
            current = []
    elif re.match(r'^%s-' % re.escape(base_indent), l):
        if current:
            jobs.append(current)
            current = []
    if re.match(r'^%s-' % re.escape(base_indent), l):
        current.append(l)
    else:
        if current:
            current.append(l)
if current:
    jobs.append(current)

kept = []
name_re = re.compile(r'^\s*-\s*name:\s*(\S+)')
for job in jobs:
    text = ''.join(job)
    m = name_re.search(job[0]) or any(name_re.search(x) for x in job)
    # Extract job name if present
    job_name = None
    for ln in job:
        nm = re.match(r'^\s*name:\s*(\S+)', ln)
        if nm:
            job_name = nm.group(1)
            break
    # Filtering rules
    if job_name and ('gce' in job_name or 'ec2' in job_name):
        print(f'SKIP name contains gce/ec2: {job_name}')
        continue
    if re.search(r'--provider=gce', text) or re.search(r'gcp-zone=', text):
        print(f'SKIP provider gcp-zone in {job_name}')
        continue
    if re.search(r'preset-e2e-containerd-ec2', text):
        print(f'SKIP preset-e2e-containerd-ec2 in {job_name}')
        continue
    # Remove cluster: lines
    filtered_job = [ln for ln in job if not re.search(r'^\s*cluster:\s', ln)]
    # Replace release-<version> with -lts if not already suffixed
    repl_pattern = re.compile(rf'release-{re.escape(version)}(?!-lts)')
    filtered_job = [repl_pattern.sub(f'release-{version}-lts', ln) for ln in filtered_job]
    kept.append(filtered_job)
    print(f'SAVE job {job_name}')

print(f'Total upstream jobs collected: {len(jobs)}')
print(f'Keeping: {len(kept)}')

if len(kept) < 13:
    print('WARNING: fewer than 13 jobs after filtering (README expectation).', file=sys.stderr)

# Write output preserving original per-line formatting, just add two-space indent to each line
with open(out_file,'w') as out:
    # header
    if raw_path.startswith('https://raw.githubusercontent.com/kubernetes/test-infra/'):
        github_url = raw_path.replace('https://raw.githubusercontent.com/kubernetes/test-infra/', 'https://github.com/kubernetes/test-infra/blob/', 1)
    else:
        github_url = raw_path  # fallback
    out.write(f'# {version}-lts jobs, do not change indentation of the lines below, it need to be aligned with base.yaml\n')
    out.write(f'# Based on {github_url}\n')
    for job in kept:
        for ln in job:
            if not ln.strip():
                out.write('\n')
                continue
            # Remove the original base indentation so we only end up with exactly two leading spaces
            if ln.startswith(base_indent):
                norm = ln[len(base_indent):]
            else:
                # fallback: strip leading spaces to avoid cascading indentation growth
                norm = ln.lstrip()
            out.write('  ' + norm.rstrip() + '\n')

print(f'✅ PROW config saved to: {out_file}')
PYEOF

# (Optional) Leave temp file for troubleshooting; uncomment to remove
rm -f "${TMP_UPSTREAM_CONFIG_FILE}"