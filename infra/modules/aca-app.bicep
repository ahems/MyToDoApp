param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param openAiName string = 'todoapp-openai-${uniqueString(resourceGroup().id)}'
param appInsightsName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param appName string = 'todoapp-app-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param containerRegistryName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param containerAppEnvId string
param openAiDeploymentName string = 'gpt-35-turbo'
param apiUrl string
// Public bootstrap image to avoid ACR pull failures during initial infra provisioning
param bootstrapImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
@minValue(0)
@maxValue(25)
param minReplica int = 0
@minValue(0)
@maxValue(25)
param maxReplica int = 3
@secure()
param revisionSuffix string
@secure()
param redisConnectionString string
param apiAppIdUri string

resource openAi 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = {
  name: openAiName
}

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${azidentity.id}': {}
    }
  }
  tags: {
    'azd-service-name': 'app'
  }
  properties: {
    managedEnvironmentId: containerAppEnvId
    configuration: {
      secrets: [
        {
          name: 'azure-openai-api-key'
          value: openAi.listKeys().key1
        }
        {
          name: 'azure-openai-endpoint'
          value: openAi.properties.endpoint     
        }
        {
          name: 'applicationinsights-connection-string'
          value: appInsights.properties.ConnectionString
        }
      ]
      ingress: {
        external: true
        targetPort: 80
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          identity: azidentity.id
          server: acr.properties.loginServer
        }
      ]
    }
    template: {
      revisionSuffix: revisionSuffix
      containers: [
        {
          name: appName
          image: bootstrapImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          probes: [
            {
              type: 'Startup'
              httpGet: {
                path: '/startupz'
                port: 80
              }
              // Startup probe tuned for slow MI availability
              initialDelaySeconds: 15
              periodSeconds: 5
              timeoutSeconds: 30
              successThreshold: 1
              failureThreshold: 3
            }
          ]
          env: [
            {
              name: 'KEY_VAULT_NAME'
              value: keyVaultName
            }
            {
              name: 'REDIS_CONNECTION_STRING'
              value: redisConnectionString
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: azidentity.properties.clientId
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsights.properties.ConnectionString
            }
            {
              name: 'AZURE_OPENAI_DEPLOYMENT_NAME'
              value: openAiDeploymentName
            }
            {
              name: 'API_URL'
              value: apiUrl
            }
            {
              name: 'API_APP_ID_URI'
              value: apiAppIdUri
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplica
        maxReplicas: maxReplica
        rules: [
          {
            name: 'http-requests'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    } 
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource redirecturi 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'REDIRECT-URI'
  properties: {
    value: 'https://${app.properties.configuration.ingress.fqdn}/getAToken'
    contentType: 'text/plain'
  }
}

output appRedirectUri string = 'https://${app.properties.configuration.ingress.fqdn}'
output appFqdn string = app.properties.configuration.ingress.fqdn
