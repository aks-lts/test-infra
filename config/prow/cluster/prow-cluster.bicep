param aks_cluster_region string = 'westus3'
param aks_cluster_prefix string = 'aks-lts-prow'
param aks_cluster_admin_groups array = []
param aks_cluster_admin_users array = []
param system_vm_sku string = 'Standard_DS3_v2'
param prow_vm_sku string = 'Standard_DS3_v2'
param test_vm_sku string = 'Standard_D32d_v4'
param storage_account_prefix string = 'prow'

resource aks 'Microsoft.ContainerService/managedClusters@2024-06-01' = {
  name: '${aks_cluster_prefix}-${uniqueString(resourceGroup().id, aks_cluster_region)}'
  location: aks_cluster_region
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: 'aks-lts-prow'
    agentPoolProfiles: [
      {
        name: 'systempool'
        vmSize: system_vm_sku
        osDiskType: 'Managed'
        kubeletDiskType: 'OS'
        maxPods: 110
        type: 'VirtualMachineScaleSets'
        maxCount: 3
        minCount: 2
        count: 2
        enableAutoScaling: true
        mode: 'System'
        osType: 'Linux'
        osSKU: 'Ubuntu'
        availabilityZones: ['1', '2', '3']
      }
      {
        name: 'prow'
        vmSize: prow_vm_sku
        osDiskType: 'Managed'
        kubeletDiskType: 'OS'
        maxPods: 110
        type: 'VirtualMachineScaleSets'
        maxCount: 3
        minCount: 1
        count: 2
        enableAutoScaling: true
        mode: 'User'
        osType: 'Linux'
        osSKU: 'Ubuntu'
        availabilityZones: ['1', '2', '3']
      }
      {
        name: 'k8stest'
        vmSize: test_vm_sku
        osDiskSizeGB: 256
        osDiskType: 'Ephemeral'
        kubeletDiskType: 'OS'
        maxPods: 110
        type: 'VirtualMachineScaleSets'
        maxCount: 10
        minCount: 2
        count: 2
        enableAutoScaling: true
        mode: 'User'
        osType: 'Linux'
        osSKU: 'Ubuntu'
        availabilityZones: ['1', '2', '3']
        nodeLabels: {
          prowtest: 'true'
        }
      }
    ]
    enableRBAC: true
    networkProfile: {
      networkPlugin: 'azure'
      loadBalancerSku: 'Standard'
    }
    aadProfile: {
      managed: true
      enableAzureRBAC: false
      adminGroupObjectIDs: aks_cluster_admin_groups
      adminUsers: aks_cluster_admin_users
    }
    storageProfile: {
      diskCSIDriver: {
        enabled: true // ghproxy in prow need this.
      }
      snapshotController: {
        enabled: false
      }
      fileCSIDriver: {
        enabled: false
      }
      blobCSIDriver: {
        enabled: true // plan to use this for minio
      }
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
  }
}

resource ingresspip 'Microsoft.Network/publicIPAddresses@2022-11-01' = {
  name: '${aks_cluster_prefix}-ingress-${uniqueString(resourceGroup().id, aks_cluster_region)}'
  location: aks_cluster_region
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
  }
}

resource clusteraccesspip 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('pip-rbac', aks.id, ingresspip.id)
  scope: ingresspip
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7') // network contributor
    principalId: aks.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Allow aks cloud-provider to manage the public IP address'
  }
}

resource sa 'Microsoft.Storage/storageAccounts@2022-05-01' = {
  name: '${storage_account_prefix}${uniqueString(resourceGroup().id, aks_cluster_region)}'
  location: aks_cluster_region
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

resource prowlogsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-05-01' = {
  name: '${sa.name}/default/prow-logs'
}

resource statusRecocilerContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-05-01' = {
  name: '${sa.name}/default/status-reconciler'
}

resource tideContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-05-01' = {
  name: '${sa.name}/default/tide'
}

module clusterIngressFrontDoor 'prow-frontdoor.bicep' = {
  name: 'azurefrontdoor'
  params: {
    namePrefix: aks_cluster_prefix
    location: aks_cluster_region
    ingressIP: ingresspip.properties.ipAddress
  }
}

resource storageContributorPermission 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('storage-rbac', aks.id, sa.id)
  scope: sa
  properties: {
    roleDefinitionId: subscriptionResourceId(subscription().subscriptionId, 'Microsoft.Authorization/roleDefinitions', '17d1049b-9a84-46fb-8f53-869881c3d3ab') // Storage Account Contributor
    principalId: aks.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Allow aks cloud-provider to manage the storage account'
  }
}

output aksClusterName string = aks.name
output resourceGroupName string = resourceGroup().name
output publicIpAddress string = ingresspip.properties.ipAddress
output publicIpName string = ingresspip.name
output storageAccountName string = sa.name
output prowHostName string = clusterIngressFrontDoor.outputs.prowHostName
