param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location

resource keyVault 'Microsoft.KeyVault/vaults@2019-09-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete:false
    enabledForTemplateDeployment : true
  }
}
