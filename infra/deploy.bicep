param cognitiveservicesname string = 'todoapp-openai-${uniqueString(resourceGroup().id)}'
param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param appInsightsName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param workspaceName string = 'todoapp-workspace-${toLower(uniqueString(resourceGroup().id))}'
param acrName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param sqlServerName string = 'todoapp-sql-${toLower(uniqueString(resourceGroup().id))}'
param diagnosticsName string = 'acr-diagnostics-${toLower(uniqueString(resourceGroup().id))}'
param cognitiveservicesLocation string = 'canadaeast'
param redisCacheName string = 'todoapp-redis-${uniqueString(resourceGroup().id)}'
param rgName string = resourceGroup().name
param location string = resourceGroup().location
param repositoryUrl string = 'https://github.com/ahems/MyToDoApp.git#main'
param apiAppName string = 'todoapp-webapp-api-${uniqueString(resourceGroup().id)}'
param webAppName string = 'todoapp-webapp-web-${uniqueString(resourceGroup().id)}'
param apiImageNameAndVersion string = 'todoapi:latest'
param appImageNameAndVersion string = 'todoapp:latest'
param appServicePlanSku string = 'B1'
param appServicePlanName string = 'todoapp-asp-${uniqueString(resourceGroup().id)}'
param adminUserEnabled bool = true
param aadAdminLogin string
param aadAdminObjectId string
@description('Wether to use authorization on the API or not. If set to true, the API will be secured with Entra AD.')
param useAuthorizationOnAPI bool = false
@description('Wether to restore the OpenAI service or not. If set to true, the OpenAI service will be restored from a soft-deleted backup. Use this only if you have previously deleted the OpenAI service created with this script, as you will need to restore it.')
param restoreOpenAi bool
param tenantId string = subscription().tenantId
param useFreeLimit bool = true
param webAppClientId string
@secure()
param webAppClientSecret string

var apiAppURL = 'https://${apiAppName}.azurewebsites.net/graphql/'

module authentication 'modules/authentication.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-Authentication'
  params: {
    keyVaultName: keyVaultName
    tenantId: tenantId
    clientId: webAppClientId
    clientSecret: webAppClientSecret
  }
  dependsOn: [
    keyvault
  ]
}

module redis 'modules/redis.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-Redis'
  params: {
    redisCacheName: redisCacheName
    keyVaultName: keyVaultName
    location: location
  }
  dependsOn: [
    keyvault
    identity
  ]
}

module cognitiveservices 'modules/openai.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-Open-AI-Service'
  params: {
    name: cognitiveservicesname
    location: cognitiveservicesLocation
    customSubDomainName: cognitiveservicesname
    restoreOpenAi: restoreOpenAi
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
    location: location
    identityName: identityName
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
    location: location
    identityName: identityName
    useFreeLimit: useFreeLimit
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
    identityName: identityName
    workspaceName: workspaceName
    adminUserEnabled: adminUserEnabled
    diagnosticsName: diagnosticsName
    location: location
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
    location: location
  }
}

module appinsights 'modules/applicationinsights.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-Application-Insights'
  params: {
    appName: appInsightsName
    workspaceName: workspaceName
    identityName: identityName
    location: location
  }
  dependsOn: [
    identity
  ]
}

module buildTaskForWeb 'modules/task.bicep' = {
  name: 'Deploy-Build-Task-For-Web-To-ACR'
  params: {
    acrName: acrName
    location: location
    acrTaskName: 'buildWebApp'
    contextPath: repositoryUrl
    repoName: 'todoapp'
    taskBuildVersionTag: 'latest'
    useAuthorization: false
  }
  dependsOn: [
    continuousDeploymentForWebApp
  ]
}

module buildTaskForAPI 'modules/task.bicep' = {
  name: 'Deploy-Build-Task-For-API-To-ACR'
  params: {
    acrName: acrName
    location: location
    acrTaskName: 'buildAPIApp'
    contextPath: '${repositoryUrl}:api'
    repoName: 'todoapi'
    taskBuildVersionTag: 'latest'
    useAuthorization: useAuthorizationOnAPI
  }
  dependsOn: [
    continuousDeploymentForApiApp
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
    appInsightsName:appInsightsName
    webAppName:webAppName
    containerRegistryName:acrName
    identityName:identityName
    appImageNameAndVersion:appImageNameAndVersion
    appServicePlanName:appServicePlanName
    apiAppURL:apiAppURL
  }
  dependsOn: [
    appServicePlan
    keyvault
    appinsights
    identity
  ]
}

module continuousDeploymentForWebApp 'modules/continuous-deployment.bicep' = {
  name: 'Configure-CD-For-${webAppName}'
  params: {
    webAppName: webAppName
    containerRegistryName: acrName
    identityName: identityName
    imageNameAndVersion: appImageNameAndVersion
    acrWebhookName: 'todoappwebhook'
  }
  dependsOn: [
    apiapp
    acr
    identity
  ]
}

module apiapp 'modules/apiapp.bicep' = {
  name: 'Deploy-API-App'
  params: {
    location: location
    sqlServerName:sqlServerName
    appInsightsName:appInsightsName
    apiAppName:apiAppName
    containerRegistryName:acrName
    identityName:identityName
    apiImageNameAndVersion:apiImageNameAndVersion
    appServicePlanName:appServicePlanName
    authEnabled: useAuthorizationOnAPI
    allowedIpAddresses: webapp.outputs.outgoingIpAddresses
  }
  dependsOn: [
    database
    appServicePlan
    keyvault
    appinsights
    identity
  ]
}

module continuousDeploymentForApiApp 'modules/continuous-deployment.bicep' = {
  name: 'Configure-CD-For-${apiAppName}'
  params: {
    webAppName: apiAppName
    containerRegistryName: acrName
    identityName: identityName
    imageNameAndVersion: apiImageNameAndVersion
    acrWebhookName: 'todoapiwebhook'
  }
  dependsOn: [
    apiapp
    acr
    identity
  ]
}
