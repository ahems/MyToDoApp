param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param openAiName string = 'todoapp-openai-${uniqueString(resourceGroup().id)}'
param sqlServerName string = 'todoapp-sql-${uniqueString(resourceGroup().id)}'
param appInsightsName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param appName string = 'todoapp-app-${uniqueString(resourceGroup().id)}'
param apiName string = 'todoapp-api-${uniqueString(resourceGroup().id)}'
param containerAppEnvName string = 'todoapp-env-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param containerRegistryName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param appImageNameAndVersion string = 'mytodoapp:latest'
param apiImageNameAndVersion string = 'mytodoapi:latest'
param workspaceName string = 'todoapp-workspace-${toLower(uniqueString(resourceGroup().id))}'
param openAiDeploymentName string = 'chat'
param azureSqlPort string = '1433'
param revisionSuffix string = uniqueString(utcNow())

@minValue(0)
@maxValue(25)
param minReplica int = 1
@minValue(0)
@maxValue(25)
param maxReplica int = 3

resource keyVault 'Microsoft.KeyVault/vaults@2019-09-01' existing = {
  name: keyVaultName
}

module aca  'modules/aca.bicep' = {
  name: 'aca'
  params: {
    azuresqlpassword:keyVault.getSecret('AZURESQLPASSWORD')
    revisionSuffix:revisionSuffix
    location: location
    keyVaultName: keyVaultName
    openAiName: openAiName
    sqlServerName:sqlServerName
    appInsightsName:appInsightsName
    appName:appName
    apiName:apiName
    containerAppEnvName:containerAppEnvName
    containerRegistryName:containerRegistryName
    identityName:identityName
    appImageNameAndVersion:appImageNameAndVersion
    apiImageNameAndVersion:apiImageNameAndVersion
    workspaceName:workspaceName
    openAiDeploymentName: openAiDeploymentName
    minReplica:minReplica
    maxReplica:maxReplica
    azureSqlPort:azureSqlPort
  }
}
