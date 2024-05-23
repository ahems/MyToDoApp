param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param openAiDeploymentName string
param openAiEndpoint string
param sqlServerName string = 'todoapp-sql-${toLower(uniqueString(resourceGroup().id))}'
param location string = resourceGroup().location
param sqlAdminUsername string = uniqueString(newGuid())
@secure()
param sqlAdminPassword string = newGuid()
param cognitiveservicesname string

var sqlDatabaseName = 'todo'

resource sqlServer 'Microsoft.Sql/servers@2021-02-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    administratorLogin: sqlAdminUsername
    administratorLoginPassword: sqlAdminPassword
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
  }
}

resource OpenAiDeployment 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'AZUREOPENAIDEPLOYMENTNAME'
  properties: {
    value: openAiDeploymentName
    contentType: 'text/plain'
  }
}

resource account 'Microsoft.CognitiveServices/accounts@2021-04-30' existing = {
  name: cognitiveservicesname
}

resource OpenAiKey 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'AZUREOPENAIAPIKEY'
  properties: {
    value: account.listKeys().key1
    contentType: 'text/plain'
  }
}
resource Endpoint 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'AZUREOPENAIENDPOINT'
  properties: {
    value: openAiEndpoint
    contentType: 'text/plain'
  }
}

resource admin 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'AZURESQLUSER'
  properties: {
    value: sqlAdminUsername
    contentType: 'text/plain'
  }
}

resource password 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'AZURESQLPASSWORD'
  properties: {
    value: sqlAdminPassword
    contentType: 'text/plain'
  }
}

resource server 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'AZURESQLSERVER'
  properties: {
    value: '${sqlServerName}.database.windows.net'
    contentType: 'text/plain'
  }
}

resource port 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'AZURESQLPORT'
  properties: {
    value: '1433'
    contentType: 'text/plain'
  }
}
