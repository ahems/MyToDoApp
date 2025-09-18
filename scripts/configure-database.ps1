# Trust PSGallery to suppress the untrusted repository prompt
try {
    $gallery = Get-PSRepository -Name 'PSGallery' -ErrorAction Stop
    if ($gallery.InstallationPolicy -ne 'Trusted') {
        Write-Output "Setting PSGallery repository to Trusted..."
        Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
    }
} catch {
    # PSGallery not registered, so register it
    Write-Output "Registering PSGallery repository..."
    Register-PSRepository -Name 'PSGallery' -SourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted
}

# Install Microsoft Graph module if not already installed
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Output "Installing Microsoft Graph module..."
    Install-Module Microsoft.Graph -Scope CurrentUser -Force -Confirm:$false
}

# Ensure required Az modules are installed (install only what we explicitly need)
if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
    Write-Output "Installing Az.Resources module..."
    Install-Module Az.Resources -Scope CurrentUser -Force -Confirm:$false
}
if (-not (Get-Module -ListAvailable -Name Az.ManagedServiceIdentity)) {
    Write-Output "Installing Az.ManagedServiceIdentity module..."
    Install-Module Az.ManagedServiceIdentity -Scope CurrentUser -Force -Confirm:$false
}
if (-not (Get-Module -ListAvailable -Name Az.Sql)) {
    Write-Output "Installing Az.Sql module..."
    Install-Module Az.Sql -Scope CurrentUser -Force -Confirm:$false
}

# Import required modules
Import-Module Az.Resources -ErrorAction Stop
Import-Module Az.ManagedServiceIdentity -ErrorAction Stop
Import-Module Az.Sql -ErrorAction Stop

# Database naming & connection string pieces
$sqlDatabaseName = 'todo'

# Get tenant ID from azd environment (trim to avoid stray newlines)
$tenantId = (azd env get-value 'TENANT_ID' 2>$null).Trim()

# Authenticate if not already logged in
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Write-Output "Connecting to Azure..."
    if ($tenantId) {
        Write-Output "Connecting to Azure with specified tenant ID..."
        Connect-AzAccount -Tenant $tenantId -UseDeviceAuthentication | Out-Null
    } else {
        Write-Warning "TENANT_ID not found in azd environment. Proceeding without specifying tenant."
        Connect-AzAccount -UseDeviceAuthentication | Out-Null
    }
}

# Get Resource Group and Location from azd environment
$resourceGroupName = (azd env get-value 'AZURE_RESOURCE_GROUP' 2>$null).Trim()
$ManagedIdentityName = (azd env get-value 'USER_MANAGED_IDENTITY_NAME' 2>$null).Trim()

if( $ManagedIdentityName -ceq "ERROR: key 'USER_MANAGED_IDENTITY_NAME' not found in the environment values") {
    try {
        Write-Output "Locating first User Assigned Managed Identity in resource group '$resourceGroupName'..."
        $userAssignedIdentities = Get-AzUserAssignedIdentity -ResourceGroupName $resourceGroupName -ErrorAction Stop | Sort-Object Name

        if (-not $userAssignedIdentities -or $userAssignedIdentities.Count -eq 0) {
            Write-Warning "No user-assigned managed identities found in resource group '$resourceGroupName'."
        } else {
            $selectedIdentity = $userAssignedIdentities | Select-Object -First 1
            $ManagedIdentityName       = $selectedIdentity.Name

            Write-Output "Selected User Assigned Managed Identity: $ManagedIdentityName"

            azd env set 'USER_MANAGED_IDENTITY_NAME' $ManagedIdentityName
        }
    }
    catch {
        Write-Warning "Failed to retrieve user-assigned managed identities: $($_.Exception.Message)"
    }
} else {
    Write-Output "USER_MANAGED_IDENTITY_NAME already set to '$ManagedIdentityName'. Skipping retrieval of user-assigned managed identity."   
}
if( -not $ManagedIdentityName ) {
    Write-Error "USER_MANAGED_IDENTITY_NAME not found in azd environment and no user-assigned managed identity could be located. Please ensure you have a user-assigned managed identity deployed in the resource group."
    exit 1
}

$sqlServerName = (azd env get-value 'SQL_SERVER_NAME' 2>$null).Trim()
if( $sqlServerName -ceq "ERROR: key 'SQL_SERVER_NAME' not found in the environment values") {
    try {
        Write-Output "Locating first SQL Server in resource group '$resourceGroupName'..."
        $sqlServers = Get-AzSqlServer -ResourceGroupName $resourceGroupName -ErrorAction Stop | Sort-Object Name

        if (-not $sqlServers -or $sqlServers.Count -eq 0) {
            Write-Warning "No SQL Servers found in resource group '$resourceGroupName'."
        } else {
            $selectedSqlServer = $sqlServers | Select-Object -First 1
            $sqlServerName     = $selectedSqlServer.ServerName

            Write-Output "Selected SQL Server: $sqlServerName"

            azd env set 'SQL_SERVER_NAME' $sqlServerName
        }
    }
    catch {
        Write-Warning "Failed to retrieve SQL Servers: $($_.Exception.Message)"
    }
} else {
    Write-Output "SQL_SERVER_NAME already set to '$sqlServerName'. Skipping retrieval of SQL server."
}
if( -not $sqlServerName ) {
    Write-Error "SQL_SERVER_NAME not found in azd environment and no SQL Server could be located. Please ensure you have a SQL Server deployed in the resource group."
    exit 1
}

## ---------------------------------------------------------------------------
## Acquire Azure AD access token for SQL (scope: https://database.windows.net/.default)
## Primary execution path uses ADO.NET with AccessToken (sqlcmd removed)
## ---------------------------------------------------------------------------
function Convert-SecureIfNeededToPlainText {
    param(
        [Parameter(Mandatory)] $Value
    )
    if ($Value -is [System.Security.SecureString]) {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Value)
        try { return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
    }
    return $Value
}

