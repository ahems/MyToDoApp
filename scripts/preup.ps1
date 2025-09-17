Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#############################################
# Helpers: PSGallery trust & Module handling
#############################################
function Ensure-PsGalleryTrusted {
	try {
		$gallery = Get-PSRepository -Name 'PSGallery' -ErrorAction Stop
		if ($gallery.InstallationPolicy -ne 'Trusted') {
			Write-Host "Setting PSGallery repository to Trusted..." -ForegroundColor DarkCyan
			Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
		}
	} catch {
		Write-Host "Registering PSGallery repository..." -ForegroundColor DarkCyan
		Register-PSRepository -Name 'PSGallery' -SourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted
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
		Install-Module @installParams | Out-Null
	}
	Import-Module $Name -ErrorAction Stop | Out-Null
}

function Get-AzdValue {
	param([Parameter(Mandatory)][string]$Name,[string]$Default='')
	$val = azd env get-value $Name 2>$null
	if (-not $val -or $val -match '^ERROR:') { return $Default }
	return $val.Trim()
}

function Set-AzdValue {
	param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Value)
	azd env set $Name $Value | Out-Null
}

#############################################
# Azure Login Context
#############################################
function Ensure-AzLogin {
	param([string]$TenantId,[string]$SubscriptionId)
	if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
		Write-Host "Connecting to Azure..." -ForegroundColor DarkCyan
		if ($TenantId) {
			Write-Host "Using tenant: $TenantId" -ForegroundColor DarkCyan
			Connect-AzAccount -Tenant $TenantId -UseDeviceAuthentication | Out-Null
		} else {
			Connect-AzAccount -UseDeviceAuthentication | Out-Null
		}
	}
	if ($SubscriptionId) {
		if ((Get-AzContext).Subscription.Id -ne $SubscriptionId) {
			Write-Host "Switching subscription context to $SubscriptionId" -ForegroundColor DarkCyan
			Set-AzContext -Subscription $SubscriptionId | Out-Null
		}
		Update-AzConfig -DefaultSubscriptionForLogin $SubscriptionId | Out-Null
	}
}

#############################################
# Entra ID (AAD) Application + Secret
#############################################
function Ensure-AppRegistration {
	param(
		[Parameter(Mandatory)][string]$AppDisplayName
	)
	$existing = Get-AzADApplication -DisplayName $AppDisplayName -ErrorAction SilentlyContinue
	if (-not $existing) {
		Write-Host "Creating Azure AD application '$AppDisplayName'..." -ForegroundColor Green
		$newApp = New-AzADApplication -DisplayName $AppDisplayName
		Start-Sleep -Seconds 5
		$app = Get-AzADApplication -DisplayName $AppDisplayName
		if (-not $app) { throw "Failed to retrieve app registration after creation." }
		$sp = New-AzADServicePrincipal -ApplicationId $app.AppId
		$cred = New-AzADSpCredential -ObjectId $sp.Id -EndDate (Get-Date).AddYears(1)
		Set-AzdValue -Name 'CLIENT_ID' -Value $app.AppId
		Set-AzdValue -Name 'CLIENT_SECRET' -Value $cred.SecretText
		Write-Host "App registration + SP + secret created." -ForegroundColor Green
	} else {
		Write-Host "Application '$AppDisplayName' already exists - skipping creation." -ForegroundColor Yellow
		# Optionally set CLIENT_ID if missing
		$clientIdEnv = Get-AzdValue -Name 'CLIENT_ID'
		if (-not $clientIdEnv) { Set-AzdValue -Name 'CLIENT_ID' -Value $existing.AppId }

		# Ensure CLIENT_SECRET exists; if missing, create a new SP credential and persist it
		$clientSecretEnv = Get-AzdValue -Name 'CLIENT_SECRET'
		if (-not $clientSecretEnv) {
			Write-Host "CLIENT_SECRET not found in environment. Creating a new secret for the existing application..." -ForegroundColor DarkCyan
			$sp = Get-AzADServicePrincipal -ApplicationId $existing.AppId -ErrorAction SilentlyContinue
			if (-not $sp) {
				Write-Host "Service principal not found for existing app. Creating service principal..." -ForegroundColor DarkCyan
				$sp = New-AzADServicePrincipal -ApplicationId $existing.AppId
			}
			$cred = New-AzADSpCredential -ObjectId $sp.Id -EndDate (Get-Date).AddYears(1)
			if (-not $cred -or -not $cred.SecretText) { throw "Failed to create or retrieve secret text for existing application." }
			Set-AzdValue -Name 'CLIENT_SECRET' -Value $cred.SecretText
			Write-Host "Created and persisted CLIENT_SECRET for existing application." -ForegroundColor Green
		}
	}
}

