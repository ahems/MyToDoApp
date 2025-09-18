Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "[dbtest] Starting managed identity database validation" -ForegroundColor Cyan

# Environment variables expected (can be injected via Container Apps):
#   SQL_SERVER_NAME (short name or FQDN w/o protocol)
#   SQL_DATABASE_NAME (default: todo)
#   DB_TABLE (default: dbo.todo)
#   LOG_VERBOSITY (Quiet|Normal|Debug)

function Get-EnvOrDefault {
  param([string]$Name, [string]$Default)
  $v = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($v)) { return $Default } else { return $v }
}

$serverInput   = Get-EnvOrDefault -Name 'SQL_SERVER_NAME' -Default ''
if (-not $serverInput) { Write-Error "SQL_SERVER_NAME env var is required"; exit 10 }
if ($serverInput -like '*.database.windows.net') { $shortServer = $serverInput.Split('.')[0] } else { $shortServer = $serverInput }
$fqdn = "$shortServer.database.windows.net"

$dbName        = Get-EnvOrDefault -Name 'SQL_DATABASE_NAME' -Default 'todo'
$tableName     = Get-EnvOrDefault -Name 'DB_TABLE' -Default 'dbo.todo'
$verbosity     = Get-EnvOrDefault -Name 'LOG_VERBOSITY' -Default 'Normal'

Write-Host "[dbtest] Target server: $fqdn / database: $dbName / table: $tableName" -ForegroundColor DarkCyan

# Acquire token using Managed Identity via IMDS (no Az modules required)
Write-Host "[dbtest] Acquiring access token for https://database.windows.net/ (Managed Identity)" -ForegroundColor Cyan
function Get-MiAccessToken {
  param([Parameter(Mandatory)][string]$Resource,[int]$Retries=3)
  $clientId = [Environment]::GetEnvironmentVariable('AZURE_CLIENT_ID')
  $hasAppSvcEndpoint = -not [string]::IsNullOrWhiteSpace($env:IDENTITY_ENDPOINT) -and -not [string]::IsNullOrWhiteSpace($env:IDENTITY_HEADER)
  function Write-Dbg([string]$m){ if ($script:verbosity -eq 'Debug') { Write-Host "[debug] $m" -ForegroundColor DarkGray } }

  # Initial delay to give Managed Identity time to warm up after container start
  $initialDelayEnv = [Environment]::GetEnvironmentVariable('MI_INITIAL_DELAY_SECONDS')
  $initialDelay = 0
  if ($initialDelayEnv -and [int]::TryParse($initialDelayEnv, [ref]$null)) { $initialDelay = [int]$initialDelayEnv } else { $initialDelay = 15 }
  if ($initialDelay -gt 0) {
    Write-Host ("[dbtest] Waiting {0}s before first token attempt to allow Managed Identity to initialize..." -f $initialDelay) -ForegroundColor DarkGray
    Start-Sleep -Seconds $initialDelay
  }

  if ([string]::IsNullOrWhiteSpace($clientId)) {
    Write-Warning "[dbtest] AZURE_CLIENT_ID not set. Using default identity selection for the environment."
  } else {
    Write-Host "[dbtest] Using user-assigned identity (AZURE_CLIENT_ID=$clientId) for token request." -ForegroundColor DarkCyan
  }

  for ($i=1; $i -le $Retries; $i++) {
    try {
      if ($hasAppSvcEndpoint) {
        # Container Apps / App Service endpoint (preferred when available)
        $base = $env:IDENTITY_ENDPOINT
        $qs = "resource={0}&api-version=2019-08-01" -f [System.Uri]::EscapeDataString($Resource)
        if (-not [string]::IsNullOrWhiteSpace($clientId)) { $qs += "&client_id={0}" -f [System.Uri]::EscapeDataString($clientId) }
        $url = "{0}?{1}" -f $base, $qs
        $headers = @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }
        Write-Host "[dbtest] Requesting token via IDENTITY_ENDPOINT." -ForegroundColor DarkGray
        $u = [System.Uri]$url
        $qKeys = ($u.Query.TrimStart('?').Split('&') | ForEach-Object { ($_ -split '=',2)[0] }) -join ','
        Write-Dbg ("Token URL host={0} path={1} queryKeys=[{2}]" -f $u.Host, $u.AbsolutePath, $qKeys)
        $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $headers -TimeoutSec 20
      } else {
        # IMDS fallback (AKS/ACI/VMs)
        $imds = 'http://169.254.169.254/metadata/identity/oauth2/token'
        $headers = @{ Metadata = 'true' }
        # Ensure no proxy intercepts the link-local IMDS call
        if ($env:NO_PROXY) { $env:NO_PROXY += ',169.254.169.254' } else { $env:NO_PROXY = '169.254.169.254' }
        Write-Dbg ("NO_PROXY set to: {0}" -f $env:NO_PROXY)
        $qs = @{
          'api-version' = '2019-08-01'
          'resource'    = $Resource
        }
        if (-not [string]::IsNullOrWhiteSpace($clientId)) { $qs['client_id'] = $clientId }
        $query = ($qs.GetEnumerator() | ForEach-Object { [System.String]::Format('{0}={1}',[System.Uri]::EscapeDataString($_.Key),[System.Uri]::EscapeDataString([string]$_.Value)) }) -join '&'
        $url = '{0}?{1}' -f $imds, $query
        Write-Host "[dbtest] Requesting token via IMDS." -ForegroundColor DarkGray
        $u = [System.Uri]$url
        $qKeys = ($u.Query.TrimStart('?').Split('&') | ForEach-Object { ($_ -split '=',2)[0] }) -join ','
        Write-Dbg ("Token URL host={0} path={1} queryKeys=[{2}]" -f $u.Host, $u.AbsolutePath, $qKeys)
        $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $headers -TimeoutSec 20
      }

      if ($resp.access_token) {
        Write-Dbg ("Token response fields: {0}" -f (($resp.PSObject.Properties.Name -join ', ')))
        return $resp.access_token
      }
      throw "No access_token field in token response."
    } catch {
      $status = $null
      try { if ($_.Exception.Response) { $status = $_.Exception.Response.StatusCode.value__ } } catch {}
      if ($i -ge $Retries) { throw }
      Write-Warning ("[dbtest] Token request failed (attempt {0}){1}: {2}. Retrying..." -f $i, ($status ? " [HTTP $status]" : ''), $_.Exception.Message)
      Start-Sleep -Seconds ([int][Math]::Pow(2,$i))
    }
  }
}

