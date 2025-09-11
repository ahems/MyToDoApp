<#
.SYNOPSIS
Pre-flight validation for Azure OpenAI model availability (PowerShell) using azd environment variables only.

.DESCRIPTION
This script is designed to be invoked as an azd preprovision hook (see azure.yaml). It reads all inputs from the current azd environment
using `azd env get-value` and writes selected outputs back with `azd env set` so Bicep parameters (matching names) can consume them.

INPUT ENV VARIABLES (attempted in this order with fallbacks):
    AZURE_SUBSCRIPTION_ID        (required)
    AZURE_RESOURCE_GROUP         (optional, derived if missing)
    AZURE_OPENAI_ACCOUNT_NAME    (optional; if missing will attempt discovery or create one)
    AZURE_LOCATION               (optional; defaults to canadaeast if missing)
    CHAT_GPT_MODEL_NAME          (optional; default gpt-5-mini)
    CHAT_GPT_PREFERRED_SKUS      (optional; comma list; default GlobalStandard,ProvisionedManaged,Standard)

OUTPUT ENV VARIABLES SET:
    chatGptDeploymentVersion     (picked version for deployment)
    chatGptSkuName               (picked SKU name)
    chatGptModelName             (echo of model name actually used)

If model discovery fails, script exits non-zero causing azd to stop before deployment.
#>

$ErrorActionPreference = 'Stop'

# --- Ensure required Az PowerShell modules are installed (auto-install) ---
function Ensure-PsGalleryTrusted {
    try {
        $r = Get-PSRepository -Name PSGallery -ErrorAction Stop
        if ($r.InstallationPolicy -ne 'Trusted') { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted }
    } catch {
        Register-PSRepository -Name PSGallery -SourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted
    }
}

function Ensure-Module {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$MinVersion
    )
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Host "Installing missing module: $Name" -ForegroundColor Yellow
        $installParams = @{ Name = $Name; Scope = 'CurrentUser'; Force = $true; AllowClobber = $true }
        if ($MinVersion) { $installParams['MinimumVersion'] = $MinVersion }
        Install-Module @installParams
    }
    Import-Module $Name -ErrorAction Stop | Out-Null
}

Ensure-PsGalleryTrusted
Ensure-Module -Name Az.Accounts -MinVersion '2.12.0'
Ensure-Module -Name Az.Resources
Ensure-Module -Name Az.CognitiveServices


function Get-AzdValue {
    param([Parameter(Mandatory)][string]$Name,[string]$Default='')
    $val = azd env get-value $Name 2>$null
    if (-not $val -or $val -match "^ERROR:") { return $Default }
    return $val.Trim()
}

# Retrieve inputs from azd env
$SubscriptionId = Get-AzdValue -Name 'AZURE_SUBSCRIPTION_ID'
if (-not $SubscriptionId) { throw 'AZURE_SUBSCRIPTION_ID not set in azd environment.' }

$ResourceGroup = Get-AzdValue -Name 'AZURE_RESOURCE_GROUP'
$EnvName = Get-AzdValue -Name 'AZURE_ENV_NAME'
if (-not $ResourceGroup) {
    if ($EnvName) { $ResourceGroup = "rg-$EnvName" } else { throw 'AZURE_RESOURCE_GROUP not set and AZURE_ENV_NAME unavailable to derive one.' }
}

$Location = Get-AzdValue -Name 'AZURE_LOCATION' -Default 'canadaeast'
$AccountName = Get-AzdValue -Name 'AZURE_OPENAI_ACCOUNT_NAME'

$ModelName = Get-AzdValue -Name 'CHAT_GPT_MODEL_NAME' -Default 'gpt-'
$PreferredSkuListRaw = Get-AzdValue -Name 'CHAT_GPT_PREFERRED_SKUS' -Default 'GlobalStandard,ProvisionedManaged,Standard'
$PreferredSkus = $PreferredSkuListRaw.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if (-not $PreferredSkus) { $PreferredSkus = @('GlobalStandard','ProvisionedManaged','Standard') }

Write-Host "Using values: Subscription=$SubscriptionId RG=$ResourceGroup Location=$Location ModelPrefix=$ModelName PreferredSKUs=$($PreferredSkus -join ',')"

