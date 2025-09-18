targetScope = 'resourceGroup'
param resourceToken string = toLower(uniqueString(resourceGroup().id, environmentName, location))
param environmentName string
param cognitiveservicesname string
param keyVaultName string = 'todoapp-kv-${resourceToken}'
param identityName string = 'todoapp-identity-${resourceToken}'
param appInsightsName string = 'todoapp-appinsights-${toLower(resourceToken)}'
param workspaceName string = 'todoapp-workspace-${toLower(resourceToken)}'
param acrName string = 'todoappacr${toLower(resourceToken)}'
param sqlServerName string = 'todoapp-sql-${toLower(resourceToken)}'
param diagnosticsName string = 'acr-diagnostics-${toLower(resourceToken)}'
param cognitiveservicesLocation string = resourceGroup().location
param redisCacheName string = 'todoapp-redis-${resourceToken}'
param location string = resourceGroup().location
param repositoryUrl string = 'https://github.com/ahems/MyToDoApp.git#main'
param apiAppName string = 'todoapp-webapp-api-${resourceToken}'
param webAppName string = 'todoapp-webapp-web-${resourceToken}'
param apiImageNameAndVersion string = 'todoapi:latest'
param appImageNameAndVersion string = 'todoapp:latest'
param appServicePlanSku string = 'B1'
param appServicePlanName string = 'todoapp-asp-${resourceToken}'
param adminUserEnabled bool = true
param aadAdminLogin string
param aadAdminObjectId string
@description('Wether to use authorization on the API or not. If set to true, the API will be secured with Entra AD.')
param useAuthorizationOnAPI bool = false
@description('Wether to restore the OpenAI service or not. If set to true, the OpenAI service will be restored from a soft-deleted backup. Use this only if you have previously deleted the OpenAI service created with this script, as you will need to restore it.')
param restoreOpenAi bool
param tenantId string = subscription().tenantId
param useFreeLimit bool
param webAppClientId string
@secure()
param webAppClientSecret string
param openAiDeploymentName string = 'chat'
param chatGptModelName string
param chatGptDeploymentName string = 'chat'
param chatGptDeploymentVersion string
param chatGptSkuName string
param availableChatGptDeploymentCapacity int
param embeddingModelName string
param embeddingDeploymentName string = 'embedding'
param embeddingDeploymentVersion string
param embeddingSkuName string
param availableEmbeddingDeploymentCapacity int
param deployToWebAppInsteadOfContainerApp bool = false 
// Generate a short, unique revision suffix per deployment to avoid conflicts
param revisionSuffix string = toLower(substring(replace(newGuid(),'-',''), 0, 8))

var apiAppURL = 'https://${apiAppName}.azurewebsites.net/graphql/'
var chatGptDeploymentCapacity = availableChatGptDeploymentCapacity / 10
var embeddingDeploymentCapacity = availableEmbeddingDeploymentCapacity / 10

module authentication 'modules/authentication.bicep' = {
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
  name: 'Deploy-Redis'
  params: {
    redisCacheName: redisCacheName
    location: location
    identityName: identityName
  }
  dependsOn: [
    identity
  ]
}

module cognitiveservices 'modules/openai.bicep' = {
  name: 'Deploy-Open-AI-Service'
  params: {
    name: cognitiveservicesname
    location: cognitiveservicesLocation
    identityName: identityName
    customSubDomainName: cognitiveservicesname
    restoreOpenAi: restoreOpenAi
    chatGptModelName: chatGptModelName
    chatGptDeploymentName: chatGptDeploymentName
    chatGptDeploymentVersion: chatGptDeploymentVersion
    chatGptDeploymentCapacity: chatGptDeploymentCapacity
    chatGptSkuName: chatGptSkuName
    keyVaultName: keyVaultName
    embeddingModelName: embeddingModelName
    embeddingDeploymentName: embeddingDeploymentName
    embeddingDeploymentVersion: embeddingDeploymentVersion
    embeddingDeploymentCapacity: embeddingDeploymentCapacity
    embeddingSkuName: embeddingSkuName
    openAiDeploymentName: openAiDeploymentName
  }
  dependsOn: [
    keyvault
  ]
}

