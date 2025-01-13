param appInsightsName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param webAppName string = 'todoapp-webapp-web-${uniqueString(resourceGroup().id)}'
param apiAppURL string = 'https://todoapp-webapp-api-${uniqueString(resourceGroup().id)}.azurewebsites.net/graphql/'
param location string = resourceGroup().location
param containerRegistryName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param appImageNameAndVersion string = 'todoapp:latest'
param appServicePlanName string = 'todoapp-asp-${uniqueString(resourceGroup().id)}'
param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'

var appImage = '${containerRegistryName}.azurecr.io/${appImageNameAndVersion}'

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' existing = {
  name: appServicePlanName
}

resource webApp 'Microsoft.Web/sites@2024-04-01' = {
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
      acrUseManagedIdentityCreds: !acr.properties.adminUserEnabled
      acrUserManagedIdentityID: azidentity.properties.clientId
      appSettings: [
        {
          name: 'API_URL'
          value: apiAppURL
        }
        {
          name: 'REDIRECT_URI'
          value: 'https://${webAppName}.azurewebsites.net/getAToken'
        }
        {
          name:'KEY_VAULT_NAME'
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
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: acr.properties.loginServer
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_USERNAME'
          value: acr.properties.adminUserEnabled ? acr.listCredentials().username : ''
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_PASSWORD'
          value: acr.properties.adminUserEnabled ? acr.listCredentials().passwords[0].value : ''
        }
      ]
      linuxFxVersion: 'DOCKER|${appImage}'
      publicNetworkAccess:'Enabled'
      healthCheckPath: '/login' // Health check path for the Web Site
    }    
  }
}

resource log 'Microsoft.Web/sites/config@2024-04-01' = {
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

output outgoingIpAddresses string[] = split(webApp.properties.outboundIpAddresses, ',')