#############################################
# Azure OpenAI Account + Model Selection
#############################################
# Minimal model (only fields we actually use)
class Model { [string]$format; [string]$name; [string]$version }

function Ensure-OpenAIAccount {
	param([string]$SubId,[string]$Rg,[string]$Acct,[string]$Loc)
	if ([string]::IsNullOrWhiteSpace($Acct)) { throw 'Ensure-OpenAIAccount received an empty account name.' }
	$existingAcct = Get-AzCognitiveServicesAccount -Name $Acct -ResourceGroupName $Rg -ErrorAction SilentlyContinue
	if (-not $existingAcct) {
		Write-Host "Creating Azure OpenAI account '$Acct' in $Loc..." -ForegroundColor Green
		New-AzCognitiveServicesAccount -ResourceGroupName $Rg -Name $Acct -Type 'OpenAI' -SkuName 'S0' -Location $Loc -CustomSubDomainName $Acct -Force | Out-Null
	} elseif ($existingAcct.Location -ne $Loc) {
		Write-Warning "Existing account region '$($existingAcct.Location)' differs from requested '$Loc'; proceeding with existing region."
	}
}

function Get-AccountModelsMultiVersion {
	param([string]$SubId,[string]$Rg,[string]$Acct)
	$apiVersion = '2025-07-01-preview'
	$url = "/subscriptions/$SubId/resourceGroups/$Rg/providers/Microsoft.CognitiveServices/accounts/$Acct/models?api-version=$apiVersion"
	try { $resp = Invoke-AzRestMethod -Path $url -Method GET -ErrorAction Stop } catch { Write-Error "Failed to call models endpoint: $($_.Exception.Message)"; return @() }
	$json = $resp.Content | ConvertFrom-Json
	$models = @()
	if ($json -and $json.value) {
		$excludePattern = '(?i)(realtime|transcribe|image|audio)'
		foreach ($m in $json.value) {
			if ($m.name -match $excludePattern) { continue }
			$model = [Model]::new(); $model.format = $m.format; $model.name = $m.name; $model.version = $m.version; $models += $model
		}
	} else { Write-Warning "No model data returned. Raw: $($resp.Content)" }
	return $models
}

function Get-AoaiModelAvailableQuota {
	[CmdletBinding()] param([Parameter(Mandatory)][string]$ResourceGroupName,[Parameter(Mandatory)][string]$AccountName,[Parameter(Mandatory)][string]$ModelName,[Parameter(Mandatory)][string]$ModelVersion,[ValidateSet('OpenAI')][string]$ModelFormat='OpenAI',[string]$Location,[switch]$AllRegions)
	$acct = Get-AzCognitiveServicesAccount -ResourceGroupName $ResourceGroupName -Name $AccountName -ErrorAction Stop
	$subscriptionId = ($acct.Id -split '/')[2]
	if (-not $Location) { $Location = $acct.Location }
	$apiVersion = '2024-10-01'
	function _Encode([string]$v){ [System.Uri]::EscapeDataString($v) }
	$relPath = "/subscriptions/$subscriptionId/providers/Microsoft.CognitiveServices/modelCapacities?api-version=$apiVersion&modelFormat=$(_Encode $ModelFormat)&modelName=$(_Encode $ModelName)&modelVersion=$(_Encode $ModelVersion)"
	$resp = Invoke-AzRestMethod -Method GET -Path $relPath -ErrorAction Stop
	$payload = $resp.Content | ConvertFrom-Json
	if (-not $payload.value){ Write-Warning "No capacity entries returned"; return }
	$rows = if ($AllRegions) { $payload.value } else { $payload.value | Where-Object { $_.location -ieq $Location } }
	if (-not $rows) { return }
	$rows = $rows | Where-Object { $_.properties.skuName -notmatch 'Batch$' } | Where-Object { ([int]$_.properties.availableCapacity) -gt 0 }
	if (-not $rows) { return }
	$rows | ForEach-Object { [pscustomobject]@{ SubscriptionId=$subscriptionId; Location=$_.location; SkuName=$_.properties.skuName; ModelFormat=$_.properties.model.format; ModelName=$_.properties.model.name; ModelVersion=$_.properties.model.version; AvailableCapacity=$_.properties.availableCapacity } } | Sort-Object Location, SkuName
}

