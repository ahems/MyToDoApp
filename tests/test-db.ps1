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

# Acquire token using Managed Identity (in Container Apps the UAMI must be attached)
Write-Host "[dbtest] Acquiring access token for https://database.windows.net/" -ForegroundColor Cyan
try {
  $token = (Get-AzAccessToken -ResourceUrl 'https://database.windows.net/').Token
  if (-not $token) { throw 'Empty token' }
  Write-Host "[dbtest] Access token obtained." -ForegroundColor Green
} catch {
  Write-Error "[dbtest] Failed to obtain MI token: $($_.Exception.Message)"; exit 11
}

# Load SQL client
$clientType = [Type]::GetType('Microsoft.Data.SqlClient.SqlConnection, Microsoft.Data.SqlClient')
if (-not $clientType) { $clientType = [Type]::GetType('System.Data.SqlClient.SqlConnection, System.Data') }
if (-not $clientType) { Write-Error '[dbtest] No SQL client assembly available'; exit 12 }

$connStr = "Server=$fqdn;Database=$dbName;Encrypt=True;TrustServerCertificate=False;"
$conn = [Activator]::CreateInstance($clientType, $connStr)
$accessTokenProp = $clientType.GetProperty('AccessToken')
if (-not $accessTokenProp) { Write-Error '[dbtest] SQL client lacks AccessToken property'; exit 13 }
$accessTokenProp.SetValue($conn, $token)

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
  $roles = Invoke-SqlTable -Sql "SELECT r.name AS RoleName FROM sys.database_role_members drm JOIN sys.database_principals r ON drm.role_principal_id=r.principal_id JOIN sys.database_principals m ON drm.member_principal_id=m.principal_id WHERE m.name = ORIGINAL_LOGIN();"
  if ($roles.Rows.Count -gt 0) { $roles | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host "[role] $_" } } else { Write-Host "[dbtest] No roles enumerated (permission or mapping issue)." }
} catch { Write-Warning "[dbtest] Could not enumerate roles: $($_.Exception.Message)" }

try { $conn.Close() } catch {}
Write-Host "[dbtest] Test sequence complete" -ForegroundColor Green

# Stay alive a short period so logs can be scraped then exit
Start-Sleep -Seconds 20
