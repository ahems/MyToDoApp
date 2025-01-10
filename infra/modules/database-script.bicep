param sqlServerName string = 'todoapp-sql-${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param containerGroupName string = 'database-${uniqueString(sqlServerName)}'
param location string = resourceGroup().location

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource sqlServer 'Microsoft.Sql/servers@2024-05-01-preview' = {
  name: sqlServerName
  location: location
}

var sqlDatabaseName = 'todo'
var ConnectionString = 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Initial Catalog=${sqlDatabaseName};Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;Authentication="Active Directory Default";User Id=${azidentity.properties.clientId}'

resource script 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'runSqlScript'
  location: location
  kind: 'AzurePowerShell'
  properties: {
    azPowerShellVersion: '7.0.0'
    containerSettings: {
      containerGroupName: containerGroupName
    }
    retentionInterval: 'PT60M'
    environmentVariables: [
      {
        name: 'CONNECTION_STRING'
        value: ConnectionString
      }
    ]
    scriptContent: '''
        Install-Module -Name SqlServer -Force -AllowClobber
        Import-Module SqlServer

        $ConnectionString = $env:CONNECTION_STRING

        $SqlConnection = New-Object Microsoft.Data.SqlClient.SqlConnection
        $SqlConnection.ConnectionString = $ConnectionString
        $SqlConnection.Open()

        $SqlCommand = $SqlConnection.CreateCommand()
        $SqlCommand.CommandText = "CREATE TABLE ToDo (
            id INT IDENTITY(1,1) PRIMARY KEY,
            name NVARCHAR(100) NOT NULL,
            recommendations_json JSON,
            notes NVARCHAR(100),
            priority INT DEFAULT 0,
            completed BIT DEFAULT 0,
            due_date NVARCHAR(50),
            oid NVARCHAR(50)
        );"
        $SqlCommand.ExecuteNonQuery()

        $SqlConnection.Close()
    '''
    timeout: 'PT5M'
    cleanupPreference: 'OnSuccess'
  }
}
