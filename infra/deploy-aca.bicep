param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param openAiName string = 'todoapp-openai-${uniqueString(resourceGroup().id)}'
param sqlServerName string = 'todoapp-sql-${uniqueString(resourceGroup().id)}'
param appInsightsName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param acaName string = 'todoapp-aca-${uniqueString(resourceGroup().id)}'
param containerAppEnvName string = 'todoapp-env-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param containerRegistryName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param imageNameAndVersion string = 'mytodoapp:latest'
param workspaceName string = 'todoapp-workspace-${toLower(uniqueString(resourceGroup().id))}'
param openAiDeploymentName string = 'chat'
param azureSqlPort string = '1433'

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
    location: location
    keyVaultName: keyVaultName
    openAiName: openAiName
    sqlServerName:sqlServerName
    appInsightsName:appInsightsName
    acaName:acaName
    containerAppEnvName:containerAppEnvName
    containerRegistryName:containerRegistryName
    identityName:identityName
    imageNameAndVersion:imageNameAndVersion
    workspaceName:workspaceName
    openAiDeploymentName: openAiDeploymentName
    minReplica:minReplica
    maxReplica:maxReplica
    azureSqlPort:azureSqlPort
  }
}