# If account name absent attempt lightweight discovery or create deterministic default
if (-not $AccountName) {
    # Derive a deterministic account name (respect 64 char limit & allowed chars)
    $hash = ([System.BitConverter]::ToString((New-Guid).ToByteArray()) -replace '-','').Substring(0,8).ToLower()
    $AccountName = "todoapp-openai-$hash"
    Write-Host "Derived Azure OpenAI account name: $AccountName" -ForegroundColor Cyan
    azd env set AZURE_OPENAI_ACCOUNT_NAME $AccountName | Out-Null
}
else {
    $AccountName = $AccountName.Trim()
    Write-Host "Using existing Azure OpenAI account name from env: $AccountName" -ForegroundColor Cyan
}

function Ensure-AzLogin {
    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
            Write-Host "Logging in to Azure..."
            Connect-AzAccount -Subscription $SubscriptionId | Out-Null
    } elseif ((Get-AzContext).Subscription.Id -ne $SubscriptionId) {
            Set-AzContext -Subscription $SubscriptionId | Out-Null
    }
}

function Invoke-ModelsRequest {
    param([string]$SubId,[string]$Rg,[string]$Acct)
    $apiVersion = '2023-05-01'
    $url = "/subscriptions/$SubId/resourceGroups/$Rg/providers/Microsoft.CognitiveServices/accounts/$Acct/models?api-version=$apiVersion"
    if (-not (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue)) {
        throw 'Invoke-AzRestMethod not available. Please update Az.Accounts module.'
    }
    (Invoke-AzRestMethod -Path $url -Method GET).Content | ConvertFrom-Json
}

