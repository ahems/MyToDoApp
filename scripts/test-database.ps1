param(
        [string]$SqlServerName = 'todoapp-sql-3mrfbd7o3rv4u.database.windows.net',
        [string]$DatabaseName = 'todo',
        [switch]$ShowSql,
        [switch]$DeployEphemeralContainer,   # When set, create a temporary Container App in the same environment to run the tests with UAMI
        [switch]$KeepEphemeralContainer      # Preserve the ephemeral Container App instead of deleting it
)

<#
SUMMARY
    This script can run the SQL permission tests locally (using the current principal / managed identity if inside Azure)
    OR create a short‑lived Container App in the same Container Apps Environment to exercise the User Assigned Managed Identity (UAMI)
    from an isolated container. This is useful as a postprovision hook to validate that the UAMI can access the SQL database.

USAGE (postprovision hook example)
    pwsh ./scripts/test-database.ps1 -DeployEphemeralContainer

NOTES
    * Requires Azure CLI (az) and appropriate RBAC (Contributor or ContainerApp Writer + Identity Reader) when creating the ephemeral app.
    * Ephemeral container image: mcr.microsoft.com/powershell:lts-debian-11
    * Installs Az.Accounts + Microsoft.Data.SqlClient runtime in ephemeral container to run T-SQL tests.
    * By default deletes the ephemeral container after log collection unless -KeepEphemeralContainer is specified.
#>

