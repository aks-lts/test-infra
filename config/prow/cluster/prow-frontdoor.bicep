param namePrefix string
param location string
param ingressIP string

resource clusterIngressFrontdoor 'Microsoft.Cdn/profiles@2022-11-01-preview' = {
  name: '${namePrefix}-${uniqueString(resourceGroup().id, location)}'
  location: 'Global'
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
  kind: 'frontdoor'
  properties: {
    originResponseTimeoutSeconds: 60
  }
}

resource azureProwEndpoint 'Microsoft.Cdn/profiles/afdendpoints@2022-11-01-preview' = {
  parent: clusterIngressFrontdoor
  name: 'aksltsprow'
  location: 'Global'
  properties: {
    enabledState: 'Enabled'
  }
}

resource prowOriginGroup 'Microsoft.Cdn/profiles/origingroups@2022-11-01-preview' = {
  parent: clusterIngressFrontdoor
  name: 'aks-lts-prow-origingroup'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: '/'
      probeRequestType: 'HEAD'
      probeProtocol: 'Http'
      probeIntervalInSeconds: 100
    }
    sessionAffinityState: 'Disabled'
  }
}

resource prowOrigin 'Microsoft.Cdn/profiles/origingroups/origins@2022-11-01-preview' = {
  parent: prowOriginGroup
  name: 'default-origin'
  properties: {
    hostName: ingressIP
    httpPort: 80
    httpsPort: 443
    originHostHeader: 'lts-prow.aks.azure.com' // as long as it matches with ingress-prow.yaml
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

resource azureProwEndpointToOrigin 'Microsoft.Cdn/profiles/afdendpoints/routes@2022-11-01-preview' = {
  parent: azureProwEndpoint
  name: 'default-route'
  properties: {
    customDomains: []
    originGroup: {
      id: prowOriginGroup.id
    }
    ruleSets: []
    supportedProtocols: [
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'HttpOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
    enabledState: 'Enabled'
  }
}

output prowHostName string = azureProwEndpoint.properties.hostName
