param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param sqlServerName string = 'todoapp-sql-${uniqueString(resourceGroup().id)}'
param appInsightsName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param apiAppName string = 'todoapp-webapp-api-${uniqueString(resourceGroup().id)}'
param webAppName string = 'todoapp-webapp-web-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param containerRegistryName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param apiImageNameAndVersion string = 'todoapi:latest'
param appImageNameAndVersion string = 'todoapp:latest'
param azureSqlPort string = '1433'
param appServicePlanSku string = 'B1'
param appServicePlanName string = 'todoapp-asp-${uniqueString(resourceGroup().id)}'

resource keyVault 'Microsoft.KeyVault/vaults@2019-09-01' existing = {
  name: keyVaultName
}

module appServicePlan  'modules/appserviceplan.bicep' = {
  name: 'Deploy-App-Service-Plan'
  params: {
    appServicePlanName:appServicePlanName
    location: location
    appServicePlanSku: appServicePlanSku
  }
}

module webapp  'modules/webapp.bicep' = {
  name: 'Deploy-Web-App'
  params: {
    keyVaultName:keyVaultName
    redisConnectionString:keyVault.getSecret('REDIS-CONNECTION-STRING')
    location: location
    sqlServerName:sqlServerName
    appInsightsName:appInsightsName
    webAppName:webAppName
    apiAppName:apiAppName
    containerRegistryName:containerRegistryName
    identityName:identityName
    appImageNameAndVersion:appImageNameAndVersion
    azureSqlPort:azureSqlPort
    appServicePlanName:appServicePlanName
  }
  dependsOn: [
    appServicePlan
    apiapp
  ]
}

module apiapp  'modules/apiapp.bicep' = {
  name: 'Deploy-API-App'
  params: {
    location: location
    sqlServerName:sqlServerName
    appInsightsName:appInsightsName
    webAppName:apiAppName
    containerRegistryName:containerRegistryName
    identityName:identityName
    apiImageNameAndVersion:apiImageNameAndVersion
    azureSqlPort:azureSqlPort
    appServicePlanName:appServicePlanName
  }
  dependsOn: [
    appServicePlan
  ]
}
