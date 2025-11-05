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
param adminUserEnabled bool = true
param aadAdminLogin string
param aadAdminObjectId string
@description('Wether to restore the OpenAI service or not. If set to true, the OpenAI service will be restored from a soft-deleted backup. Use this only if you have previously deleted the OpenAI service created with this script, as you will need to restore it.')
param restoreOpenAi bool
param tenantId string = subscription().tenantId
param useFreeLimit bool
param webAppClientId string
@secure()
param webAppClientSecret string
param apiAppIdUri string
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
// Generate a short, unique revision suffix per deployment to avoid conflicts
param revisionSuffix string = toLower(substring(replace(newGuid(),'-',''), 0, 8))
param AIServicesKind string = 'AIServices'
param publicNetworkAccess string = 'Enabled'
param sqlDatabaseName string

var chatGptDeploymentCapacity = availableChatGptDeploymentCapacity / 10
var embeddingDeploymentCapacity = availableEmbeddingDeploymentCapacity / 10

module identity 'modules/identity.bicep' = {
  name: 'Deploy-User-Managed-Identity'
  params: {
    identityName: identityName
    location: location
  }
}

module redis 'modules/redis.bicep' = {
  name: 'Deploy-Redis'
  params: {
    redisCacheName: redisCacheName
    location: location
    identityName: identityName
    aadAdminObjectId: aadAdminObjectId
    aadAdminLogin: aadAdminLogin
  }
  dependsOn: [
    identity
  ]
}

module keyvault 'modules/keyvault.bicep' = {
  name: 'Deploy-KeyVault'
  params: {
    keyVaultName: keyVaultName
    location: location
    identityName: identityName
    aadAdminObjectId: aadAdminObjectId
  }
  dependsOn: [
    identity
  ]
}

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

module cognitiveservices 'modules/aiservices.bicep' = {
  name: 'Deploy-AI-Foundry'
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
    kind: AIServicesKind
    publicNetworkAccess: publicNetworkAccess
    aadAdminObjectId: aadAdminObjectId
  }
  dependsOn: [
    keyvault
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
    sqlDatabaseName: sqlDatabaseName
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

module appinsights 'modules/applicationinsights.bicep' = {
  name: 'Deploy-Application-Insights'
  params: {
    appName: appInsightsName
    workspaceName: workspaceName
    identityName: identityName
    location: location
    aadAdminObjectId: aadAdminObjectId
  }
  dependsOn: [
    identity
  ]
}

module containerApp 'modules/aca.bicep' = {
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
    clientId: webAppClientId
    apiAppIdUri: apiAppIdUri
  }
  dependsOn: [
    appinsights
    identity
    cognitiveservices
    acr
    keyvault
  ]
}

output APP_REDIRECT_URI string = containerApp!.outputs.APP_REDIRECT_URI

// Expose values needed for local debugging / .env population
// Key Vault name (already determined as a param -> output for azd env injection)
output KEY_VAULT_NAME string = keyVaultName

// Redis Entra-based connection string (surfaced from redis module output)
output REDIS_CONNECTION_STRING string = redis.outputs.entraConnectionString

// Application Insights connection string (need to reference component resource id after module deployment)
// The module doesn't output it directly, so recreate the name and reference the implicit resource symbol in the module via existing name
// appinsights module uses name appInsightsName; we can read its properties via symbolic name 'appinsights'.
output APPLICATIONINSIGHTS_CONNECTION_STRING string = containerApp.outputs.APPLICATIONINSIGHTS_CONNECTION_STRING

// API URL (GraphQL endpoint) - constructed similarly to what aca module sets inside env values
// The middle tier container app FQDN is not surfaced directly; derive using known naming convention from aca module parameters
// We add an output in aca module instead would be cleaner, but for now replicate pattern: apiName = 'todoapp-api-${resourceToken}'
// Since containerApp module internal resource name uses apiName param, we cannot access its properties here without an output. TODO: add output in aca module.
// Placeholder output (empty) until module is updated; avoids breaking template. Next change will add actual output from aca module.
output API_URL string = containerApp.outputs.API_URL

// Azure Client Id of the user-assigned managed identity
output AZURE_CLIENT_ID string = identity.outputs.clientId

output USER_MANAGED_IDENTITY_NAME string = identityName

output SQL_SERVER_NAME string = sqlServerName

// Service names for azd deploy mapping (required by azd CLI)
output SERVICE_APP_NAME string = 'todoapp-app-${resourceToken}'
output SERVICE_API_NAME string = 'todoapp-api-${resourceToken}'
