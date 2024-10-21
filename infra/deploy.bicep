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
param location string = resourceGroup().location
param repositoryUrl string = 'https://github.com/ahems/MyToDoApp'
param apiAppName string = 'todoapp-webapp-api-${uniqueString(resourceGroup().id)}'
param webAppName string = 'todoapp-webapp-web-${uniqueString(resourceGroup().id)}'
param apiImageNameAndVersion string = 'todoapi:latest'
param appImageNameAndVersion string = 'todoapp:latest'
param appServicePlanSku string = 'B1'
param appServicePlanName string = 'todoapp-asp-${uniqueString(resourceGroup().id)}'
param aadAdminLogin string
param aadAdminObjectId string
@secure()
param gitAccessToken string

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
  name: 'Deploy-User-Managed-Identity'
  params: {
    identityName: identityName
  }
}

module appinsights 'modules/applicationinsights.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-Application-Insights'
  params: {
    appName: appInsightsName
    workspaceName: workspaceName
  }
}

module buildTaskForWeb 'modules/task.bicep' = {
  name: 'Deploy-Build-Task-For-Web-To-ACR'
  params: {
    acrName: acrName
    location: location
    acrTaskName: 'buildWebApp'
    contextAccessToken: gitAccessToken
    contextPath: './'
    repositoryUrl: repositoryUrl
    repoName: 'todoapp'
    taskBuildVersionTag: 'latest'
  }
  dependsOn: [
    acr
  ]
}

module buildTaskForAPI 'modules/task.bicep' = {
  name: 'Deploy-Build-Task-For-API-To-ACR'
  params: {
    acrName: acrName
    location: location
    acrTaskName: 'buildAPIApp'
    contextAccessToken: gitAccessToken
    contextPath: './api'
    repositoryUrl: repositoryUrl
    repoName: 'todoapi'
    taskBuildVersionTag: 'latest'
  }
  dependsOn: [
    acr
  ]
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
    location: location
    sqlServerName:sqlServerName
    appInsightsName:appInsightsName
    webAppName:webAppName
    apiAppURL:apiapp.outputs.apiAppURL
    containerRegistryName:acrName
    identityName:identityName
    appImageNameAndVersion:appImageNameAndVersion
    appServicePlanName:appServicePlanName
  }
  dependsOn: [
    appServicePlan
    apiapp
    acr
    keyvault
    appinsights
    identity
    database
  ]
}

module apiapp  'modules/apiapp.bicep' = {
  name: 'Deploy-API-App'
  params: {
    location: location
    sqlServerName:sqlServerName
    appInsightsName:appInsightsName
    webAppName:apiAppName
    containerRegistryName:acrName
    identityName:identityName
    apiImageNameAndVersion:apiImageNameAndVersion
    appServicePlanName:appServicePlanName
  }
  dependsOn: [
    database
    appServicePlan
    acr
    keyvault
    appinsights
    identity
  ]
}
