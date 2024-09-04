param resource_prefix string = 'capz'
@secure()
param location string = resourceGroup().location

resource cloudproviderId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${resource_prefix}-cloud-provider-id-${uniqueString(resourceGroup().id, location)}'
  location: location
}

resource domainVMId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${resource_prefix}-domain-vm-id-${uniqueString(resourceGroup().id, location)}'
  location: location
}

resource gmsaId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${resource_prefix}-gmsa-id-${uniqueString(resourceGroup().id, location)}'
  location: location
}

resource gmsa_kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${resource_prefix}-gmsa-${uniqueString(resourceGroup().id, location)}'
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
  name: '${resource_prefix}-capzcicommunity-${uniqueString(resourceGroup().id, location)}'
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
  name: '${resource_prefix}-e2eprivatecommunity-${uniqueString(resourceGroup().id, location)}'
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

resource sa 'Microsoft.Storage/storageAccounts@2022-05-01' = {
  name: '${resource_prefix}-sa-${uniqueString(resourceGroup().id, location)}'
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
