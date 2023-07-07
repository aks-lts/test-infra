param aks_cluster_region string = 'westus2'
param aks_cluster_prefix string = 'aks-lts-prow'
param system_vm_sku string = 'Standard_DS3_v2'
param prow_vm_sku string = 'Standard_DS3_v2'
param test_vm_sku string = 'Standard_D8s_v5'
param storage_account_prefix string = 'prow'

resource aks 'Microsoft.ContainerService/managedClusters@2023-03-01' = {
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
        osDiskType: 'Managed'
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

#disable-next-line outputs-should-not-contain-secrets // confirmed that GHA properly obfuscates in logs
output kubeconfig string = aks.listClusterAdminCredential().kubeconfigs[0].value
output aksClusterName string = aks.name
output resourceGroupName string = resourceGroup().name
output publicIPName string = ingresspip.name
output storageAccountName string = sa.name
#disable-next-line outputs-should-not-contain-secrets // confirmed that GHA properly obfuscates in logs
output storageAccountKey string = listKeys(sa.id, sa.apiVersion).keys[0].value
output prowHostName string = clusterIngressFrontDoor.outputs.prowHostName
