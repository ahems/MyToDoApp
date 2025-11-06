param appName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param workspaceName string = 'todoapp-workspace-${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param aadAdminObjectId string

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

// Use Azure Verified Module for Log Analytics Workspace
module workspace 'br/public:avm/res/operational-insights/workspace:0.12.0' = {
  name: 'log-analytics-workspace-${workspaceName}'
  params: {
    name: workspaceName
    location: location
    skuName: 'PerGB2018'
    dataRetention: 30
    dailyQuotaGb: 1
  }
}

// Use Azure Verified Module for Application Insights
module appInsights 'br/public:avm/res/insights/component:0.6.1' = {
  name: 'app-insights-${appName}'
  params: {
    name: appName
    location: location
    kind: 'web'
    applicationType: 'web'
    workspaceResourceId: workspace.outputs.resourceId
    disableLocalAuth: true
    roleAssignments: [
      {
        principalId: azidentity.properties.principalId
        roleDefinitionIdOrName: 'Monitoring Metrics Publisher'
        principalType: 'ServicePrincipal'
      }
      {
        principalId: aadAdminObjectId
        roleDefinitionIdOrName: 'Monitoring Metrics Publisher'
        principalType: 'User'
      }
    ]
  }
}
