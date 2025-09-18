param appInsightsName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param containerAppEnvName string = 'todoapp-env-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param containerRegistryName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
// Public bootstrap image to avoid ACR pull failures during initial infra provisioning
param bootstrapImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
param sqlServerName string = 'todoapp-sql-${toLower(uniqueString(resourceGroup().id))}'

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource containerAppEnv 'Microsoft.App/managedEnvironments@2023-11-02-preview' existing = {
  name: containerAppEnvName
}

resource dbTest 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'todoapp-dbtest-${uniqueString(resourceGroup().id)}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${azidentity.id}': {}
    }
  }
  tags: {
    'azd-service-name': 'database-test'
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: false
        targetPort: 80
        allowInsecure: false
        traffic: [ { latestRevision: true, weight: 100 } ]
      }
      registries: [
        {
          identity: azidentity.id
          server: acr.properties.loginServer
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'database-test'
          image: bootstrapImage
          resources: {
            cpu: json('0.5')
            memory: '1.0Gi'
          }
          env: [
            { 
              name: 'SQL_SERVER_NAME'
              value: sqlServerName 
            }
            {
              name: 'SQL_DATABASE_NAME'
              value: 'todo' 
            }
            { name: 'DB_TABLE'
              value: 'dbo.todo'
            }
            { name: 'MI_INITIAL_DELAY_SECONDS'
              value: '15'
            }
            { name: 'LOG_VERBOSITY'
              value: 'Normal' 
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: azidentity.properties.clientId
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsights.properties.ConnectionString
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
}
