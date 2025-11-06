param acrName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param diagnosticsName string = 'acr-diagnostics-${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param workspaceName string = 'todoapp-workspace-${toLower(uniqueString(resourceGroup().id))}'
param location string = resourceGroup().location
param adminUserEnabled bool = true

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

// Use Azure Verified Module for Azure Container Registry
module acr 'br/public:avm/res/container-registry/registry:0.9.3' = {
  name: 'container-registry-${acrName}'
  params: {
    name: acrName
    location: location
    acrSku: 'Basic'
    acrAdminUserEnabled: adminUserEnabled
    zoneRedundancy: 'Disabled'
    roleAssignments: [
      {
        principalId: azidentity.properties.principalId
        roleDefinitionIdOrName: 'Contributor'
        principalType: 'ServicePrincipal'
      }
    ]
    diagnosticSettings: [
      {
        name: diagnosticsName
        workspaceResourceId: workspace.id
        logCategoriesAndGroups: [
          {
            category: 'ContainerRegistryRepositoryEvents'
          }
          {
            category: 'ContainerRegistryLoginEvents'
          }
        ]
        metricCategories: [
          {
            category: 'AllMetrics'
          }
        ]
      }
    ]
  }
}

output name string = acr.outputs.name
// Expose the registry login server so it can propagate to environment variables via root module output
output loginServer string = acr.outputs.loginServer
