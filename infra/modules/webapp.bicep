param sqlServerName string = 'todoapp-sql-${uniqueString(resourceGroup().id)}'
param appInsightsName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param webAppName string = 'todoapp-webapp-web-${uniqueString(resourceGroup().id)}'
param apiAppURL string = 'https://todoapp-webapp-api-${uniqueString(resourceGroup().id)}/graphql/'
param location string = resourceGroup().location
param containerRegistryName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param appImageNameAndVersion string = 'todoapp:latest'
param azureSqlPort string = '1433'
param appServicePlanName string = 'todoapp-asp-${uniqueString(resourceGroup().id)}'
param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'

var appImage = '${containerRegistryName}.azurecr.io/${appImageNameAndVersion}'
var DATABASE_CONNECTION_STRING = 'mssql+pyodbc://@${sqlServer.properties.fullyQualifiedDomainName}:${azureSqlPort}/todo?driver=ODBC+Driver+18+for+SQL+Server;Authentication=ActiveDirectoryMsi;User Id=${azidentity.properties.clientId}'

resource sqlServer 'Microsoft.Sql/servers@2021-02-01-preview' existing = {
  name: sqlServerName
}

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: identityName
}

resource acr 'Microsoft.ContainerRegistry/registries@2022-12-01' existing = {
  name: containerRegistryName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource appServicePlan 'Microsoft.Web/serverfarms@2020-12-01' existing = {
  name: appServicePlanName
}

resource webApp 'Microsoft.Web/sites@2022-09-01' = {
  name: webAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${azidentity.id}': {}
    }
  }
  kind: 'app,linux,container'
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      acrUseManagedIdentityCreds: true
      acrUserManagedIdentityID: azidentity.properties.clientId      
      appSettings: [
        {
          name:'KEY_VAULT_NAME'
          value: keyVaultName
        }
        {
          name: 'AZURE_CLIENT_ID'
          value: azidentity.properties.clientId
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: 'https://${acr.properties.loginServer}'
        }
        {
          name: 'DATABASE_CONNECTION_STRING'
          value: DATABASE_CONNECTION_STRING
        }
        {
          name: 'WEBSITES_PORT'
          value: '80'
        }
        {
          name: 'API_URL'
          value: apiAppURL
        }
      ]
      linuxFxVersion: 'DOCKER|${appImage}'
    }
  }
}

resource log 'Microsoft.Web/sites/config@2020-12-01' = {
  name: 'logs'
  parent: webApp
  properties: {
    httpLogs: {
      fileSystem: {
        retentionInMb: 50
        retentionInDays: 7
        enabled: true
      }
    }
    applicationLogs: {
      fileSystem: {
        level: 'Verbose'
      }
    }
  }
}
