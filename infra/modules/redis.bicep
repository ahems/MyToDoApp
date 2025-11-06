param redisCacheName string = 'todoapp-redis-${uniqueString(resourceGroup().id)}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param aadAdminObjectId string
param aadAdminLogin string

@description('Redis pricing tier: Basic, Standard, or Premium')
@allowed([ 'Basic', 'Standard', 'Premium' ])
param redisSkuName string = 'Basic'

@description('Redis family: C for Basic/Standard, P for Premium')
@allowed([ 'C', 'P' ])
param redisSkuFamily string = 'C'

@description('Redis capacity (0-6 for Basic/Standard; 1-5 for Premium). 0 corresponds to C0 (250MB).')
param redisSkuCapacity int = 0

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource redisCache 'Microsoft.Cache/redis@2024-11-01' = {
  name: redisCacheName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${azidentity.id}': {}
    }
  }
  properties: {
    sku: {
      name: redisSkuName
      family: redisSkuFamily
      capacity: redisSkuCapacity
    }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    // Enable Microsoft Entra (AAD) authentication
    redisConfiguration: {
      'aad-enabled': 'true'
    }
    // Require Microsoft Entra ID by disabling access key authentication
    disableAccessKeyAuthentication: true
  }
}

// Grant data-plane access to the passed-in user-assigned managed identity using Redis Data Owner policy
resource redisUserAssignedMIDataOwnerAssignment 'Microsoft.Cache/redis/accessPolicyAssignments@2024-11-01' = {
  name: 'todoapp-MI-DataOwner'
  parent: redisCache
  properties: {
    // Object ID (principalId) of the user-assigned managed identity
    objectId: azidentity.properties.principalId
    // Friendly alias for objectId; also used as the Redis username for token-based auth
    objectIdAlias: identityName
    // Built-in data access policy name: Data Owner | Data Contributor | Data Reader
    accessPolicyName: 'Data Owner'
  }
}

// Grant data-plane access to the passed-in user identity so that debugging locally will work
resource redisUserDataOwnerAssignment 'Microsoft.Cache/redis/accessPolicyAssignments@2024-11-01' = {
  name: 'todoapp-User-DataOwner'
  parent: redisCache
  properties: {
    // Object ID (principalId) of the user-assigned managed identity
    objectId: aadAdminObjectId
    // Friendly alias for objectId; also used as the Redis username for token-based auth
    objectIdAlias: aadAdminLogin
    // Built-in data access policy name: Data Owner | Data Contributor | Data Reader
    accessPolicyName: 'Data Owner'
  } 
  dependsOn: [
    redisUserAssignedMIDataOwnerAssignment
  ]
}

// Useful outputs for clients using Entra-based authentication
output redisHostName string = redisCache.properties.hostName
output redisSslPort int = redisCache.properties.sslPort
// Alias doubles as the Redis username for token-based auth
output redisObjectIdAlias string = identityName
// Entra-style connection string (no password). Client must supply Entra token at runtime.
output entraConnectionString string = 'rediss://${identityName}@${redisCache.properties.hostName}:${redisCache.properties.sslPort}/0'
