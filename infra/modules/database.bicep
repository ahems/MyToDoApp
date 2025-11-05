param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param sqlServerName string = 'todoapp-sql-${toLower(uniqueString(resourceGroup().id))}'
param location string = resourceGroup().location
param aadAdminLogin string
param aadAdminObjectId string
param tenantId string = subscription().tenantId
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param useFreeLimit bool
param sqlDatabaseName string

// Existing user-assigned identity & Key Vault
resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Using deterministic FQDN pattern rather than module output to keep secret name stable.
var sqlServerFqdn = '${sqlServerName}${environment().suffixes.sqlServerHostname}'

module sqlServerModule 'br/public:avm/res/sql/server:0.14.0' = {
  name: 'sqlServerDeployment'
  params: {
    name: sqlServerName
    location: location
    // AAD admin mapping
    administrators: {
      azureADOnlyAuthentication: true
      login: aadAdminLogin
      sid: aadAdminObjectId
      tenantId: tenantId
      principalType: 'User'
    }
    // Identity assignment
    managedIdentities: {
      userAssignedResourceIds: [ azidentity.id ]
    }
  // AVM expects primaryUserAssignedIdentityId (not *ResourceId*) when specifying a UAI as primary
  primaryUserAssignedIdentityId: azidentity.id
    // Preserve permissive firewall behavior (legacy compatibility)
    firewallRules: [
      {
        name: 'AllowAll'
        startIpAddress: '0.0.0.0'
        endIpAddress: '255.255.255.255'
      }
    ]
    // Single database definition replicating previous properties
    databases: [
      {
        name: sqlDatabaseName
        sku: {
          name: 'GP_S_Gen5_4'
          tier: 'GeneralPurpose'
        }
        collation: 'SQL_Latin1_General_CP1_CI_AS'
        maxSizeBytes: 34359738368
        zoneRedundant: false
        readScale: 'Disabled'
        highAvailabilityReplicaCount: 0
        autoPauseDelay: 60
        // Serverless databases require a valid minCapacity (in vCores). 0 is invalid; 0.5 is the lowest allowed.
        minCapacity: '0.5'
        licenseType: 'BasePrice'
        useFreeLimit: useFreeLimit
        freeLimitExhaustionBehavior: 'AutoPause'
      }
    ]
    restrictOutboundNetworkAccess: 'Disabled'
  }
}

// Connection string mirrors previous format (Active Directory Default). This uses the Managed Identity assigned to the SQL server.
// This requires the application to also run with an identity that has been granted access to the database
var connectionString = 'Server=tcp:${sqlServerFqdn},1433;Initial Catalog=${sqlDatabaseName};Authentication=Active Directory Default;'

// Secrets (depend on module to ensure ordering)
resource server 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'AZURESQLSERVER'
  properties: {
    value: sqlServerFqdn
    contentType: 'text/plain'
  }
  dependsOn: [ sqlServerModule ]
}

resource port 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'AZURESQLPORT'
  properties: {
    value: '1433'
    contentType: 'text/plain'
  }
  dependsOn: [ sqlServerModule ]
}

resource connectionStringSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'DATABASE-CONNECTION-STRING'
  properties: {
    value: connectionString
    contentType: 'text/plain'
  }
  dependsOn: [ sqlServerModule ]
}

output connectionString string = connectionString
