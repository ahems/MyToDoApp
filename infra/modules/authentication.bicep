param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param tenantId string = subscription().tenantId
@description('The client ID of the web app registration, usedin the code to authenticate users.')
param clientId string
@secure()
@description('The client secret of the web app registration, used in the code to authenticate users.')
param clientSecret string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource authority 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'AUTHORITY'
  properties: {
    value: '${environment().authentication.loginEndpoint}${tenantId}'
    contentType: 'text/plain'
  }
}

resource webAppClientId 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'CLIENTID'
  properties: {
    value: clientId
    contentType: 'text/plain'
  }
}

resource webAppClientSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'CLIENTSECRET'
  properties: {
    value: clientSecret
    contentType: 'text/plain'
  }
}
