param acrName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param diagnosticsName string = 'acr-diagnostics-${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param workspaceName string = 'todoapp-workspace-${toLower(uniqueString(resourceGroup().id))}'

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
resource acrTask 'Microsoft.ContainerRegistry/registries/tasks@2019-06-01-preview' = {
  name: '${acr.name}/${acrTaskName}'
  properties: {
    platform: {
      os: 'Linux'
      architecture: 'amd64'
    }
    step: {
      type: 'Docker'
      dockerFilePath: 'Dockerfile'
      contextPath: './'
      isPushEnabled: true
      noCache: false
    }
    status: 'Enabled'
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
        status: 'Enabled'
      }
    }
    adminUserEnabled: true
    zoneRedundancy: 'Disabled'
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2020-03-01-preview' existing = {
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