try {
  $token = Get-MiAccessToken -Resource 'https://database.windows.net/'
  if (-not $token) { throw 'Empty token from IMDS' }
  Write-Host "[dbtest] Access token obtained." -ForegroundColor Green
} catch {
  Write-Error "[dbtest] Failed to obtain MI token via IMDS: $($_.Exception.Message)"; exit 11
}

# Load SQL client (prefer Microsoft.Data.SqlClient, fallback to System.Data.SqlClient)
function Get-SqlClientType {
  try { return [Type]::GetType('Microsoft.Data.SqlClient.SqlConnection, Microsoft.Data.SqlClient', $false) } catch { }
  try { Add-Type -AssemblyName 'Microsoft.Data.SqlClient' -ErrorAction SilentlyContinue | Out-Null; return [Microsoft.Data.SqlClient.SqlConnection] } catch { }
  try { return [Type]::GetType('System.Data.SqlClient.SqlConnection, System.Data', $false) } catch { }
  try { Add-Type -AssemblyName 'System.Data' -ErrorAction SilentlyContinue | Out-Null; return [System.Data.SqlClient.SqlConnection] } catch { }
  return $null
}
$clientType = Get-SqlClientType
if (-not $clientType) {
  Write-Error '[dbtest] No SQL client assembly available (Microsoft.Data.SqlClient or System.Data.SqlClient). Consider adding Microsoft.Data.SqlClient to the image.'
  exit 12
}

$connStr = "Server=$fqdn;Database=$dbName;Encrypt=True;TrustServerCertificate=False;"
$conn = [Activator]::CreateInstance($clientType, $connStr)
$accessTokenProp = $clientType.GetProperty('AccessToken')
if ($accessTokenProp) {
  $accessTokenProp.SetValue($conn, $token)
} else {
  # Some older clients don’t expose AccessToken; try using IntegratedSecurity/Authentication keyword path
  # Note: This path may not work with UAMI tokens; prefer Microsoft.Data.SqlClient when possible
  Write-Warning '[dbtest] SQL client type does not expose AccessToken; attempting connection with Authentication=Active Directory Access Token.'
  try {
    $conn.Close() | Out-Null
  } catch {}
  $connStr = "Server=$fqdn;Database=$dbName;Encrypt=True;TrustServerCertificate=False;Authentication=Active Directory Access Token;"
  $conn = [Activator]::CreateInstance($clientType, $connStr)
  # Try to set AccessToken via dynamic since property wasn’t discovered earlier
  try { $conn.AccessToken = $token } catch { Write-Error '[dbtest] Unable to set AccessToken on SQL client; install Microsoft.Data.SqlClient in the image.'; exit 13 }
}

try { $conn.Open(); Write-Host '[dbtest] SQL connection succeeded.' -ForegroundColor Green } catch { Write-Error "[dbtest] SQL connection failed: $($_.Exception.Message)"; exit 14 }

