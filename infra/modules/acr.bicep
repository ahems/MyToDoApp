param acrName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: identityName
}

// Apply ACR Pull Role
resource acrRoleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid(acr.id)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull role
    principalId: azidentity.properties.principalId
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2022-12-01' = {
  name: acrName
  location: resourceGroup().location
  sku: {
    name: 'Premium'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    networkRuleBypassOptions: 'AzureServices'
    networkRuleSet: {
      defaultAction: 'Allow'
    }
    encryption: {
      status: 'Disabled'
    }
    policies: {
      quarantinePolicy: {
        status: 'Disabled'
      }
      trustPolicy: {
        status: 'Disabled'
      }
    }
    adminUserEnabled: true
    zoneRedundancy: 'Disabled'
  }
}

output name string = acr.name