#############################################
# MAIN EXECUTION FLOW
#############################################
Ensure-PsGalleryTrusted
Ensure-Module -Name Az.Accounts -MinVersion '2.12.0'
Ensure-Module -Name Az.Resources
Ensure-Module -Name Az.CognitiveServices

$tenantId       = Get-AzdValue -Name 'TENANT_ID'
$subscriptionId = Get-AzdValue -Name 'AZURE_SUBSCRIPTION_ID'
Ensure-AzLogin -TenantId $tenantId -SubscriptionId $subscriptionId

# Ensure NAME & OBJECT_ID env vars (user context)
$nameVal = Get-AzdValue -Name 'NAME'
$objectIdVal = Get-AzdValue -Name 'OBJECT_ID'
if (-not $nameVal -or -not $objectIdVal) {
	$acct = (Get-AzContext).Account
	$nameVal = $acct.Id
	$userObj = Get-AzADUser -SignedIn
	$objectIdVal = $userObj.Id
	Set-AzdValue -Name 'NAME' -Value $nameVal
	Set-AzdValue -Name 'OBJECT_ID' -Value $objectIdVal
	Write-Host "Persisted NAME and OBJECT_ID to azd env." -ForegroundColor Green
}

# 1. App Registration
$appDisplayName = 'MyToDoApp'
Ensure-AppRegistration -AppDisplayName $appDisplayName

# 2. Azure OpenAI provisioning + model selection (skip if already fully selected)
$existingChatComplete = (Get-AzdValue -Name 'chatGptDeploymentVersion') -and (Get-AzdValue -Name 'chatGptSkuName') -and (Get-AzdValue -Name 'chatGptModelName') -and (Get-AzdValue -Name 'availableChatGptDeploymentCapacity')
$existingEmbComplete  = (Get-AzdValue -Name 'embeddingDeploymentVersion') -and (Get-AzdValue -Name 'embeddingDeploymentSkuName') -and (Get-AzdValue -Name 'embeddingDeploymentModelName') -and (Get-AzdValue -Name 'availableEmbeddingDeploymentCapacity')

if ($existingChatComplete -and $existingEmbComplete) {
	Write-Host "Model selections already present. Skipping model discovery." -ForegroundColor Yellow
	return
}

$location = Get-AzdValue -Name 'AZURE_LOCATION' -Default 'eastus2'
# Persist default location if it was not previously set
if (-not (Get-AzdValue -Name 'AZURE_LOCATION')) {
	Set-AzdValue -Name 'AZURE_LOCATION' -Value $location
	Write-Host "Set default AZURE_LOCATION = $location" -ForegroundColor Cyan
}

$resourceGroup = Get-AzdValue -Name 'AZURE_RESOURCE_GROUP'
$envName = Get-AzdValue -Name 'AZURE_ENV_NAME'
if (-not $resourceGroup) {
	if (-not $envName) { throw 'AZURE_RESOURCE_GROUP not set and cannot derive because AZURE_ENV_NAME is missing.' }
	$resourceGroup = "rg-$envName"
	Set-AzdValue -Name 'AZURE_RESOURCE_GROUP' -Value $resourceGroup
	Write-Host "Derived and set AZURE_RESOURCE_GROUP = $resourceGroup" -ForegroundColor Cyan
	# Create the resource group immediately if it does not exist using resolved $location
	$existingRg = Get-AzResourceGroup -Name $resourceGroup -ErrorAction SilentlyContinue
	if (-not $existingRg) {
		Write-Host "Creating resource group '$resourceGroup' in location '$location'..." -ForegroundColor Green
		New-AzResourceGroup -Name $resourceGroup -Location $location | Out-Null
	} else {
		Write-Host "Resource group '$resourceGroup' already exists." -ForegroundColor Yellow
	}
}