try {
    $rawToken = (Get-AzAccessToken -ResourceUrl 'https://database.windows.net/').Token
    if (-not $rawToken) { throw 'Access token empty' }
    $sqlToken = Convert-SecureIfNeededToPlainText -Value $rawToken
    if (-not ($sqlToken -is [string])) { $sqlToken = [string]$sqlToken }
    Write-Output 'Obtained Azure AD access token for SQL.'
}
catch {
    Write-Error "Failed to obtain Azure AD access token: $($_.Exception.Message). Cannot proceed with database role assignments without token."
    exit 1
}

# -----------------------------------------------------------------------------
# Execute T-SQL to create external user mapped to Managed Identity and grant roles (simplified idempotent)
# -----------------------------------------------------------------------------

$escapedIdentityName = $ManagedIdentityName -replace ']', ']]'

$tsql = @"
-- Create external user if missing
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$escapedIdentityName')
BEGIN
    PRINT 'Creating external user [$escapedIdentityName]';
    CREATE USER [$escapedIdentityName] FROM EXTERNAL PROVIDER;
END
ELSE
BEGIN
    PRINT 'User [$escapedIdentityName] already exists – skipping create.';
END

-- Grant roles only if not already a member
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members drm
    JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
    JOIN sys.database_principals u ON drm.member_principal_id = u.principal_id
    WHERE r.name = 'db_datareader' AND u.name = '$escapedIdentityName')
BEGIN
    PRINT 'Adding user [$escapedIdentityName] to role db_datareader';
    ALTER ROLE [db_datareader] ADD MEMBER [$escapedIdentityName];
END
ELSE PRINT 'User already in role db_datareader – skipping.';

IF NOT EXISTS (SELECT 1 FROM sys.database_role_members drm
    JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
    JOIN sys.database_principals u ON drm.member_principal_id = u.principal_id
    WHERE r.name = 'db_datawriter' AND u.name = '$escapedIdentityName')
BEGIN
    PRINT 'Adding user [$escapedIdentityName] to role db_datawriter';
    ALTER ROLE [db_datawriter] ADD MEMBER [$escapedIdentityName];
END
ELSE PRINT 'User already in role db_datawriter – skipping.';

IF NOT EXISTS (SELECT 1 FROM sys.database_role_members drm
    JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
    JOIN sys.database_principals u ON drm.member_principal_id = u.principal_id
    WHERE r.name = 'db_ddladmin' AND u.name = '$escapedIdentityName')
BEGIN
    PRINT 'Adding user [$escapedIdentityName] to role db_ddladmin';
    ALTER ROLE [db_ddladmin] ADD MEMBER [$escapedIdentityName];
END
ELSE PRINT 'User already in role db_ddladmin – skipping.';
"@

Write-Output "Applying (idempotent) database role assignments for managed identity '$ManagedIdentityName' on database '$sqlDatabaseName'..."

# server FQDN
$serverFqdn = "$sqlServerName.database.windows.net"

try {
    $connectionString = "Server=$serverFqdn;Database=$sqlDatabaseName;Encrypt=True;TrustServerCertificate=False;";
    $connType = [System.Type]::GetType('Microsoft.Data.SqlClient.SqlConnection, Microsoft.Data.SqlClient')
    if (-not $connType) { $connType = [System.Data.SqlClient.SqlConnection] }
    $conn = [Activator]::CreateInstance($connType, $connectionString)
    $accessTokenProp = $connType.GetProperty('AccessToken')
    if (-not $accessTokenProp) { throw 'Current SQL client library does not expose AccessToken property; install Microsoft.Data.SqlClient package.' }
    # Ensure token is a plain string (some environments may still hand back SecureString)
    $plainToken = Convert-SecureIfNeededToPlainText -Value $sqlToken
    $accessTokenProp.SetValue($conn, $plainToken)
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $tsql
    $null = $cmd.ExecuteNonQuery()
    Write-Output "Successfully ensured user and role memberships for '$ManagedIdentityName'."

    # ---------------------------------------------------------------------
    # Create 'todo' table if it does not exist (idempotent)
    # Note: Azure SQL does not yet have a native JSON column type; using NVARCHAR(MAX)
    # with an ISJSON() CHECK constraint to approximate JSON enforcement.
    # ---------------------------------------------------------------------
    $tableSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE t.name = 'todo' AND s.name = 'dbo')
BEGIN
    PRINT 'Creating table dbo.todo';
    CREATE TABLE dbo.todo (
        id INT IDENTITY(1,1) PRIMARY KEY,
        name NVARCHAR(100) NOT NULL,
        recommendations_json NVARCHAR(MAX) NULL,
        notes NVARCHAR(100) NULL,
        priority INT NOT NULL CONSTRAINT DF_todo_priority DEFAULT(0),
        completed BIT NOT NULL CONSTRAINT DF_todo_completed DEFAULT(0),
        due_date NVARCHAR(50) NULL,
        oid NVARCHAR(50) NULL,
        CONSTRAINT CK_todo_recommendations_json_isjson CHECK (recommendations_json IS NULL OR ISJSON(recommendations_json)=1)
    );
END
ELSE
BEGIN
    PRINT 'Table dbo.todo already exists – skipping create.';
END
"@
    $cmd.CommandText = $tableSql
    $null = $cmd.ExecuteNonQuery()
    $conn.Close()
    Write-Output "Verified existence of table dbo.todo."
}
catch {
    Write-Error "Failed to execute T-SQL for managed identity via ADO.NET: $($_.Exception.Message)"
    exit 1
}
