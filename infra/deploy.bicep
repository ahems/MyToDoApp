param cognitiveservicesname string = 'todoapp-ai-${uniqueString(resourceGroup().id)}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param cognitiveservicesLocation string = 'canadaeast'
param rgName string
param embeddingModelName string = ''
param embeddingDeploymentName string = ''
param embeddingDeploymentVersion string = ''
param embeddingDeploymentCapacity int = 0
param embeddingDimensions int = 0
var embedding = {
  modelName: !empty(embeddingModelName) ? embeddingModelName : 'text-embedding-ada-002'
  deploymentName: !empty(embeddingDeploymentName) ? embeddingDeploymentName : 'embedding'
  deploymentVersion: !empty(embeddingDeploymentVersion) ? embeddingDeploymentVersion : '2'
  deploymentCapacity: embeddingDeploymentCapacity != 0 ? embeddingDeploymentCapacity : 30
  dimensions: embeddingDimensions != 0 ? embeddingDimensions : 1536
}
param openAiHost string = 'azure'
param chatGptModelName string = ''
param chatGptDeploymentName string = ''
param chatGptDeploymentVersion string = ''
param chatGptDeploymentCapacity int = 0
var chatGpt = {
  modelName: !empty(chatGptModelName) ? chatGptModelName : startsWith(openAiHost, 'azure') ? 'gpt-35-turbo' : 'gpt-3.5-turbo'
  deploymentName: !empty(chatGptDeploymentName) ? chatGptDeploymentName : 'chat'
  deploymentVersion: !empty(chatGptDeploymentVersion) ? chatGptDeploymentVersion : '0613'
  deploymentCapacity: chatGptDeploymentCapacity != 0 ? chatGptDeploymentCapacity : 30
}

param gpt4vModelName string = 'gpt-4'
param gpt4vDeploymentName string = 'gpt-4v'
param gpt4vModelVersion string = 'vision-preview'
param gpt4vDeploymentCapacity int = 10
param useGPT4V bool = false

var defaultOpenAiDeployments = [
  {
    name: chatGpt.deploymentName
    model: {
      format: 'OpenAI'
      name: chatGpt.modelName
      version: chatGpt.deploymentVersion
    }
    sku: {
      name: 'Standard'
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

var openAiDeployments = concat(defaultOpenAiDeployments, useGPT4V ? [
    {
      name: gpt4vDeploymentName
      model: {
        format: 'OpenAI'
        name: gpt4vModelName
        version: gpt4vModelVersion
      }
      sku: {
        name: 'Standard'
        capacity: gpt4vDeploymentCapacity
      }
    }
  ] : [])
  
  
module cognitiveservices 'modules/openai.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-Open-AI-Service-${cognitiveservicesname}'
  params: {
    name: cognitiveservicesname
    location: cognitiveservicesLocation
    deployments: openAiDeployments
    customSubDomainName: cognitiveservicesname
  }
}

module databaseAndKeyVault 'modules/database-and-keyvault.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-Database-And-KeyVault-${cognitiveservicesname}'
  params: {
    userAssignedManagedIdenityPrincipalId: identity.outputs.principalId
    cognitiveservicesname: cognitiveservicesname
    openAiDeploymentName: cognitiveservices.outputs.name
    openAiEndpoint: cognitiveservices.outputs.endpoint
  }
  dependsOn: [
    cognitiveservices
    identity
  ]
}
 module acr 'modules/acr.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-ACR'
 }

 module identity 'modules/identity.bicep' = {
  scope: resourceGroup(rgName)
  name: 'Deploy-Identity'
  params: {
    identityName: identityName
  }
}
