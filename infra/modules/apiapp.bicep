param sqlServerName string = 'todoapp-sql-${uniqueString(resourceGroup().id)}'
param appInsightsName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param apiAppName string = 'todoapp-webapp-api-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param containerRegistryName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param apiImageNameAndVersion string = 'todoapi:latest'
param azureSqlPort string = '1433'
param appServicePlanName string = 'todoapp-asp-${uniqueString(resourceGroup().id)}'
param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param authEnabled bool
param allowedIpAddresses string[]
param apiAppClientId string = '00000000-0000-0000-0000-000000000000'
param tenantId string = subscription().tenantId

var apiImage = '${containerRegistryName}.azurecr.io/${apiImageNameAndVersion}'
var DATABASE_CONNECTION_STRING = 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},${azureSqlPort};Initial Catalog=todo;Authentication=Active Directory Default;User Id=${azidentity.properties.clientId}'

resource sqlServer 'Microsoft.Sql/servers@2024-05-01-preview' existing = {
  name: sqlServerName
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

resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' existing = {
  name: appServicePlanName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource apiApp 'Microsoft.Web/sites@2024-04-01' = {
  name: apiAppName
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
          name: 'DATABASE_CONNECTION_STRING'
          value: DATABASE_CONNECTION_STRING
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
          value: 'https://${acr.properties.loginServer}'
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_USERNAME'
          value: acr.properties.adminUserEnabled ? acr.listCredentials().username : ''
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_PASSWORD'
          value: acr.properties.adminUserEnabled ? acr.listCredentials().passwords[0].value : ''
        }
        {
          name: 'WEBSITES_PORT'
          value: '5000'
        }
      ]
      linuxFxVersion: 'DOCKER|${apiImage}'
      publicNetworkAccess:'Enabled'
      healthCheckPath: '/api/todo' // Health check path for the API
      ipSecurityRestrictions: [
        for allowedIp in allowedIpAddresses: {
          ipAddress: '${allowedIp}/0'
          action: 'Allow'
        }
      ]
    }
  }
}

resource authSettings 'Microsoft.Web/sites/config@2024-04-01' = if(authEnabled) {
  name: 'authsettingsV2'
  parent: apiApp
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      unauthenticatedClientAction: 'Return401'
      redirectToProvider: 'azureActiveDirectory'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: apiAppClientId
          clientSecretSettingName: 'CLIENT_SECRET'
          openIdIssuer: 'https://login.microsoftonline.com/${tenantId}/v2.0'
        }
        login: {
          loginParameters: [
            'response_type=code','scope=openid profile email'
          ]
        }
      }
    }
  }
}

resource APIURL 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'API-URL'
  properties: {
    value: 'https://${apiApp.properties.defaultHostName}/graphql/'
    contentType: 'text/plain'
  }
}

resource log 'Microsoft.Web/sites/config@2024-04-01' = {
  name: 'logs'
  parent: apiApp
  properties: {
    applicationLogs: {
      fileSystem: {
        level: 'Verbose'
      }
    }
  }
}

output apiAppURL string = 'https://${apiApp.properties.defaultHostName}/graphql/'
output outgoingIpAddresses string[] = split(apiApp.properties.outboundIpAddresses, ',')
