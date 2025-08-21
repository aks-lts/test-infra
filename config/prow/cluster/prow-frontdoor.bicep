param namePrefix string
param location string
param ingressIP string
@secure()
param frontDoorSecret string = ''

resource clusterIngressFrontdoor 'Microsoft.Cdn/profiles@2022-11-01-preview' = {
  name: '${namePrefix}-${uniqueString(resourceGroup().id, location)}'
  location: 'Global'
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
  properties: {
    originResponseTimeoutSeconds: 60
  }
}

resource azureProwEndpoint 'Microsoft.Cdn/profiles/afdendpoints@2022-11-01-preview' = {
  parent: clusterIngressFrontdoor
  name: 'ltsprow-${uniqueString(resourceGroup().id, location)}'
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
    originHostHeader: azureProwEndpoint.properties.hostName
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

resource azureProwEndpointToOrigin 'Microsoft.Cdn/profiles/afdendpoints/routes@2022-11-01-preview' = {
  parent: azureProwEndpoint
  name: 'default-route'
  dependsOn: [
    prowOrigin
  ]
  properties: {
    customDomains: []
    originGroup: {
      id: prowOriginGroup.id
    }
    ruleSets: [
      {
        id: prowRuleSet.id
      }
    ]
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

// Create an (empty) rule set resource. Azure manages the rule set properties.
// Individual rules are added as child resources under the rule set.
resource prowRuleSet 'Microsoft.Cdn/profiles/ruleSets@2024-09-01' = {
  parent: clusterIngressFrontdoor
  name: 'add-header-rules'
}

// Add a delivery rule that overwrites header `X-From-FrontDoor` with the
// secure value from the `frontDoorSecret` parameter.
// Overwrite the X-From-FrontDoor header with a shared secret so backend
// services can verify the request was proxied by Front Door and trust it.
// This helps prevent direct requests that bypass Front Door from being
// treated as legitimate.
resource prowRule 'Microsoft.Cdn/profiles/ruleSets/rules@2024-09-01' = {
  parent: prowRuleSet
  name: 'add-frontdoor-header'
  properties: {
    order: 1
    actions: [
      {
        name: 'ModifyRequestHeader'
        parameters: {
          typeName: 'DeliveryRuleHeaderActionParameters'
          headerAction: 'Overwrite'
          headerName: 'X-From-FrontDoor'
          value: frontDoorSecret
        }
      }
    ]
    conditions: []
  }
}

output prowHostName string = azureProwEndpoint.properties.hostName
