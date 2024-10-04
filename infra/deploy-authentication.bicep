param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param tenantId string = subscription().tenantId
param clientId string
@secure()
param clientSecret string

module authentication 'modules/authentication.bicep' = {
  name: 'Deploy-Authentication'
  params: {
    keyVaultName: keyVaultName
    tenantId: tenantId
    clientId: clientId
    clientSecret: clientSecret
  }
}
