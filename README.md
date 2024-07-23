# test-infra
LTS specific configuration and tooling for testing

# workflows

* deploy-lts-prow.yaml
  * Automates https://docs.prow.k8s.io/docs/getting-started-deploy to set up or update the AKS LTS instance of Prow
  * Requires an Azure subscription with
    - an existing resource group, e.g. `aks-lts-prow`, use for `AZURE_RG` below
    - a service principal (run `az ad sp create-for-rbac --role Contributor --sdk-auth --scope /subscriptions/$AZURE_SUBSCRIPTION/resourceGroups/$AZURE_RG` and use output for `AZURE_CREDENTIALS` below)
    - registration of the Microsoft.Cdn resource provider (run `az provider register --namespace Microsoft.Cdn`)
  * Requires variables:
    - `APP_ID`  (GitHub AppId, e.g. `12345`- see [GitHub App](https://docs.prow.k8s.io/docs/getting-started-deploy/#github-app))
    - `ORG` (GitHub org, e.g. `aks-lts`)
    - `REPO` (GitHub repo, e.g. `kubernetes`)
    - `AZURE_SUBSCRIPTION` (Azure subscription associated with Azure credentials below)
    - `AZURE_RG` (Existing Azure resource group to use for deployment, e.g. `aks-lts-prow`)
  * Required secrets:
    - `AZURE_CREDENTIALS` (output of `az ad sp create-for-rbac --role Contributor --sdk-auth --scope /subscriptions/$AZURE_SUBSCRIPTION/resourceGroups/$AZURE_RG`)
    - `APP_PRIVATE_KEY` (private key for GitHub App- see [GitHub App](https://docs.prow.k8s.io/docs/getting-started-deploy/#github-app); make sure to use the private key and not the client secret)
    - `HMAC_TOKEN` (generate randomly via `openssl rand -hex 20` and also set in GitHub App, see [Create the GitHub secrets](https://docs.prow.k8s.io/docs/getting-started-deploy/#create-the-github-secrets))
  * Prow jobs for each K8S release need to be added manually:
    - For an example, see https://github.com/aks-lts/test-infra/pull/9
    - Create a new config file `config/prow/release-branch-jobs/<version>.yaml`
    - Add a new line to the `Create job configs step` in `.github/workflows/deploy-lts-prow.yaml` 
      (follow the existing pattern, i.e. `envsubst < config/prow/release-branch-jobs/<version>.yaml >> cm.yaml`)
    - Go to the [kubernetes/test-infra](https://github.com/kubernetes/test-infra) repo and find the config file they use
      for that version under [config/jobs/kubernetes/sig-release/release-branch-jobs](https://github.com/kubernetes/test-infra/tree/master/config/jobs/kubernetes/sig-release/release-branch-jobs). 
      It might have been deleted already (when that version went out of support), so inspect the history of that folder and find the last version right before deletion.
    - Copy only the `presubmits:` section of that file to the new config file you created (`config/prow/release-branch-jobs/<version>.yaml`)
    - Remove all tests for a repo other than `kubernetes/kubernetes`, for example `kubernetes/perf-tests`
    - Replace `kubernetes/kubernetes` with `$GITHUB_ORG/$GITHUB_REPO`
    - Remove all the `cluster: ...` rows (`sed -i '' '/cluster: /d' <version>.yaml`)
    - Remove all tests with `--provider=gce`
    - In the `branches:` sections of the remaining jobs, make sure they contain the name of the LTS branch you want tests to run on (typically `release-<version>-lts`)
    - Push these changes to a branch and run the [Deploy AKS LTS Prow](https://github.com/aks-lts/test-infra/actions/workflows/deploy-lts-prow.yaml) workflow
      for that branch (click "Run workflow" and select your branch). Make sure it succeeds.
    - Create a test PR on the [aks-lts/kubernetes](https://github.com/aks-lts/kubernetes) repo. Make sure it targets the desired branch (`release-<version>-lts`).
      Check if the tests run and succeed.
    - If tests don't run or fail, check https://aka.ms/aks/prow. Some of them might need additional tweaking, e.g. request less CPU/memory 
    - Once all is looking good, remember to merge the PR on this repo.

# Updating image tags
## PROW (K8S_PROW_IMAGE_TAG)
Image repo: https://console.cloud.google.com/gcr/images/k8s-prow

Reference the version used in upstream by looking up [gcr.io/k8s-prow/prow-controller-manager](https://github.com/search?q=repo%3Akubernetes%2Ftest-infra+gcr.io%2Fk8s-prow%2Fprow-controller-manager&type=code) or [gcr.io/k8s-prow/entrypoint](https://github.com/search?q=repo%3Akubernetes%2Ftest-infra+gcr.io%2Fk8s-prow%2Fentrypoint&type=code) verions.

## KUBEKINS-E2E (KUBEKINS_E2E_TAG)
Reference the version used in upstraem by looking up [kubekins-e2e:](https://github.com/search?q=repo%3Akubernetes%2Ftest-infra+kubekins-e2e%3A&type=code&p=2)