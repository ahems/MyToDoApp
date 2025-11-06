Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
postup.ps1

Purpose:
  After 'azd up' (or other provisioning steps), pull selected values from the current
  azd environment and create/update a .env file at the project root for local debugging.

Behavior:
  - Reads existing .env (if any), updates or appends target keys, preserves other lines/comments.
  - Always sets IS_LOCALHOST=true (marker for local execution code paths).
  - Attempts to retrieve well-known keys via 'azd env get-value'. Missing keys are skipped.
  - Writes values quoted (single quotes) when they contain characters that commonly need protection.

Extending:
  Add new mappings to $desiredVariables list following existing pattern.
#>

function Get-AzdValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = ''
    )
    $raw = & azd env get-value $Name 2>&1
    $exit = $LASTEXITCODE
    if (-not $raw) { return $Default }
    $val = ($raw | Out-String).Trim()
    $ansiPattern = '^(?:\x1B\[[0-9;]*m)*'
    if ($exit -ne 0 -or
        $val -match ("${ansiPattern}\s*(?i:error:)") -or
        $val -match ("${ansiPattern}\s*(?i)key '?$Name'?'? not found") -or
        $val -match ("${ansiPattern}\s*(?i)no value found") ) {
        return $Default
    }
    return $val
}

function Quote-EnvValue {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -eq '') { return "" }
    # Always quote if contains whitespace, #, ;, :, = or starts with # or contains single quote.
    if ($Value -match "[\s#;:=]" -or $Value.StartsWith('#') -or $Value.Contains("'")) {
        $escaped = $Value -replace "'", "''"  # .env style: double single quotes inside single quotes.
        return "'$escaped'"
    }
    return $Value
}

function Parse-EnvFile {
    param([Parameter(Mandatory)][string]$Path)
    $result = @{}
    if (-not (Test-Path $Path)) { return $result }
    Get-Content -Raw -Path $Path -ErrorAction Stop | ForEach-Object { $_ -split "`n" } | ForEach-Object {
        $line = $_
        if ($line -match '^[ \t]*#') { return }
        if ($line -match '^[ \t]*$') { return }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { return }
        $k = $line.Substring(0,$eq).Trim()
        $v = $line.Substring($eq+1)
        $result[$k] = $v
    }
    return $result
}

function Update-EnvFile {
    param(
        [Parameter(Mandatory)][string]$EnvPath,
        [Parameter(Mandatory)][hashtable]$NewValues
    )
    $existingLines = @()
    $existingMap = @{}
    if (Test-Path $EnvPath) {
        $existingLines = Get-Content -Path $EnvPath -ErrorAction Stop
        # Build index of key -> line number for replacement
        for ($i=0; $i -lt $existingLines.Count; $i++) {
            $line = $existingLines[$i]
            if ($line -match '^[ \t]*#') { continue }
            $eq = $line.IndexOf('=')
            if ($eq -lt 1) { continue }
            $k = $line.Substring(0,$eq).Trim()
            if (-not [string]::IsNullOrWhiteSpace($k)) { $existingMap[$k] = $i }
        }
    }
    else {
        $existingLines = @()
    }

    foreach ($k in $NewValues.Keys) {
        $formatted = "$k=$($NewValues[$k])"
        if ($existingMap.ContainsKey($k)) {
            $existingLines[$existingMap[$k]] = $formatted
        } else {
            $existingLines += $formatted
        }
    }

    # Ensure file ends with newline for POSIX friendliness
    if ($existingLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($existingLines[-1])) {
        $existingLines += ''
    }
    Set-Content -Path $EnvPath -Value $existingLines -Encoding UTF8
}

# Determine project root (script is in ./scripts)
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$envFile = Join-Path $projectRoot '.env'

Write-Host "Generating/updating .env at $envFile" -ForegroundColor Cyan

# Desired variables mapping / retrieval logic
$desiredVariables = @(
    @{ Target='IS_LOCALHOST'; Static='true' },
    @{ Target='APPLICATIONINSIGHTS_CONNECTION_STRING'; Candidates=@('APPLICATIONINSIGHTS_CONNECTION_STRING') },
    @{ Target='REDIS_CONNECTION_STRING'; Candidates=@('REDIS_CONNECTION_STRING','REDIS_URL','REDIS_HOST') },
    @{ Target='AZURE_CLIENT_ID'; Candidates=@('AZURE_CLIENT_ID','CLIENT_ID') },
    @{ Target='KEY_VAULT_NAME'; Candidates=@('KEY_VAULT_NAME','AZURE_KEY_VAULT_NAME') },
    @{ Target='API_URL'; Candidates=@('API_URL','GRAPHQL_API_URL') }
)

$resolved = @{}
foreach ($entry in $desiredVariables) {
    $target = $entry.Target
    if ($entry.ContainsKey('Static')) {
        $resolved[$target] = Quote-EnvValue -Value $entry.Static
        continue
    }
    $val = ''
    foreach ($cand in $entry.Candidates) {
        $v = Get-AzdValue -Name $cand
        if ($v) { $val = $v; break }
    }
    if ($val) {
        $resolved[$target] = Quote-EnvValue -Value $val
    } else {
        Write-Host "Skipping $target (no candidate value found in azd env)" -ForegroundColor DarkYellow
    }
}

# Add REDIS_LOCAL_PRINCIPAL_ID using OBJECT_ID (if available) for local Redis AAD debugging
$objectIdValue = Get-AzdValue -Name 'OBJECT_ID'
if ($objectIdValue) {
    $resolved['REDIS_LOCAL_PRINCIPAL_ID'] = Quote-EnvValue -Value $objectIdValue
    Write-Host "Set REDIS_LOCAL_PRINCIPAL_ID from OBJECT_ID ($objectIdValue)" -ForegroundColor Cyan
} else {
    Write-Host "OBJECT_ID not found in azd env; skipping REDIS_LOCAL_PRINCIPAL_ID" -ForegroundColor DarkYellow
}

if ($resolved.Keys.Count -eq 0) {
    Write-Warning 'No variables resolved; .env not modified.'
    return
}

Update-EnvFile -EnvPath $envFile -NewValues $resolved
Write-Host '.env file updated.' -ForegroundColor Green