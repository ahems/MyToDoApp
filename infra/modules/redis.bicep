param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param redisCacheName string = 'todoapp-redis-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location

resource redisCache 'Microsoft.Cache/redis@2023-08-01' = {
  name: redisCacheName
  location: location
  properties: {
    sku: {
      name: 'Basic'
      family: 'C'
      capacity: 0
    }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2019-09-01' existing = {
  name: keyVaultName
}

resource admin 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'REDIS-CONNECTION-STRING'
  properties: {
    value: 'rediss://:${redisCache.listKeys().primaryKey}@${redisCache.properties.hostName}:${redisCache.properties.sslPort}/0'
    contentType: 'text/plain'
  }
}
