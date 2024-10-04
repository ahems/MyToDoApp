param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param webAppName string = 'todoapp-webapp-web-${uniqueString(resourceGroup().id)}'
param tenantId string = subscription().tenantId
param clientId string
@secure()
param clientSecret string

resource keyVault 'Microsoft.KeyVault/vaults@2019-09-01' existing = {
  name: keyVaultName
}

resource webApp 'Microsoft.Web/sites@2022-09-01' existing = {
  name: webAppName
}

resource authoritySecret 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'AUTHORITY'
  properties: {
    value: 'https://login.microsoftonline.com/${tenantId}'
    contentType: 'text/plain'
  }
}

resource clientIdSecret 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'CLIENTID'
  properties: {
    value: clientId
    contentType: 'text/plain'
  }
}

resource authenicationIdSecret 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'CLIENTSECRET'
  properties: {
    value: clientSecret
    contentType: 'text/plain'
  }
}

resource redirectUriSecret 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'REDIRECT-URI'
  properties: {
    value: 'https://${webApp.properties.defaultHostName}/getAToken'
    contentType: 'text/plain'
  } 
}