# test-infra
LTS specific configuration and tooling for testing

# workflows

* deploy-lts-prow.yaml
  * Automates https://docs.prow.k8s.io/docs/getting-started-deploy to set up AKS LTS instance of Prow
  * Requires variables:
    - `APP_ID`  (GitHub AppId)
    - `ORG` (GitHub org, e.g. `aks-lts`)
    - `REPO` (GitHub repo, e.g. `kubernetes`)
    - `AZURE_SUBSCRIPTION` (Azure subscription associated with Azure credentials below)
    - `AZURE_RG` (Existing Azure resource group to use for deployment, e.g. `aks-lts-prow`)
  * Required secrets:
    - `AZURE_CREDENTIALS` (output of `az ad sp create-for-rbac --role Contributor --sdk-auth`)
    - `TOKEN` (from GitHub)
    - `HMAC_TOKEN` (generate )
    - `FAKE_MOUNT_SECRET` (set to commonly used fake secret - TODO generate this)
