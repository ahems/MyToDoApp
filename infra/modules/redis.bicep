param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param redisCacheName string = 'todoapp-redis-${uniqueString(resourceGroup().id)}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location

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

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
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
  }
}

resource admin 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'REDIS-CONNECTION-STRING'
  properties: {
    value: 'rediss://:${redisCache.listKeys().primaryKey}@${redisCache.properties.hostName}:${redisCache.properties.sslPort}/0'
    contentType: 'text/plain'
  }
}