$accountName = Get-AzdValue -Name 'AZURE_OPENAI_ACCOUNT_NAME'
if (-not $accountName) {
	$hash = ([System.BitConverter]::ToString((New-Guid).ToByteArray()) -replace '-','').Substring(0,8).ToLower()
	$accountName = "todoapp-openai-$hash"
	Set-AzdValue -Name 'AZURE_OPENAI_ACCOUNT_NAME' -Value $accountName
	Write-Host "Derived Azure OpenAI account name: $accountName" -ForegroundColor Cyan
}

Ensure-OpenAIAccount -SubId $subscriptionId -Rg $resourceGroup -Acct $accountName -Loc $location

Write-Host "Enumerating models for account '$accountName' in region '$location'..." -ForegroundColor Cyan
$models = Get-AccountModelsMultiVersion -SubId $subscriptionId -Rg $resourceGroup -Acct $accountName
if (-not $models -or $models.Count -eq 0) { Write-Warning 'No models returned; skipping model selection.'; return }

# Get quota for each model
$allQuota = @()
$total = $models.Count
$i = 0
foreach ($m in $models) {
	$i++
	$fmt = if ([string]::IsNullOrWhiteSpace($m.format)) { 'OpenAI' } else { $m.format }
	try {
		Write-Host "  [$i/$total] Getting available quota for Model '$($m.name)', version '$($m.version)'..." -ForegroundColor DarkCyan
		$quota = Get-AoaiModelAvailableQuota -ResourceGroupName $resourceGroup -AccountName $accountName -ModelName $m.name -ModelVersion $m.version -ModelFormat $fmt -ErrorAction Stop
		if ($quota) { $allQuota += $quota }
	} catch { Write-Warning "Failed quota retrieval for Model $($m.name), version $($m.version): $($_.Exception.Message)" }
}

if ($allQuota.Count -eq 0) { Write-Warning 'No quota data collected.'; return }

Write-Host "Sorting quota results..." -ForegroundColor DarkGreen
$sorted = $allQuota | Sort-Object -Property @{Expression={ [int]$_.AvailableCapacity }; Descending=$true}, @{Expression={$_.ModelVersion}; Descending=$true}

$chatPick = $sorted | Select-Object -First 1
if ($chatPick) {
	Set-AzdValue -Name 'chatGptDeploymentVersion' -Value $chatPick.ModelVersion
	Set-AzdValue -Name 'chatGptSkuName' -Value $chatPick.SkuName
	Set-AzdValue -Name 'chatGptModelName' -Value $chatPick.ModelName
	Set-AzdValue -Name 'availableChatGptDeploymentCapacity' -Value ($chatPick.AvailableCapacity.ToString())
	Write-Host "Selected Chat model: $($chatPick.ModelName) $($chatPick.ModelVersion) SKU $($chatPick.SkuName) Capacity $($chatPick.AvailableCapacity)" -ForegroundColor Green
} else { Write-Warning 'No chat model selected.' }

$embeddingPick = $sorted | Where-Object { $_.ModelName -like '*embedding*' } | Select-Object -First 1
if ($embeddingPick) {
	Set-AzdValue -Name 'embeddingDeploymentVersion' -Value $embeddingPick.ModelVersion
	Set-AzdValue -Name 'embeddingDeploymentSkuName' -Value $embeddingPick.SkuName
	Set-AzdValue -Name 'embeddingDeploymentModelName' -Value $embeddingPick.ModelName
	Set-AzdValue -Name 'availableEmbeddingDeploymentCapacity' -Value ($embeddingPick.AvailableCapacity.ToString())
	Write-Host "Selected Embeddings model: $($embeddingPick.ModelName) $($embeddingPick.ModelVersion) SKU $($embeddingPick.SkuName) Capacity $($embeddingPick.AvailableCapacity)" -ForegroundColor Green
} else { Write-Warning 'No embeddings model selected.' }

Write-Host "preup.ps1 completed." -ForegroundColor Cyan

