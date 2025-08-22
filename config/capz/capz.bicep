@minLength(3)
param resource_prefix string = 'capz'
param location string = resourceGroup().location

var random_suffix = substring(uniqueString(resourceGroup().id, location), 0, 8)

// https://github.com/kubernetes/k8s.io/tree/main/infra/azure/terraform/capz 
// https://github.com/kubernetes/test-infra/blob/master/config/jobs/kubernetes-sigs/sig-windows/release-master-windows.yaml
// https://github.com/kubernetes-sigs/windows-testing/tree/master/capz

resource cloudproviderId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'cloud-provider-user-identity'
  location: location
}

resource domainVMId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'domain-vm-identity'
  location: location
}

resource gmsaId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'gmsa-user-identity'
  location: location
}

resource gmsa_kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${resource_prefix}gmsakv${random_suffix}'
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: domainVMId.properties.principalId
        permissions: {
          secrets: ['set']
        }
      }
      {
        tenantId: subscription().tenantId
        objectId: gmsaId.properties.principalId
        permissions: {
          secrets: ['get']
        }
      }
    ]
  }
}

resource capzci_registry 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: '${resource_prefix}ci${random_suffix}'
  location: location
  sku: {
    name: 'Premium'
  }
  properties:{
    anonymousPullEnabled: true
    policies: {
      retentionPolicy: {
        days: 7
        status: 'enabled'
      }
    }
  }
}

resource registrytask 'Microsoft.ContainerRegistry/registries/tasks@2019-06-01-preview' = {
  name: 'midnight_capz_purge'
  parent: capzci_registry
  location: location
  properties: {
    platform: {
      os: 'Linux'
      architecture: 'amd64'
    }
    trigger:{
      timerTriggers: [
        {
          name: 't1'
          schedule: '0 0 * * *'
          status: 'enabled'
        } 
      ]
      baseImageTrigger: {
        name: 'defaultBaseimageTriggerName'
        baseImageTriggerType: 'Runtime'
        updateTriggerPayloadType: 'Default'
      }
    }
    agentConfiguration: {
      cpu: 2
    }

    step: {
      type: 'EncodedTask'
      encodedTaskContent: base64('''
version: v1.1.0
steps:
  - cmd: acr purge --filter azdisk:* --filter azure-cloud-controller-manager:* --filter azure-cloud-node-manager-arm64:* --filter azure-cloud-node-manager:* --filter cluster-api-azure:* --ago 1d --untagged
    disableWorkingDirectoryOverride: true
    timeout: 3600
''')
    }
  }
}

resource e2eprivatecommunity 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: '${resource_prefix}e2e${random_suffix}'
  location: location
  sku: {
    name: 'Premium'
  }
  properties:{
    anonymousPullEnabled: true
    policies: {
      retentionPolicy: {
        days: 7
        status: 'enabled'
      }
    }
  }
}

resource capzsa 'Microsoft.Storage/storageAccounts@2022-05-01' = {
  name: '${resource_prefix}sa${random_suffix}'
  location: location
  sku: {
    name: 'Standard_ZRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  } 
}

resource cloudproviderblobcontributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('storage-rbac', cloudproviderId.id, capzsa.id, 'Storage Blob Data Contributor')
  scope: capzsa
  properties: {
    principalId: cloudproviderId.properties.principalId
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalType: 'ServicePrincipal'
    description: 'Allow controlPlane VM to download private build from storage account'
  }
}

output capzci_registry_name string = capzci_registry.name
output capz_gmsa_kv_name string = gmsa_kv.name
output capzsastorage_name string = capzsa.name
