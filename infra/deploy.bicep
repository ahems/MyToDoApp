param cognitiveservicesname string = 'todoapp-openai-${uniqueString(resourceGroup().id)}'
param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param appInsightsName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param workspaceName string = 'todoapp-workspace-${toLower(uniqueString(resourceGroup().id))}'
param acrName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param sqlServerName string = 'todoapp-sql-${toLower(uniqueString(resourceGroup().id))}'
param cognitiveservicesLocation string = 'canadaeast'
param rgName string

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
}

module database 'modules/database.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-Database'
  params: {
    keyVaultName: keyVaultName
    sqlServerName: sqlServerName
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
    keyVaultName: keyVaultName
  }
  dependsOn: [
    keyvault
  ]
}

module appinsights 'modules/applicationinsights.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-ApplicationInsights'
  params: {
    keyVaultName: keyVaultName
    appName: appInsightsName
    workspaceName: workspaceName
  }
  dependsOn: [
    keyvault
  ]
}
