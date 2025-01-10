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
param appImageNameAndVersion string = 'todoapp:latest'
param apiImageNameAndVersion string = 'todoapi:latest'
param workspaceName string = 'todoapp-workspace-${toLower(uniqueString(resourceGroup().id))}'
param openAiDeploymentName string = 'gpt-35-turbo'
param azureSqlPort string = '1433'
@minValue(0)
@maxValue(25)
param minReplica int = 1
@minValue(0)
@maxValue(25)
param maxReplica int = 3
@secure()
param azuresqlpassword string
@secure()
param revisionSuffix string

var appImage = '${containerRegistryName}.azurecr.io/${appImageNameAndVersion}'
var apiImage = '${containerRegistryName}.azurecr.io/${apiImageNameAndVersion}'

resource sqlServer 'Microsoft.Sql/servers@2024-05-01-preview' existing = {
  name: sqlServerName
}

resource openAi 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = {
  name: openAiName
}
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
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

resource containerAppEnv 'Microsoft.App/managedEnvironments@2022-06-01-preview' = {
  name: containerAppEnvName
  location: location
  sku: {
    name: 'Consumption'
  }
  properties: {
    zoneRedundant: false
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspace.properties.customerId
        sharedKey: workspace.listKeys().primarySharedKey
      }
    }
    daprAIConnectionString: appInsights.properties.ConnectionString
    daprAIInstrumentationKey: appInsights.properties.InstrumentationKey
  }
}

var DATABASE_CONNECTION_STRING = 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},${azureSqlPort};Initial Catalog=todo;Persist Security Info=False;User ID=${sqlServer.properties.administratorLogin};Password=${azuresqlpassword};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${azidentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      secrets: [
        {
          name: 'azure-openai-deployment-name'
          value: openAiDeploymentName
        }
        {
          name: 'azure-openai-api-key'
          value: openAi.listKeys().key1
        }
        {
          name: 'azure-openai-endpoint'
          value: openAi.properties.endpoint     
        }
        {
          name: 'azure-sql-server'
          value: sqlServer.properties.fullyQualifiedDomainName    
        }
        {
          name: 'azure-sql-user'
          value: sqlServer.properties.administratorLogin
        }
        {
          name: 'azure-sql-password'
          value: azuresqlpassword
        }
        {
          name: 'azure-sql-port'
          value: azureSqlPort
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
          image: appImage
          resources: {
            cpu: json('.25')
            memory: '.5Gi'
          }
          env: [
            {
              name: 'KEY_VAULT_NAME'
              value: keyVaultName
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
              name: 'API_URL'
              value: 'https://${containerApi.properties.configuration.ingress.fqdn}/graphql/'
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

resource containerApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: apiName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${azidentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      secrets: [
        {
          name: 'database-connection-string'
          value: DATABASE_CONNECTION_STRING
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
          image: apiImage
          resources: {
            cpu: json('.25')
            memory: '.5Gi'
          }
          env: [
            {
              name: 'DATABASE_CONNECTION_STRING'
              value: DATABASE_CONNECTION_STRING
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
    value: 'https://${containerApp.properties.configuration.ingress.fqdn}/getAToken'
    contentType: 'text/plain'
  }
}

resource apiurl 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'API-URL'
  properties: {
    value: 'https://${containerApi.properties.configuration.ingress.fqdn}/graphql/'
    contentType: 'text/plain'
  }
}
