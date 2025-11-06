param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param appInsightsName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param apiName string = 'todoapp-api-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param containerRegistryName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param containerAppEnvId string
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
param sqlConnectionString string
@secure()
param redisConnectionString string
param clientId string
param apiAppIdUri string

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource api 'Microsoft.App/containerApps@2024-03-01' = {
  name: apiName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${azidentity.id}': {}
    }
  }
  tags: {
    'azd-service-name': 'api'
  }
  properties: {
    managedEnvironmentId: containerAppEnvId
    configuration: {
      secrets: [
        {
          name: 'database-connection-string'
          value: sqlConnectionString
        }
      ]
      ingress: {
        external: true
        targetPort: 5000
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
          name: apiName
          image: bootstrapImage
          resources: {
            cpu: json('.25')
            memory: '.5Gi'
          }
          env: [
            {
              name: 'DATABASE_CONNECTION_STRING'
              value: sqlConnectionString
            }
            {
              name: 'REDIS_CONNECTION_STRING'
              value: redisConnectionString
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsights.properties.ConnectionString
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: azidentity.properties.clientId
            }
            {name: 'CLIENT_ID'
             value: clientId
            }
            {
              name: 'API_APP_ID_URI'
              value: apiAppIdUri
            }
            {
              name: 'API_APP_ID'
              value: split(apiAppIdUri, '/')[2]
            }
            {
              name: 'TENANT_ID'
              value: subscription().tenantId
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

resource apiurl 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'API-URL'
  properties: {
    value: 'https://${api.properties.configuration.ingress.fqdn}/graphql/'
    contentType: 'text/plain'
  }
}

output apiUrl string = 'https://${api.properties.configuration.ingress.fqdn}/graphql/'
output apiFqdn string = api.properties.configuration.ingress.fqdn