if ($DeployEphemeralContainer) {
        Write-Host "[Mode] Ephemeral Container App validation enabled" -ForegroundColor Cyan
        # Gather environment values
        $resourceGroupName = (azd env get-value 'AZURE_RESOURCE_GROUP' 2>$null).Trim()
        if (-not $resourceGroupName -or $resourceGroupName -match '^ERROR:') {
                Write-Error "AZURE_RESOURCE_GROUP not found in azd environment."; exit 1
        }
        $uamiName = (azd env get-value 'USER_MANAGED_IDENTITY_NAME' 2>$null).Trim()
        if (-not $uamiName -or $uamiName -match '^ERROR:') {
                Write-Error "USER_MANAGED_IDENTITY_NAME not found in azd environment. Ensure provisioning completed."; exit 1
        }
        $rawSqlServerName = (azd env get-value 'SQL_SERVER_NAME' 2>$null).Trim()
        if (-not $rawSqlServerName -or $rawSqlServerName -match '^ERROR:') {
                Write-Error "SQL_SERVER_NAME not found in azd environment."; exit 1
        }
        # rawSqlServerName is usually the short name without FQDN. Normalize to short name
        if ($rawSqlServerName -like '*.database.windows.net') { $shortSqlServer = $rawSqlServerName.Split('.')[0] } else { $shortSqlServer = $rawSqlServerName }

        Write-Host "Resource Group: $resourceGroupName" -ForegroundColor DarkCyan
        Write-Host "User Assigned Managed Identity: $uamiName" -ForegroundColor DarkCyan
        Write-Host "SQL Server (short): $shortSqlServer" -ForegroundColor DarkCyan

        # Resolve identity resource id
        $uamiId = az identity show -g $resourceGroupName -n $uamiName --query id -o tsv 2>$null
        if (-not $uamiId) { Write-Error "Failed to resolve user-assigned identity $uamiName"; exit 1 }

        # Resolve Container Apps Environment (assume single in RG or pick first)
        $envName = az containerapp env list -g $resourceGroupName --query '[0].name' -o tsv 2>$null
        if (-not $envName) { Write-Error "Could not determine Container Apps Environment name in RG $resourceGroupName"; exit 1 }
        Write-Host "Container Apps Environment: $envName" -ForegroundColor DarkCyan

        $jobOrAppName = "sql-mi-test-$(Get-Random -Maximum 99999)"  # unique-ish
        Write-Host "Ephemeral test Container App name: $jobOrAppName" -ForegroundColor DarkCyan

        # Inline PowerShell test script executed inside the ephemeral container
        $innerScript = @'
Set-StrictMode -Version Latest
Write-Host "==> Starting Managed Identity SQL permission validation inside ephemeral container" -ForegroundColor Cyan
function Install-ModulesIfNeeded {
    try {
        if (-not (Get-Module -ListAvailable -Name Az.Accounts)) { Install-Module Az.Accounts -Force -Scope CurrentUser -Confirm:$false }
    } catch { Write-Warning "Az.Accounts install failed: $($_.Exception.Message)" }
    try {
        if (-not (Get-Module -ListAvailable -Name Az.Sql)) { Install-Module Az.Sql -Force -Scope CurrentUser -Confirm:$false }
    } catch { Write-Warning "Az.Sql install failed: $($_.Exception.Message)" }
}
Install-ModulesIfNeeded

$sqlServerShort = $env:SQL_SERVER_SHORT
if (-not $sqlServerShort) { Write-Error 'SQL_SERVER_SHORT env var missing'; exit 2 }
$dbName = $env:SQL_DATABASE_NAME
if (-not $dbName) { $dbName = 'todo' }
$fqdn = "$sqlServerShort.database.windows.net"
Write-Host "Target SQL: $fqdn (DB: $dbName)" -ForegroundColor Cyan

try {
    $token = (Get-AzAccessToken -ResourceUrl 'https://database.windows.net/').Token
    if (-not $token) { throw 'Empty access token' }
    Write-Host 'Obtained AAD access token via Managed Identity.' -ForegroundColor Green
} catch {
    Write-Error "Failed to obtain MI SQL access token: $($_.Exception.Message)"; exit 3
}

$clientType = [Type]::GetType('Microsoft.Data.SqlClient.SqlConnection, Microsoft.Data.SqlClient')
if (-not $clientType) { $clientType = [Type]::GetType('System.Data.SqlClient.SqlConnection, System.Data') }
if (-not $clientType) { Write-Error 'No SQL client available.'; exit 4 }
$connStr = "Server=$fqdn;Database=$dbName;Encrypt=True;TrustServerCertificate=False;"
$conn = [Activator]::CreateInstance($clientType, $connStr)
$prop = $clientType.GetProperty('AccessToken')
if (-not $prop) { Write-Error 'SQL client missing AccessToken property'; exit 5 }
$prop.SetValue($conn, $token)
try { $conn.Open(); Write-Host 'SQL connection (token based) succeeded.' -ForegroundColor Green } catch { Write-Error "Connection failed: $($_.Exception.Message)"; exit 6 }

function ExecSql($label, $sql){
    Write-Host "-- $label" -ForegroundColor Yellow
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql
    try { $r = $cmd.ExecuteReader(); $tbl = New-Object System.Data.DataTable; $tbl.Load($r); $tbl | Format-Table -AutoSize } catch { Write-Error "[$label] failed: $($_.Exception.Message)" }
}

ExecSql 'Check table' @"\nIF OBJECT_ID('dbo.todo') IS NULL SELECT 'NOT FOUND' AS Status ELSE SELECT 'FOUND' AS Status, COUNT(*) AS RowCount FROM dbo.todo;\n"@
ExecSql 'Insert probe' "INSERT INTO dbo.todo (name, notes, priority, completed) OUTPUT INSERTED.id, INSERTED.name VALUES ('__mi_probe__','ephemeral',1,0);"
ExecSql 'Update probe (latest)' @"\nDECLARE @id INT = (SELECT TOP (1) id FROM dbo.todo WHERE name='__mi_probe__' ORDER BY id DESC);\nIF @id IS NOT NULL BEGIN UPDATE dbo.todo SET notes='ephemeral-updated', completed=1 WHERE id=@id; SELECT id,name,notes,completed FROM dbo.todo WHERE id=@id; END ELSE SELECT 'No probe row' AS Info;\n"@
ExecSql 'Delete probe' "DELETE FROM dbo.todo WHERE name='__mi_probe__'; SELECT 'Cleanup complete' AS Info;"

try { $conn.Close() } catch {}
Write-Host '==> Ephemeral MI SQL validation complete' -ForegroundColor Cyan
'@

        # Base64 encode the inner script to avoid shell escaping issues
        $innerScriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($innerScript))

            Write-Host "Creating ephemeral Container App '$jobOrAppName'..." -ForegroundColor Cyan
            # Build argument list for az CLI properly (first token is the executable, remainder are arguments)
            # IMPORTANT: In current az containerapp create, '--command' passes the container entrypoint, and '--args' passes arguments.
            # We avoid using '-c' inline because az treats it as an unrecognized top-level argument when placed after --command pwsh.
            # Strategy: supply pwsh as --command, and as first arg run a one-liner that reconstructs the script.
            $pwshOneLiner = "[System.IO.File]::WriteAllBytes('/tmp/run.b64',[Convert]::FromBase64String('$innerScriptB64'));" +
                             "[IO.File]::WriteAllText('/tmp/run.ps1',[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$innerScriptB64')));" +
                             "pwsh -File /tmp/run.ps1; while($true){ Start-Sleep 300 }"
            $createArgs = @(
                'containerapp','create',
                '-g', $resourceGroupName,
                '-n', $jobOrAppName,
                '--environment', $envName,
                '--image','mcr.microsoft.com/powershell:lts-debian-11',
                '--cpu','0.25','--memory','0.5Gi',
                '--user-assigned', $uamiId,
                '--ingress','internal',
                '--min-replicas','1','--max-replicas','1',
                '--revision-suffix','mi-test',
                '--env-vars',"SQL_SERVER_SHORT=$shortSqlServer","SQL_DATABASE_NAME=$DatabaseName",
                '--command','pwsh',
                '--args',"-NoLogo","-NoProfile","-Command","$pwshOneLiner"
            )
            Write-Host ("az " + ($createArgs -join ' ')) -ForegroundColor DarkGray
            $createOutput = & az @createArgs 2>&1
            $createOutput | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -ne 0) { Write-Error "Failed creating ephemeral Container App (exit code $LASTEXITCODE)."; exit 1 }

            if ($createOutput -match 'unrecognized arguments') {
                Write-Warning "It looks like the CLI still rejected arguments. You can try simplifying: remove the while loop, or switch to a Container App Job (az containerapp job create --replica-timeout 600 --image ... --command pwsh --args -File run.ps1). If you want I can auto-convert this to a job variant." 
            }

        Write-Host "Waiting for logs (initial warm-up ~15-45s)..." -ForegroundColor Cyan
        Start-Sleep -Seconds 20
        $attempts = 0
        while ($attempts -lt 6) {
                & az containerapp logs show -g $resourceGroupName -n $jobOrAppName --tail 200 2>$null
                $attempts++
                if ($attempts -lt 6) { Start-Sleep -Seconds 10 }
        }

        if (-not $KeepEphemeralContainer) {
                Write-Host "Deleting ephemeral Container App '$jobOrAppName'..." -ForegroundColor Cyan
                az containerapp delete -g $resourceGroupName -n $jobOrAppName -y 2>$null | Out-Null
        } else {
                Write-Host "Keeping ephemeral Container App '$jobOrAppName' as requested." -ForegroundColor Yellow
        }

        Write-Host "Ephemeral test complete." -ForegroundColor Green
        exit 0
}

