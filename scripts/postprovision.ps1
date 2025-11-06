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

# Get tenant ID from azd environment (trim to avoid stray newlines)
$tenantId = (azd env get-value 'TENANT_ID' 2>$null).Trim()

# Get SQL database name from azd environment, default to 'todo' if not found
$sqlDatabaseName = (azd env get-value 'SQL_DATABASE_NAME' 2>$null).Trim()
if ($sqlDatabaseName -ceq "ERROR: key 'SQL_DATABASE_NAME' not found in the environment values" -or [string]::IsNullOrWhiteSpace($sqlDatabaseName)) {
    $sqlDatabaseName = 'todo'
} else {
    Write-Output "Using SQL database name: '$sqlDatabaseName'"
}

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
# Load and execute T-SQL to create external user mapped to Managed Identity and grant roles
# -----------------------------------------------------------------------------

$escapedIdentityName = $ManagedIdentityName -replace ']', ']]'

# Load SQL script from file
$roleAssignmentSqlPath = Join-Path $PSScriptRoot 'assign-database-roles.sql'
if (-not (Test-Path $roleAssignmentSqlPath)) {
    Write-Error "SQL script not found: $roleAssignmentSqlPath"
    exit 1
}

$tsql = Get-Content -Path $roleAssignmentSqlPath -Raw
# Replace placeholder with actual identity name
$tsql = $tsql -replace '\{\{IDENTITY_NAME\}\}', $escapedIdentityName

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
    # Load and execute SQL to create table(s)
    # ---------------------------------------------------------------------
    $createTableSqlPath = Join-Path $PSScriptRoot 'create-tables.sql'
    if (-not (Test-Path $createTableSqlPath)) {
        Write-Error "SQL script not found: $createTableSqlPath"
        $conn.Close()
        exit 1
    }

    $tableSql = Get-Content -Path $createTableSqlPath -Raw
    $cmd.CommandText = $tableSql
    $null = $cmd.ExecuteNonQuery()
    $conn.Close()
    Write-Output "Created tables."
}
catch {
    Write-Error "Failed to execute T-SQL for managed identity via ADO.NET: $($_.Exception.Message)"
    exit 1
}
