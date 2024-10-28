param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param sqlServerName string = 'todoapp-sql-${toLower(uniqueString(resourceGroup().id))}'
param location string = resourceGroup().location
param aadAdminLogin string
param aadAdminObjectId string
param tenantId string = subscription().tenantId
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'

var sqlDatabaseName = 'todo'

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: identityName
}

resource sqlServer 'Microsoft.Sql/servers@2021-02-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

resource sqlServerFirewallRule 'Microsoft.Sql/servers/firewallRules@2021-02-01-preview' = {
  parent: sqlServer
  name: 'AllowAll'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '255.255.255.255'
  }
}

resource sqlServerAdmin 'Microsoft.Sql/servers/administrators@2021-02-01-preview' = {
  parent: sqlServer
  name: 'ActiveDirectory'
  properties: {
    administratorType: 'ActiveDirectory'
    login: aadAdminLogin
    sid: aadAdminObjectId
    tenantId: tenantId
  }
}

resource azureADOnlyAuth 'Microsoft.Sql/servers/azureADOnlyAuthentications@2021-02-01-preview' = {
  parent: sqlServer
  name: 'default'
  properties: {
    azureADOnlyAuthentication: true
  }
  dependsOn: [
    sqlServerAdmin
  ]
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2021-02-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: location
  sku: {
    name: 'GP_S_Gen5_4'
    tier: 'GeneralPurpose'
    family: 'Gen5'
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 34359738368
    zoneRedundant: false
    readScale: 'Disabled'
    highAvailabilityReplicaCount: 0
    autoPauseDelay: 120
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2019-09-01' existing = {
  name: keyVaultName
}

resource server 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'AZURESQLSERVER'
  properties: {
    value: '${sqlServerName}${environment().suffixes.sqlServerHostname}'
    contentType: 'text/plain'
  }
  dependsOn: [sqlServer]
}

resource port 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'AZURESQLPORT'
  properties: {
    value: '1433'
    contentType: 'text/plain'
  }
  dependsOn: [sqlServer]
}

resource connectionString 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'DATABASE-CONNECTION-STRING'
  properties: {
    value: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Initial Catalog=${sqlDatabaseName};Authentication=Active Directory Default;User Id=${azidentity.properties.clientId}'
    contentType: 'text/plain'
  }
}
