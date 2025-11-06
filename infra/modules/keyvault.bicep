param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param aadAdminObjectId string

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

// Use Azure Verified Module for Key Vault
module keyVault 'br/public:avm/res/key-vault/vault:0.13.3' = {
  name: 'key-vault-${keyVaultName}'
  params: {
    name: keyVaultName
    location: location
    enableRbacAuthorization: true
    enableSoftDelete: false
    enableVaultForTemplateDeployment: true
    sku: 'standard'
    roleAssignments: [
      {
        principalId: azidentity.properties.principalId
        roleDefinitionIdOrName: 'Key Vault Secrets User'
        principalType: 'ServicePrincipal'
      }
      {
        principalId: aadAdminObjectId
        roleDefinitionIdOrName: 'Key Vault Secrets User'
        principalType: 'User'
      }
    ]
  }
}
