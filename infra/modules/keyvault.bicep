param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: identityName
}

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

// Apply Key Vault Secrets User (this might fail if the identity has just been created - retry if it does)
resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid(keyVault.id)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: azidentity.properties.principalId
  }
}