module keyvault 'modules/keyvault.bicep' = {
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

// Surface ACR endpoint for azd environment injection
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.outputs.loginServer

module identity 'modules/identity.bicep' = {
  name: 'Deploy-User-Managed-Identity'
  params: {
    identityName: identityName
    location: location
  }
}

module appinsights 'modules/applicationinsights.bicep' = {
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

module containerApp 'modules/aca.bicep' = if (!deployToWebAppInsteadOfContainerApp) {
  name: 'Deploy-Container-App'
  params: {
    keyVaultName:keyVaultName
    location: location
    appInsightsName:appInsightsName
    appName:'todoapp-app-${resourceToken}'
    apiName:'todoapp-api-${resourceToken}'
    containerAppEnvName:'todoapp-env-${resourceToken}'
    workspaceName:workspaceName
    openAiName:cognitiveservicesname    
    containerRegistryName:acrName
    identityName:identityName
    openAiDeploymentName:openAiDeploymentName
    minReplica:0
    maxReplica:3
    sqlConnectionString: database.outputs.connectionString
    revisionSuffix:revisionSuffix
    redisConnectionString: redis.outputs.entraConnectionString
  }
  dependsOn: [
    appinsights
    identity
    cognitiveservices
    acr
    keyvault
  ]
}

output APP_REDIRECT_URI string = deployToWebAppInsteadOfContainerApp ? 'https://${webAppName}.azurewebsites.net/getAToken' : containerApp!.outputs.APP_REDIRECT_URI

module buildTaskForWeb 'modules/task.bicep' = if (deployToWebAppInsteadOfContainerApp) {
  name: 'Deploy-Build-Task-For-Web-To-ACR'
  params: {
    acrName: acrName
    location: location
    acrTaskName: 'buildWebApp'
    contextPath: repositoryUrl
    repoName: 'todoapp'
    taskBuildVersionTag: 'latest'
    useAuthorization: false
    identityName: identityName
  }
  dependsOn: [
    continuousDeploymentForWebApp
  ]
}

module buildTaskForAPI 'modules/task.bicep' = if (deployToWebAppInsteadOfContainerApp) {
  name: 'Deploy-Build-Task-For-API-To-ACR'
  params: {
    acrName: acrName
    location: location
    acrTaskName: 'buildAPIApp'
    contextPath: '${repositoryUrl}:api'
    repoName: 'todoapi'
    taskBuildVersionTag: 'latest'
    useAuthorization: useAuthorizationOnAPI
    identityName: identityName
  }
  dependsOn: [
    continuousDeploymentForApiApp
  ]
}

module appServicePlan  'modules/appserviceplan.bicep' = if (deployToWebAppInsteadOfContainerApp) {
  name: 'Deploy-App-Service-Plan'
  params: {
    appServicePlanName:appServicePlanName
    location: location
    appServicePlanSku: appServicePlanSku
  }
}

module webapp  'modules/webapp.bicep' = if (deployToWebAppInsteadOfContainerApp) {
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

module continuousDeploymentForWebApp 'modules/continuous-deployment.bicep' = if (deployToWebAppInsteadOfContainerApp) {
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

module apiapp 'modules/apiapp.bicep' = if (deployToWebAppInsteadOfContainerApp) {
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
  allowedIpAddresses: webapp!.outputs.outgoingIpAddresses
    keyVaultName:keyVaultName
  }
  dependsOn: [
    database
    appServicePlan
    keyvault
    appinsights
    identity
  ]
}

module continuousDeploymentForApiApp 'modules/continuous-deployment.bicep' = if (deployToWebAppInsteadOfContainerApp) {
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