# Helper: write a banner
function Write-Step($msg){ Write-Host "==> $msg" -ForegroundColor Cyan }

# If values not supplied, try azd env
if (-not $SqlServerName) {
    try {
        $SqlServerName = (azd env get-value 'SQL_SERVER_NAME' 2>$null).Trim()
        if ($SqlServerName -match '^ERROR:') { $SqlServerName = $null }
    } catch {}
}
if (-not $SqlServerName) {
    Write-Error "SqlServerName not provided and not found in azd environment."
    exit 1
}

$Fqdn = "$SqlServerName.database.windows.net"

Write-Step "Acquiring access token for https://database.windows.net/ (Managed Identity or current principal)"
try {
    $token = (Get-AzAccessToken -ResourceUrl 'https://database.windows.net/').Token
} catch {
    Write-Error "Failed to get access token: $($_.Exception.Message)"
    exit 1
}

# Load client
$clientType = [Type]::GetType('Microsoft.Data.SqlClient.SqlConnection, Microsoft.Data.SqlClient')
if (-not $clientType) { $clientType = [Type]::GetType('System.Data.SqlClient.SqlConnection, System.Data') }

if (-not $clientType) {
    Write-Error "Could not load a SQL client class. Install Microsoft.Data.SqlClient."
    exit 1
}

