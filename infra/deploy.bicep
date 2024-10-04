param cognitiveservicesname string = 'todoapp-openai-${uniqueString(resourceGroup().id)}'
param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param appInsightsName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param workspaceName string = 'todoapp-workspace-${toLower(uniqueString(resourceGroup().id))}'
param acrName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param sqlServerName string = 'todoapp-sql-${toLower(uniqueString(resourceGroup().id))}'
param cognitiveservicesLocation string = 'canadaeast'
param redisCacheName string = 'todoapp-redis-${uniqueString(resourceGroup().id)}'
param rgName string = resourceGroup().name
param aadAdminLogin string
param aadAdminObjectId string

module redis 'modules/redis.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-Redis'
  params: {
    redisCacheName: redisCacheName
    keyVaultName: keyVaultName
  }
  dependsOn: [
    keyvault
  ]
}

module cognitiveservices 'modules/openai.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-Open-AI-Service'
  params: {
    name: cognitiveservicesname
    location: cognitiveservicesLocation
    customSubDomainName: cognitiveservicesname
  }
  dependsOn: [
    keyvault
  ]
}

module keyvault 'modules/keyvault.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-KeyVault'
  params: {
    keyVaultName: keyVaultName
  }
  dependsOn: [
    identity
  ]
}

module database 'modules/database.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-Database'
  params: {
    keyVaultName: keyVaultName
    sqlServerName: sqlServerName
    aadAdminLogin: aadAdminLogin
    aadAdminObjectId: aadAdminObjectId
  }
  dependsOn: [
    keyvault
  ]
}
 module acr 'modules/acr.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-ACR'
  params: {
    acrName: acrName
  }
  dependsOn: [
    identity
  ]
 }

 module identity 'modules/identity.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-Managed-Identity'
  params: {
    identityName: identityName
  }
}

module appinsights 'modules/applicationinsights.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-ApplicationInsights'
  params: {
    appName: appInsightsName
    workspaceName: workspaceName
  }
}
