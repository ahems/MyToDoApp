param acrName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param diagnosticsName string = 'acr-diagnostics-${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param workspaceName string = 'todoapp-workspace-${toLower(uniqueString(resourceGroup().id))}'
param location string = resourceGroup().location
param adminUserEnabled bool = true

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource acrContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid('${acr.name}-contributor')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c') // Contributor role
    principalId: azidentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: adminUserEnabled
    zoneRedundancy: 'Disabled'
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: acr
  name: diagnosticsName
  properties: {
    workspaceId: workspace.id
    logs: [
      {
        category: 'ContainerRegistryRepositoryEvents'
        enabled: true
      }
      {
        category: 'ContainerRegistryLoginEvents'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}


output name string = acr.name
// Expose the registry login server so it can propagate to environment variables via root module output
output loginServer string = acr.properties.loginServer
