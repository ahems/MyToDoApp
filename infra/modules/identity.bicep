param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: identityName
  location: location
}

resource keyVault 'Microsoft.KeyVault/vaults@2019-09-01' existing = {
  name: keyVaultName
}

// Apply Key Vault Secrets User
resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid(keyVault.id)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: azidentity.properties.principalId
  }
}

output identityid string = azidentity.id
output clientId string = azidentity.properties.clientId
output principalId string = azidentity.properties.principalId
