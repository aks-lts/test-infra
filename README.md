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
    - `APP_PRIVATE_KEY` (private key for GitHub App- see [GitHub App](https://docs.prow.k8s.io/docs/getting-started-deploy/#github-app))
    - `HMAC_TOKEN` (generate randomly via `openssl rand -hex 20` and also set in GitHub App, see [Create the GitHub secrets](https://docs.prow.k8s.io/docs/getting-started-deploy/#create-the-github-secrets))
