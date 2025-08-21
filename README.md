# test-infra
LTS specific configuration and tooling for testing

# workflows

## Deployt LTS PROW to Azure
* deploy-lts-prow.yaml
  * Automates https://docs.prow.k8s.io/docs/getting-started-deploy to set up or update the AKS LTS instance of Prow
  * Requires an Azure subscription with
    - an existing resource group, e.g. `aks-lts-prow`, use for `AZURE_RG` below
    - a service principal (run `az ad sp create-for-rbac --role Contributor --sdk-auth --scope /subscriptions/$AZURE_SUBSCRIPTION/resourceGroups/$AZURE_RG` and use output for `AZURE_CREDENTIALS` below)
    - registration of the Microsoft.Cdn resource provider (run `az provider register --namespace Microsoft.Cdn`)
  * Requires variables:
    - `APP_ID`: App ID of the PROW GitHub App, e.g. `12345`- see [GitHub App](https://docs.prow.k8s.io/docs/getting-started-deploy/#github-app)
    - `CLIENT_ID`: Client ID of the PROW GitHub App.
    - `ORG`: GitHub org, e.g. `aks-lts`
    - `REPO`: GitHub repo, e.g. `kubernetes`
    - `AZURE_SUBSCRIPTION`: Azure subscription associated with Azure credentials below
    - `AZURE_RG`: Existing Azure resource group to use for deployment, e.g. `aks-lts-prow`
  * Required secrets:
    - `AZURE_CREDENTIALS`: Output of `az ad sp create-for-rbac --role Contributor --sdk-auth --scope /subscriptions/$AZURE_SUBSCRIPTION/resourceGroups/$AZURE_RG`
    - `APP_CLIENT_SECRET`: Client secrets of the PROW GitHub App
    - `APP_PRIVATE_KEY`: Private key for the PROW GitHub App. see [GitHub App](https://docs.prow.k8s.io/docs/getting-started-deploy/#github-app). It is the private key (at the bottom of the GITHUB App settings) and NOT the client secret.
    - `HMAC_TOKEN`: Generate randomly via `openssl rand -hex 20` and also set in GitHub App. See [Create the GitHub secrets](https://docs.prow.k8s.io/docs/getting-started-deploy/#create-the-github-secrets) for details.
    - `APP_COOKIE`: Generate randomly via `openssl rand -base64 32`. See [How to setup GitHub Oauth](https://docs.prow.k8s.io/docs/components/core/deck/github-oauth-setup/#set-up-secrets) for details.
# Add PROW Job Config for Each LTS Release
  The PROW config for release is based on [kubernetes/test-infra](https://github.com/kubernetes/test-infra) repo. Please refer to https://github.com/aks-lts/test-infra/pull/42 for PR sample.

  The PROW config files for all release are under [config/jobs/kubernetes/sig-release/release-branch-jobs](https://github.com/kubernetes/test-infra/tree/master/config/jobs/kubernetes/sig-release/release-branch-jobs). If the file of the target release is not found, it might have been deleted already (when that version went out of support), so inspect the commit history of that folder and find the last version right before deletion.

## Add New PROW Config (AUTOMATED)
  1. Find the URL of of the upstream config (ex: https://github.com/kubernetes/test-infra/blob/master/config/jobs/kubernetes/sig-release/release-branch-jobs/1.30.yaml).
  1. Get the URL of the RAW version of upstream config (ex: https://raw.githubusercontent.com/kubernetes/test-infra/refs/heads/master/config/jobs/kubernetes/sig-release/release-branch-jobs/1.30.yaml). Note the host name is `raw.githubusercontent.com` instead of `github.com`
  1. Run the script to generate the new PROW config
      ```
      ./hack/addProwConfigForRelease.sh {version} {URL to RAW upstream config}
      ```
      in case of 1.30:
      ```
      ./hack/addProwConfigForRelease.sh 1.30 https://raw.githubusercontent.com/kubernetes/test-infra/refs/heads/master/config/jobs/kubernetes/sig-release/release-branch-jobs/1.30.yaml
      ```
  1. The script should update `.github/workflows/deploy-lts-prow.yaml` and generate a new file: `config/prow/release-branch-jobs/<version>.yaml`.
     Sanity check the generated content with the MANUAL section.
     `config/prow/release-branch-jobs/<version>.yaml` should have at least 13 jobs.

## Add New PROW Config (MANUAL)

  1. Add a new line to the `Create job configs step` in `.github/workflows/deploy-lts-prow.yaml` 
    (follow the existing pattern, i.e. `envsubst < config/prow/release-branch-jobs/<version>.yaml >> cm.yaml`)
  1. Create a new config file `config/prow/release-branch-jobs/<version>.yaml`.
  1. Copy the content of the upstream config file to the new config file `config/prow/release-branch-jobs/<version>.yaml`.
  1. Apply the following changes to the new config file:
      - Remove everything that are not under the `presubmits:` section the config file.
      - Remove all test jobs that are not under than `kubernetes/kubernetes`. For example, remove all tests under `kubernetes/perf-tests`.
      - Remove all test jobs with `--provider=gce` or `--gcp-zone=` under the `spec.containers.args`.
      - Remove all test jobs with `preset-e2e-containerd-ec2` label
      - Remove all rows with the `cluster: ...` (`sed -i '' '/cluster: /d' <version>.yaml`),
      - Replece all mentions of `release-<version>` to `release-<version>-lts` (i.e. the name of the LTS branch you want tests to run on), includeing the `branches:` sections of the jobs.
  1. Ensure that formatting and styling matches with the YAML file of previous release branch jobs.
  1. Jobs 'pull-kubernetes-linter-hints'and 'pull-kubernetes-verify' require at least 16G. If their memory is less than 16G, update them.

## Test New PROW Config 

1. Push the changes to a new branch and run the [Deploy AKS LTS Prow](https://github.com/aks-lts/test-infra/actions/workflows/deploy-lts-prow.yaml) workflow
      for that branch (click "Run workflow" and select your branch). Make sure it succeeds.
1. Create a test PR on the [aks-lts/kubernetes](https://github.com/aks-lts/kubernetes) repo. Make sure it targets the desired branch (`release-<version>-lts`). Check if the tests run and succeed.
1. If tests don't run or fail, check https://aka.ms/aks/prow. Some of them might need additional tweaking, e.g. request less CPU/memory 
1. Once all is looking good, remember to merge the PR on this repo.

# Updating image tags
## PROW (K8S_PROW_IMAGE_TAG)
Image repo: https://console.cloud.google.com/gcr/images/k8s-prow

Reference the version used in upstream by looking up [gcr.io/k8s-prow/prow-controller-manager](https://github.com/search?q=repo%3Akubernetes%2Ftest-infra+gcr.io%2Fk8s-prow%2Fprow-controller-manager&type=code) or [gcr.io/k8s-prow/entrypoint](https://github.com/search?q=repo%3Akubernetes%2Ftest-infra+gcr.io%2Fk8s-prow%2Fentrypoint&type=code) verions.