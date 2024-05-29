param appName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param workspaceName string = 'todoapp-workspace-${toLower(uniqueString(resourceGroup().id))}'
param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'

resource workspace 'Microsoft.OperationalInsights/workspaces@2020-03-01-preview' = {
  name: workspaceName
  location: resourceGroup().location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    workspaceCapping: {
      dailyQuotaGb: 1
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appName
  location: resourceGroup().location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2019-09-01' existing = {
  name: keyVaultName
}

resource AppInsightsKey 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'CONNECTIONSTRING'
  properties: {
    value: appInsights.properties.ConnectionString
    contentType: 'text/plain'
  }
}

output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