function Ensure-OpenAIAccount {
    param([string]$SubId,[string]$Rg,[string]$Acct,[string]$Loc)
    if ([string]::IsNullOrWhiteSpace($Acct)) { throw 'Ensure-OpenAIAccount received an empty account name ($Acct).' }
    $existingAcct = Get-AzCognitiveServicesAccount -Name $Acct -ResourceGroupName $Rg -ErrorAction SilentlyContinue
    if (-not $existingAcct) {
        Write-Host "Creating Azure OpenAI account '$Acct' in $Loc..."
        New-AzCognitiveServicesAccount `
            -ResourceGroupName $Rg `
            -Name $Acct `
            -Type 'OpenAI' `
            -SkuName 'S0' `
            -Location $Loc `
            -CustomSubDomainName $Acct `
            -Force | Out-Null
    } else {
        if ($existingAcct.Location -ne $Loc) {
            Write-Warning "Existing account is in region '$($existingAcct.Location)' not '$Loc'; continuing with existing region.";
            $script:Location = $existingAcct.Location
        }
    }
}

# --- Main Flow ---
Ensure-AzLogin
Ensure-OpenAIAccount -SubId $SubscriptionId -Rg $ResourceGroup -Acct $AccountName -Loc $Location

Write-Host "Querying models for account '$AccountName' via REST (Invoke-AzRestMethod)..."
$models = Invoke-ModelsRequest -SubId $SubscriptionId -Rg $ResourceGroup -Acct $AccountName
if (-not $models) { throw "No models returned." }

$candidates = $models | Where-Object { $_.name -like "$ModelName*" } | ForEach-Object {
    [pscustomobject]@{
            Name    = $_.name
            Version = $_.properties.version
            Sku     = $_.properties.skuName
    }
}

if (-not $candidates -or $candidates.Count -eq 0) { throw "No model versions found starting with '$ModelName' in this account/region." }

Write-Host "Discovered versions:"; $candidates | Sort-Object Version | Format-Table

$SelectedModelVersion = $null
$SelectedModelSku = $null
foreach ($sku in $PreferredSkus) {
    $match = $candidates | Where-Object { $_.Sku -eq $sku } | Select-Object -First 1
    if ($match) { $SelectedModelVersion = $match.Version; $SelectedModelSku = $match.Sku; break }
}

if (-not $SelectedModelVersion) {
    Write-Warning "No preferred SKU found; selecting first available."
    $first = $candidates | Select-Object -First 1
    $SelectedModelVersion = $first.Version
    $SelectedModelSku = $first.Sku
}

Write-Host "Selected: ModelPrefix=$ModelName Version=$SelectedModelVersion SKU=$SelectedModelSku" -ForegroundColor Green

# Persist outputs for Bicep (param names match environment variable names azd will inject)
azd env set chatGptDeploymentVersion $SelectedModelVersion | Out-Null
azd env set chatGptSkuName $SelectedModelSku | Out-Null
azd env set chatGptModelName $ModelName | Out-Null

Write-Host "Environment updated: chatGptDeploymentVersion=$SelectedModelVersion chatGptSkuName=$SelectedModelSku" -ForegroundColor Cyan

exit 0

$ErrorActionPreference = 'Stop'

function Ensure-AzLogin {
    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        Write-Host "Logging in to Azure..."
        Connect-AzAccount -Subscription $SubscriptionId | Out-Null
    } elseif ((Get-AzContext).Subscription.Id -ne $SubscriptionId) {
        Set-AzContext -Subscription $SubscriptionId | Out-Null
    }
}

function Invoke-ModelsRequest {
    param([string]$SubId,[string]$Rg,[string]$Acct)
    $apiVersion = '2023-05-01'
    $url = "/subscriptions/$SubId/resourceGroups/$Rg/providers/Microsoft.CognitiveServices/accounts/$Acct/models?api-version=$apiVersion"
    # Try Az cmdlet first (PS 7 Az.Accounts >= 2.12)
    if (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue) {
        (Invoke-AzRestMethod -Path $url -Method GET).Content | ConvertFrom-Json
    } else {
        # Fallback to az CLI
        $full = "https://management.azure.com$url"
        $json = az rest --method get --url $full 2>$null
        if (-not $json) { throw "Failed to get models via az rest." }
        $json | ConvertFrom-Json
    }
}

function New-OpenAIAccount {
    param([string]$SubId,[string]$Rg,[string]$Acct,[string]$Loc)
    $acct = az cognitiveservices account show -n $Acct -g $Rg -o json 2>$null | ConvertFrom-Json
    if ($null -eq $acct) {
        Write-Host "Creating Azure OpenAI account '$Acct' in $Loc..."
        az cognitiveservices account create `
            -n $Acct -g $Rg -l $Loc --kind OpenAI --sku S0 --yes `
            --custom-domain $Acct 1>$null
    } else {
        if ($acct.location -ne $Loc) {
            Write-Warning "Existing account is in region '$($acct.location)' not '$Loc'; continuing with existing region."
        }
    }
}

# --- Main Flow ---
Ensure-AzLogin
New-OpenAIAccount -SubId $SubscriptionId -Rg $ResourceGroup -Acct $AccountName -Loc $Location

Write-Host "Querying models for account '$AccountName'..."
$models = Invoke-ModelsRequest -SubId $SubscriptionId -Rg $ResourceGroup -Acct $AccountName

if (-not $models) { throw "No models returned." }

# Normalize entries
$candidates = $models | Where-Object { $_.name -like "$ModelName*" } | ForEach-Object {
    [pscustomobject]@{
        Name    = $_.name
        Version = $_.properties.version
        Sku     = $_.properties.skuName
    }
}

if (-not $candidates -or $candidates.Count -eq 0) {
    throw "No model versions found starting with '$ModelName' in this account/region."
}

Write-Host "Discovered versions:"
$candidates | Sort-Object Version | Format-Table

# Pick preferred SKU
$SelectedModelVersion = $null
$SelectedModelSku = $null
foreach ($sku in $PreferredSkus) {
    $match = $candidates | Where-Object { $_.Sku -eq $sku } | Select-Object -First 1
    if ($match) {
        $SelectedModelVersion = $match.Version
        $SelectedModelSku = $match.Sku
        break
    }
}

if (-not $SelectedModelVersion) {
    Write-Warning "No preferred SKU found; selecting first available."
    $first = $candidates | Select-Object -First 1
    $SelectedModelVersion = $first.Version
    $SelectedModelSku = $first.Sku
}

Write-Host ""
Write-Host "Selected:"
Write-Host "  Model Prefix : $ModelName"
Write-Host "  Version      : $SelectedModelVersion"
Write-Host "  SKU          : $SelectedModelSku"

# Emit key=value for pipeline consumption
"`nCHAT_GPT_MODEL_VERSION=$SelectedModelVersion"
"CHAT_GPT_SKU=$SelectedModelSku"

# Optional: write a parameters JSON snippet
$paramFileObj = @{
    chatGptDeploymentVersion = @{
        value = $SelectedModelVersion
    }
    chatGptSkuName = @{
        value = $SelectedModelSku
    }
}
$paramFilePath = Join-Path (Get-Location) "openai-model-selected.parameters.json"
$paramFileObj | ConvertTo-Json -Depth 5 | Out-File $paramFilePath -Encoding utf8
Write-Host "`nWrote parameter snippet: $paramFilePath"

# Exit code 0 success
exit 0