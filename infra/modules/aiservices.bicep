param name string = 'todoapp-openai-${uniqueString(resourceGroup().id)}'
param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param location string = 'canadaeast'
param tags object = {}
@description('The custom subdomain name used to access the API. Defaults to the value of the name parameter.')
param customSubDomainName string = name
param kind string = 'AIServices'
param openAiDeploymentName string = 'chat'
param restoreOpenAi bool = false
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param aadAdminObjectId string

@allowed([ 'Enabled', 'Disabled' ])
param publicNetworkAccess string = 'Enabled'
param sku object = {
  name: 'S0'
}

param allowedIpRules array = []
param networkAcls object = empty(allowedIpRules) ? {
  defaultAction: 'Allow'
} : {
  ipRules: allowedIpRules
  defaultAction: 'Deny'
}
param embeddingModelName string = 'embedding'
param embeddingDeploymentName string = ''
param embeddingDeploymentVersion string = ''
param embeddingDeploymentCapacity int = 0
param embeddingSkuName string = ''
var embedding = {
  modelName: !empty(embeddingModelName) ? embeddingModelName : 'text-embedding-ada-002'
  deploymentName: !empty(embeddingDeploymentName) ? embeddingDeploymentName : 'embedding'
  deploymentVersion: !empty(embeddingDeploymentVersion) ? embeddingDeploymentVersion : '2'
  deploymentCapacity: embeddingDeploymentCapacity != 0 ? embeddingDeploymentCapacity : 30
  embeddingSkuName: !empty(embeddingSkuName) ? embeddingSkuName : 'Standard'
}
param openAiHost string = 'azure'
param chatGptModelName string = ''
param chatGptDeploymentName string = 'chat'
param chatGptDeploymentVersion string = ''
param chatGptDeploymentCapacity int = 0
param chatGptSkuName string = ''
var chatGpt = {
  modelName: !empty(chatGptModelName) ? chatGptModelName : startsWith(openAiHost, 'azure') ? 'gpt-35-turbo' : 'gpt-3.5-turbo'
  deploymentName: !empty(chatGptDeploymentName) ? chatGptDeploymentName : 'chat'
  deploymentVersion: !empty(chatGptDeploymentVersion) ? chatGptDeploymentVersion : '0613'
  deploymentCapacity: chatGptDeploymentCapacity != 0 ? chatGptDeploymentCapacity : 30
  skuName: !empty(chatGptSkuName) ? chatGptSkuName : 'Standard'
}

var deployments = [
  {
    name: chatGpt.deploymentName
    model: {
      format: 'OpenAI'
      name: chatGpt.modelName
      version: chatGpt.deploymentVersion
    }
    sku: {
      name: chatGpt.skuName
      capacity: chatGpt.deploymentCapacity
    }
  }
  {
    name: embedding.deploymentName
    model: {
      format: 'OpenAI'
      name: embedding.modelName
      version: embedding.deploymentVersion
    }
    sku: {
      name: 'Standard'
      capacity: embedding.deploymentCapacity
    }
  }
]

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: name
  location: location
  tags: tags
  kind: kind
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${azidentity.id}': {}
    }
  }
  properties: {
    customSubDomainName: customSubDomainName
    publicNetworkAccess: publicNetworkAccess
    networkAcls: networkAcls
    disableLocalAuth: true
    dynamicThrottlingEnabled: false
    restrictOutboundNetworkAccess: false
    restore: restoreOpenAi
  }
  sku: sku
}

// Grant the managed identity data-plane permission to invoke Azure OpenAI deployments (chat/completions, embeddings, etc.)
// Role: Cognitive Services OpenAI User (least-privilege for inference)
// If you need to manage deployments, consider Cognitive Services OpenAI Contributor instead.
// Role definition ID source: Built-in role GUID for 'Cognitive Services OpenAI User'. Adjust if tenant introduces custom role.
resource openAiUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // Use deterministic GUID from account id + identity name (both known at compile time)
  name: guid(account.id, identityName, 'openai-user')
  scope: account
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a001fd3d-188f-4b5d-821b-7da978bf7442') // Cognitive Services OpenAI Contributor
    principalId: azidentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Grant the same data-plane role to the specified AAD admin/user so local development (DefaultAzureCredential using user context) can call the Azure OpenAI deployments directly.
// Uses deterministic GUID to stay idempotent across deployments.
resource openAiUserLocalRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, aadAdminObjectId, 'openai-user')
  scope: account
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a001fd3d-188f-4b5d-821b-7da978bf7442') // Cognitive Services OpenAI Contributor
    principalId: aadAdminObjectId
    principalType: 'User'
  }
}

@batchSize(1)
resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = [for deployment in deployments: {
  parent: account
  name: deployment.name
  properties: {
    model: deployment.model
  }
  sku: deployment.sku
}]

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource OpenAiDeployment 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'AZUREOPENAIDEPLOYMENTNAME'
  properties: {
    value: openAiDeploymentName
    contentType: 'text/plain'
  }
}

resource Endpoint 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'AZUREOPENAIENDPOINT'
  properties: {
    value: account.properties.endpoint
    contentType: 'text/plain'
  }
}

output endpoint string = account.properties.endpoint
output id string = account.id
output name string = account.name