$connectionString = "Server=$Fqdn;Database=$DatabaseName;Encrypt=True;TrustServerCertificate=False;"
$conn = [Activator]::CreateInstance($clientType, $connectionString)
$accessTokenProp = $clientType.GetProperty('AccessToken')
if (-not $accessTokenProp) {
    Write-Error "The SQL client in use does not expose an AccessToken property."
    exit 1
}
$accessTokenProp.SetValue($conn, $token)

function Invoke-TestSql {
    param(
        [Parameter(Mandatory)] [string]$Label,
        [Parameter(Mandatory)] [string]$Sql
    )
    Write-Step $Label
    if ($ShowSql) { Write-Host $Sql -ForegroundColor DarkGray }
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $Sql
    try {
        $adapterType = [Type]::GetType('Microsoft.Data.SqlClient.SqlDataAdapter, Microsoft.Data.SqlClient')
        if (-not $adapterType) { $adapterType = [Type]::GetType('System.Data.SqlClient.SqlDataAdapter, System.Data') }
        $ds = New-Object System.Data.DataSet
        $adapter = [Activator]::CreateInstance($adapterType, $cmd)
        [void]$adapter.Fill($ds)
        if ($ds.Tables.Count -gt 0) {
            $ds.Tables | ForEach-Object { $_ | Format-Table -AutoSize }
        } else {
            Write-Host "(No rowset returned)"
        }
    }
    catch {
        Write-Error "Failed during [$Label]: $($_.Exception.Message)"
        throw
    }
}

try {
    $conn.Open()

    # 1. Basic SELECT (should succeed if user has at least SELECT on table via db_datareader)
    Invoke-TestSql -Label "Check table existence & row count" -Sql @"
IF OBJECT_ID('dbo.todo') IS NULL
    SELECT 'dbo.todo NOT FOUND' AS Status;
ELSE
    SELECT 'dbo.todo FOUND' AS Status, COUNT(*) AS RowCount FROM dbo.todo;
"@

    # 2. INSERT (requires INSERT privilege -> db_datawriter)
    Invoke-TestSql -Label "Insert probe row" -Sql @"
INSERT INTO dbo.todo (name, notes, priority, completed) 
OUTPUT INSERTED.id, INSERTED.name, INSERTED.priority, INSERTED.completed
VALUES ('__mi_probe__', 'perm test', 1, 0);
"@

    # Capture inserted id
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT TOP (1) id FROM dbo.todo WHERE name='__mi_probe__' ORDER BY id DESC;"
    $probeId = $cmd.ExecuteScalar()

    if (-not $probeId) {
        Write-Warning "Probe row not found after insert."
    } else {
        Write-Host "Probe row id = $probeId"
    }

    # 3. UPDATE
    Invoke-TestSql -Label "Update probe row" -Sql @"
UPDATE dbo.todo SET notes='updated perm test', completed=1 WHERE id = $probeId;
SELECT id, name, notes, completed FROM dbo.todo WHERE id = $probeId;
"@

    # 4. DDL (optional) create/drop index if role db_ddladmin is granted
    Invoke-TestSql -Label "Create index (if not exists)" -Sql @"
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_todo_completed')
BEGIN
    CREATE INDEX IX_todo_completed ON dbo.todo(completed, id);
    SELECT 'Created IX_todo_completed' AS Action;
END
ELSE
    SELECT 'IX_todo_completed already exists' AS Action;
"@

    # 5. DELETE probe row (cleanup)
    Invoke-TestSql -Label "Delete probe row" -Sql @"
DELETE FROM dbo.todo WHERE id = $probeId;
SELECT 'Deleted row id = $probeId' AS CleanupStatus;
"@

    # 6. Optional: Drop index (leave it if you prefer)
    Invoke-TestSql -Label "Drop index (cleanup)" -Sql @"
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_todo_completed')
BEGIN
    DROP INDEX IX_todo_completed ON dbo.todo;
    SELECT 'Dropped IX_todo_completed' AS Action;
END
ELSE
    SELECT 'IX_todo_completed not present for drop' AS Action;
"@
}
finally {
    if ($conn.State -eq 'Open') { $conn.Close() }
    $conn.Dispose()
}

Write-Host "`nAll tests executed. Review any errors above."