function Invoke-SqlScalar {
  param([string]$Sql)
  $cmd = $conn.CreateCommand(); $cmd.CommandText = $Sql; return $cmd.ExecuteScalar()
}
function Invoke-SqlNonQuery {
  param([string]$Sql)
  $cmd = $conn.CreateCommand(); $cmd.CommandText = $Sql; [void]$cmd.ExecuteNonQuery()
}
function Invoke-SqlTable {
  param([string]$Sql)
  $cmd = $conn.CreateCommand(); $cmd.CommandText = $Sql; $r = $cmd.ExecuteReader(); $t = New-Object System.Data.DataTable; $t.Load($r); return $t
}

function Write-DebugLog {
  param([string]$Message)
  if ($verbosity -eq 'Debug'){ Write-Host "[debug] $Message" -ForegroundColor DarkGray }
}

Write-Host "[dbtest] Verifying table existence: $tableName" -ForegroundColor Cyan
$tableExists = Invoke-SqlScalar -Sql "SELECT CASE WHEN OBJECT_ID('$tableName') IS NULL THEN 0 ELSE 1 END"
if ($tableExists -ne 1) { Write-Warning "[dbtest] Table $tableName not found." } else { Write-Host "[dbtest] Table $tableName exists." -ForegroundColor Green }

# Insert probe row
Write-Host "[dbtest] Inserting probe row" -ForegroundColor Cyan
Invoke-SqlNonQuery -Sql "INSERT INTO $tableName (name, notes, priority, completed) VALUES ('__mi_probe__','from test container',1,0);"
$probeId = Invoke-SqlScalar -Sql "SELECT TOP (1) id FROM $tableName WHERE name='__mi_probe__' ORDER BY id DESC;"
Write-Host "[dbtest] Probe row id: $probeId" -ForegroundColor DarkCyan

# Update probe
Write-Host "[dbtest] Updating probe row" -ForegroundColor Cyan
Invoke-SqlNonQuery -Sql "UPDATE $tableName SET notes='updated from test container', completed=1 WHERE id=$probeId;"
$row = Invoke-SqlTable -Sql "SELECT id,name,notes,priority,completed FROM $tableName WHERE id=$probeId;"
$row | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host "[row] $_" }

# DDL attempt (index) to validate db_ddladmin
Write-Host "[dbtest] Creating index attempt (IX_todo_completed)" -ForegroundColor Cyan
try {
  Invoke-SqlNonQuery -Sql "IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_todo_completed') CREATE INDEX IX_todo_completed ON $tableName(completed,id);"
  Write-Host "[dbtest] Index create succeeded or already existed." -ForegroundColor Green
} catch { Write-Warning "[dbtest] Index create failed (likely missing db_ddladmin): $($_.Exception.Message)" }

# Delete probe
Write-Host "[dbtest] Deleting probe row" -ForegroundColor Cyan
Invoke-SqlNonQuery -Sql "DELETE FROM $tableName WHERE id=$probeId;"

# Optional: Drop index (cleanup)
try {
  Invoke-SqlNonQuery -Sql "IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_todo_completed') DROP INDEX IX_todo_completed ON $tableName;"
  Write-Host "[dbtest] Index drop (cleanup) done." -ForegroundColor DarkGray
} catch { Write-Warning "[dbtest] Index drop failed: $($_.Exception.Message)" }

# Final row count
$rowCount = Invoke-SqlScalar -Sql "SELECT COUNT(*) FROM $tableName;"
Write-Host ("[dbtest] Final row count in {0}: {1}" -f $tableName,$rowCount) -ForegroundColor Cyan

# Roles insight (if permitted)
Write-Host "[dbtest] Enumerating current database roles for this principal (if permitted)" -ForegroundColor Cyan
try {
  # Use USER_NAME() for current database principal; more reliable for contained users and MI
  $rolesResult = Invoke-SqlTable -Sql "SELECT r.name AS RoleName FROM sys.database_role_members drm JOIN sys.database_principals r ON drm.role_principal_id=r.principal_id JOIN sys.database_principals m ON drm.member_principal_id=m.principal_id WHERE m.name = USER_NAME();"
  if ($rolesResult -is [System.Data.DataTable]) {
    if ($rolesResult.Rows.Count -gt 0) {
      $rolesResult | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host "[role] $_" }
    } else {
      Write-Host "[dbtest] No roles enumerated (permission or mapping issue)."
    }
  } elseif ($null -eq $rolesResult) {
    Write-Host "[dbtest] No roles enumerated (permission or mapping issue)."
  } else {
    $items = @($rolesResult)
    if ($items.Count -gt 0) {
      $items | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host "[role] $_" }
    } else {
      Write-Host "[dbtest] No roles enumerated (permission or mapping issue)."
    }
  }
} catch { Write-Warning "[dbtest] Could not enumerate roles: $($_.Exception.Message)" }

try { $conn.Close() } catch {}
Write-Host "[dbtest] Test sequence complete" -ForegroundColor Green

# Stay alive a short period so logs can be scraped then exit
Start-Sleep -Seconds 20
