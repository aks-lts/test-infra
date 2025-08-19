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

# Run python code to process the new config file
python3 -c "
import ruamel.yaml # can be installed with pip install ruamel.yaml
from io import StringIO
import sys
import re

yaml = ruamel.yaml.YAML()
yaml.preserve_quotes = True
yaml.default_flow_style = False

# Read the YAML file
with open('${TMP_UPSTREAM_CONFIG_FILE}', 'r') as f:
    content = f.read()

# Parse the yaml
data = yaml.load(content)

# Get a list of relevant jobs
if 'presubmits' in data and 'kubernetes/kubernetes' in data['presubmits']:
    jobs = data['presubmits']['kubernetes/kubernetes']
    print(f'Total presubmits.kubernetes/kubernetes jobs: {len(jobs)}')
    
    kept_jobs_list = []
    for job in jobs:
        
        # If job name has 'gce' or 'ec2', skip it
        if 'name' in job:
            if 'gce' in job['name'] or 'ec2' in job['name']:
                jobName = job['name']
                print(f'  Skip: {jobName}')
                continue
        
        # Remove cluster field if it exists
        if 'cluster' in job:
            del job['cluster']
        
        # Update branches to release-<version>-lts format
        if 'branches' in job:
            job['branches'] = [f'release-${VERSION}-lts']
        
        kept_jobs_list.append(job)
        print(f'Keep: {job[\"name\"]}')
    
    # Write the filtered data back to the YAML file
    
    with open('${NEW_CONFIG_FILE}', 'w') as f:

        # Extract the config path from the URL
        url_path_match = re.search(r'(config/jobs/kubernetes/sig-release/release-branch-jobs/[^/]+\.yaml)', '${UPSTREAM_CONFIG_URL}')
        config_path = url_path_match.group(1) if url_path_match else '$(basename \"${UPSTREAM_CONFIG_URL}\")'
        
        # Write the header comment
        f.write('# ${VERSION}-lts jobs, do not change indentation of the lines below, it need to be aligned with base.yaml\\n')
        f.write(f'# Based on {config_path}\\n')
        
        # Dump the YAML content
        stream = StringIO()
        yaml.dump(kept_jobs_list, stream)
        yaml_content = stream.getvalue()
        
        # Add two spaces before each line of YAML content to align with base.yaml
        indented_yaml = '\\n'.join('  ' + line if line.strip() else line for line in yaml_content.split('\\n'))
        f.write(indented_yaml)
    
    print(f'Final Job Count: {len(kept_jobs_list)}')
    print(f'✅ PROW config saved to: ${NEW_CONFIG_FILE}')
"
# clean up
rm -rf "$(dirname "${TMP_UPSTREAM_CONFIG_FILE}")"