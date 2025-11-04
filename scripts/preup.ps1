Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PSScriptAnalyzer SuppressMessage = 'PSUseApprovedVerbs', 'Ensure prefix retained for idempotent helper functions.'

#############################################
# Helpers: PSGallery trust & Module handling
#############################################
# PSScriptAnalyzer SuppressMessage = PSUseApprovedVerbs "Ensure prefix retained for idempotent helper functions."
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

# PSScriptAnalyzer SuppressMessage = PSUseApprovedVerbs "Ensure prefix retained for idempotent helper functions."
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
	param(
		[Parameter(Mandatory)][string]$Name,
		[string]$Default=''
	)
	# Capture both stdout & stderr so we can inspect the textual output even if azd returns a non-zero exit code.
	$raw = & azd env get-value $Name 2>&1
	$exit = $LASTEXITCODE
	if (-not $raw) { return $Default }
	# Normalize to single trimmed string (azd may emit trailing newlines)
	$val = ($raw | Out-String).Trim()

	# Detect common azd error patterns. Sometimes ANSI color codes or whitespace precede the word ERROR/error.
	#   - Possible formats observed: "ERROR: key 'XYZ' not found..." or "error: ..."
	#   - With color codes: "\x1b[31mERROR: key 'XYZ' not found ...\x1b[0m"
	#   - Non-zero exit code is also a strong signal the retrieval failed.
	$ansiPattern = '^(?:\x1B\[[0-9;]*m)*'  # optional leading ANSI sequences
	if ($exit -ne 0 -or
		$val -match ("${ansiPattern}\s*(?i:error:)" ) -or
		$val -match ("${ansiPattern}\s*(?i)key '?$Name'?'? not found") -or
		$val -match ("${ansiPattern}\s*(?i)no value found") ) {
		Write-Verbose "azd env key '$Name' not found or retrieval error (exit=$exit); returning default." -Verbose:$false
		return $Default
	}

	return $val
}

function Set-AzdValue {
	param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Value)
	azd env set $Name $Value | Out-Null
}

#############################################
# Azure Login Context
#############################################
# PSScriptAnalyzer SuppressMessage = PSUseApprovedVerbs "Ensure prefix retained for idempotent helper functions."
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
	}
}

#############################################
# Entra ID (AAD) Application + Secret
#############################################
# PSScriptAnalyzer SuppressMessage = PSUseApprovedVerbs "Ensure prefix retained for idempotent helper functions."
function Ensure-AppRegistration {
	param(
		[Parameter(Mandatory)][string]$AppDisplayName
	)
	$existing = Get-AzADApplication -DisplayName $AppDisplayName -ErrorAction SilentlyContinue
	if (-not $existing) {
		Write-Host "Creating Azure AD application '$AppDisplayName'..." -ForegroundColor Green
		New-AzADApplication -DisplayName $AppDisplayName | Out-Null
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

# PSScriptAnalyzer SuppressMessage = PSUseApprovedVerbs "Ensure helper naming aligns with rest of script."
function Ensure-ApiAppRegistration {
	param(
		[Parameter(Mandatory)][string]$ApiAppDisplayName,
		[Parameter(Mandatory)][string]$WebAppClientId
	)

	if (-not $WebAppClientId) { throw 'Web application client id not available; ensure Ensure-AppRegistration ran first.' }

	# Initialize variables
	$appRole = $null
	$appRoleId = $null

	$apiApp = Get-AzADApplication -DisplayName $ApiAppDisplayName -Select AppRole,AppId,Id,DisplayName -ErrorAction SilentlyContinue
	$identifierUri = $null  # Don't use old environment variable, generate fresh based on new app
	$appRoleValue = 'Api.Access'
	$appRoleDescription = 'Allows the web application to call the API.'

	if (-not $apiApp) {
		Write-Host "Creating API Azure AD application '$ApiAppDisplayName'..." -ForegroundColor Green
		# Create the app first without identifier URI to get the app ID
		$appRoleId = [Guid]::NewGuid()
		$roleSpec = @{
			AllowedMemberTypes = @('Application')
			Description = $appRoleDescription
			DisplayName = $appRoleValue
			Id = $appRoleId
			IsEnabled = $true
			Value = $appRoleValue
		}
		New-AzADApplication -DisplayName $ApiAppDisplayName -AppRole $roleSpec -SignInAudience 'AzureADMyOrg' | Out-Null
		Start-Sleep -Seconds 5
		$apiApp = Get-AzADApplication -DisplayName $ApiAppDisplayName -Select AppRole,AppId,Id,DisplayName
		if (-not $apiApp) { throw 'Failed to retrieve API app registration after creation.' }
		if (-not $apiApp.AppId) { throw 'API app was created but AppId is missing.' }
		
		# Now set the identifier URI using the app ID
		if (-not $identifierUri) { $identifierUri = "api://$($apiApp.AppId)" }
		Update-AzADApplication -ObjectId $apiApp.Id -IdentifierUris @($identifierUri) | Out-Null
		Start-Sleep -Seconds 5
		$apiApp = Get-AzADApplication -DisplayName $ApiAppDisplayName -Select AppRole,AppId,Id,DisplayName
		
		# Create mock app role object with known ID for newly created app
		Write-Host "Creating mock app role object with known ID for newly created app..." -ForegroundColor Yellow
		$appRole = [PSCustomObject]@{
			Id = $appRoleId
			Value = $appRoleValue
			DisplayName = $appRoleValue
			Description = $appRoleDescription
		}
	} else {
		if (-not $identifierUri) {
			# Get full app object to check IdentifierUris
			$fullApiApp = Get-AzADApplication -DisplayName $ApiAppDisplayName
			try {
				if ($fullApiApp.IdentifierUris -and $fullApiApp.IdentifierUris.Count -gt 0) {
					$identifierUri = $fullApiApp.IdentifierUris[0]
				} else {
					$identifierUri = "api://$($apiApp.AppId)"
					Update-AzADApplication -ObjectId $apiApp.Id -IdentifierUris @($identifierUri) | Out-Null
					$apiApp = Get-AzADApplication -DisplayName $ApiAppDisplayName -Select AppRole,AppId,Id,DisplayName
				}
			} catch {
				Write-Host "Warning: Could not access IdentifierUris property, setting default identifier URI..." -ForegroundColor Yellow
				$identifierUri = "api://$($apiApp.AppId)"
				Update-AzADApplication -ObjectId $apiApp.Id -IdentifierUris @($identifierUri) | Out-Null
				$apiApp = Get-AzADApplication -DisplayName $ApiAppDisplayName -Select AppRole,AppId,Id,DisplayName
			}
		}

		$appRole = $null
		try {
			# Get full app object to check for existing roles
			$fullApiAppForRoles = Get-AzADApplication -DisplayName $ApiAppDisplayName
			if ($fullApiAppForRoles -and $fullApiAppForRoles.AppRole) {
				$appRole = $fullApiAppForRoles.AppRole | Where-Object { $_.Value -eq $appRoleValue }
				if ($appRole) { 
					if ($appRole.GetType().IsArray -and $appRole.Count -gt 0) {
						$appRole = $appRole[0] 
					}
					Write-Host "Found existing role '$appRoleValue' in API app - skipping creation" -ForegroundColor Green
				}
			}
		} catch {
			Write-Verbose "AppRole property not found or accessible on API app object." -Verbose:$false
		}

		if (-not $appRole) {
			Write-Host "Adding application role '$appRoleValue' to API app..." -ForegroundColor DarkCyan
			$appRoleId = [Guid]::NewGuid()
			$roleSpec = @{
				AllowedMemberTypes = @('Application')
				Description = $appRoleDescription
				DisplayName = $appRoleValue
				Id = $appRoleId
				IsEnabled = $true
				Value = $appRoleValue
			}
			$existingRoles = @()
			try {
				if ($fullApiAppForRoles -and $fullApiAppForRoles.AppRole) {
					foreach ($r in $fullApiAppForRoles.AppRole) {
						$existingRoles += @{
							AllowedMemberTypes = $r.AllowedMemberTypes
							Description = $r.Description
							DisplayName = $r.DisplayName
							Id = [Guid]$r.Id
							IsEnabled = [bool]$r.IsEnabled
							Value = $r.Value
						}
					}
				}
			} catch {
				Write-Verbose "AppRoles property not found or accessible on API app object during role enumeration." -Verbose:$false
			}
			$allRoles = $existingRoles + $roleSpec
			Update-AzADApplication -ObjectId $apiApp.Id -AppRole $allRoles | Out-Null
			Start-Sleep -Seconds 5
			$apiApp = Get-AzADApplication -DisplayName $ApiAppDisplayName -Select AppRole,AppId,Id,DisplayName
			$appRole = $null
			try {
				if ($apiApp -and $apiApp.AppRole) {
					$appRole = $apiApp.AppRole | Where-Object { $_.Value -eq $appRoleValue }
				}
			} catch {
				Write-Verbose "AppRole property not found or accessible on API app object after role update." -Verbose:$false
			}
			if ($appRole -and $appRole.Count -gt 0) { $appRole = $appRole[0] }
			if (-not $appRole) { throw 'Failed to create API application role.' }
		}
	}

	if (-not $identifierUri) {
		$identifierUri = "api://$($apiApp.AppId)"
		Update-AzADApplication -ObjectId $apiApp.Id -IdentifierUris @($identifierUri) | Out-Null
		Start-Sleep -Seconds 5
		$apiApp = Get-AzADApplication -DisplayName $ApiAppDisplayName -Select AppRole,AppId,Id,DisplayName
	}

	if (-not $appRole) {
		Write-Host "DEBUG: API App object properties:" -ForegroundColor Red
		Write-Host "AppId: $($apiApp.AppId)" -ForegroundColor Red
		Write-Host "DisplayName: $($apiApp.DisplayName)" -ForegroundColor Red
		Write-Host "AppRoles count: $(if ($apiApp.AppRoles) { $apiApp.AppRoles.Count } else { 'null or not accessible' })" -ForegroundColor Red
		if ($apiApp.AppRoles) {
			foreach ($role in $apiApp.AppRoles) {
				Write-Host "Role Value: '$($role.Value)', Id: '$($role.Id)'" -ForegroundColor Red
			}
		}
		throw "API application role '$appRoleValue' was not found after creation/update."
	}
	$apiRoleId = [string]$appRole.Id

	$apiSp = Get-AzADServicePrincipal -ApplicationId $apiApp.AppId -ErrorAction SilentlyContinue
	if (-not $apiSp) {
		Write-Host "Creating service principal for API app..." -ForegroundColor DarkCyan
		$apiSp = New-AzADServicePrincipal -ApplicationId $apiApp.AppId
	}

	$webSp = Get-AzADServicePrincipal -ApplicationId $WebAppClientId -ErrorAction SilentlyContinue
	if (-not $webSp) {
		Write-Host "Creating service principal for web app registration..." -ForegroundColor DarkCyan
		$webSp = New-AzADServicePrincipal -ApplicationId $WebAppClientId
	}

	$assignmentExists = $false
	try {
		$assignments = Get-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId $webSp.Id -ErrorAction Stop
		if ($assignments) {
			$assignmentExists = $assignments | Where-Object { $_.ResourceId -eq $apiSp.Id -and ([string]$_.AppRoleId -eq $apiRoleId) }
			if ($assignmentExists) {
				Write-Host "Role assignment already exists between web app and API app - skipping creation" -ForegroundColor Green
			}
		}
	} catch {
		Write-Verbose "Unable to enumerate existing role assignments: $($_.Exception.Message)" -Verbose:$false
	}

	if (-not $assignmentExists) {
		Write-Host "Assigning API app role '$appRoleValue' to web app service principal..." -ForegroundColor DarkCyan
		New-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId $webSp.Id -ResourceId $apiSp.Id -AppRoleId ([Guid]$apiRoleId) | Out-Null
	}

	Set-AzdValue -Name 'API_APP_ID' -Value $apiApp.AppId
	Set-AzdValue -Name 'API_APP_OBJECT_ID' -Value $apiApp.Id
	Set-AzdValue -Name 'API_APP_ROLE_ID' -Value $apiRoleId
	Set-AzdValue -Name 'API_APP_ID_URI' -Value $identifierUri

	Write-Host "API app registration ensured. Audience: $identifierUri" -ForegroundColor Green
}

#############################################
# Azure OpenAI Account + Model Selection
#############################################
# Minimal model (only fields we actually use)
class Model { [string]$format; [string]$name; [string]$version }

# PSScriptAnalyzer SuppressMessage = PSUseApprovedVerbs "Ensure helper naming aligns with rest of script."
function Ensure-OpenAIAccount {
	param([string]$SubId,[string]$Rg,[string]$Acct,[string]$Loc)
	if ([string]::IsNullOrWhiteSpace($Acct)) { throw 'Ensure-OpenAIAccount received an empty account name.' }
	$existingAcct = Get-AzCognitiveServicesAccount -Name $Acct -ResourceGroupName $Rg -ErrorAction SilentlyContinue
	if (-not $existingAcct) {
		Write-Host "Creating Azure OpenAI account '$Acct' in $Loc..." -ForegroundColor Green
		New-AzCognitiveServicesAccount -ResourceGroupName $Rg -Name $Acct -Type 'AIServices' -SkuName 'S0' -Location $Loc -CustomSubDomainName $Acct -Force | Out-Null
	} elseif ($existingAcct.Location -ne $Loc) {
		Write-Warning "Existing account region '$($existingAcct.Location)' differs from requested '$Loc'; proceeding with existing region."
	}
}

function Get-AccountModelsMultiVersion {
	param([string]$SubId,[string]$Rg,[string]$Acct)
	$apiVersion = '2025-07-01-preview'
	$url = "/subscriptions/$SubId/resourceGroups/$Rg/providers/Microsoft.CognitiveServices/accounts/$Acct/models?api-version=$apiVersion"
	try { $resp = Invoke-AzRestMethod -Path $url -Method GET -ErrorAction Stop } catch { Write-Error "Failed to call models endpoint: $($_.Exception.Message)"; return @() }

	$models = @()
	if (-not $resp -or -not $resp.Content) {
		Write-Warning "Empty response when enumerating models."
		return $models
	}

	# Try to parse JSON, but be defensive: structure may change or contain an error payload.
	try {
		$json = $resp.Content | ConvertFrom-Json -ErrorAction Stop
	} catch {
		Write-Warning ("Unable to parse models JSON: {0}. Raw (truncated): {1}" -f $_.Exception.Message, ($resp.Content.Substring(0, [Math]::Min(500, $resp.Content.Length))))
		return $models
	}

	# Determine the collection of model items. Some API shapes return { value = [...] }, others may return an array directly.
	$modelItems = @()
	if ($null -ne $json) {
		$hasValueProp = $false
		if ($json -is [System.Management.Automation.PSObject]) {
			$hasValueProp = $json.PSObject.Properties.Name -contains 'value'
		}
		if ($hasValueProp -and $json.value) {
			$modelItems = $json.value
		} elseif ($json -is [System.Collections.IEnumerable] -and -not ($json -is [string])) {
			# Treat top-level array as models list
			$modelItems = $json
		}
	}

	if (-not $modelItems -or ($modelItems | Measure-Object).Count -eq 0) {
		Write-Warning ("No model entries discovered. Raw (truncated): {0}" -f ($resp.Content.Substring(0, [Math]::Min(500, $resp.Content.Length))))
		return $models
	}

	$excludePattern = '(?i)(realtime|transcribe|image|audio)'
	foreach ($m in $modelItems) {
		# Be tolerant if expected properties are missing
		if (-not ($m | Get-Member -Name name -ErrorAction SilentlyContinue)) { continue }
		if ($m.name -match $excludePattern) { continue }
		$model = [Model]::new();
		$model.name = $m.name
		if ($m | Get-Member -Name format -ErrorAction SilentlyContinue) { $model.format = $m.format }
		if ($m | Get-Member -Name version -ErrorAction SilentlyContinue) { $model.version = $m.version }
		$models += $model
	}
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

# If subscription id is missing but resource group is already known, attempt to discover the subscription
if (-not $subscriptionId) {
	Write-Host "No value for AZURE_SUBSCRIPTION_ID found." -ForegroundColor DarkCyan
	$rgForLookup = Get-AzdValue -Name 'AZURE_RESOURCE_GROUP'
	if ($rgForLookup) {
		Write-Host "Attempting to resolve AZURE_SUBSCRIPTION_ID for resource group '$rgForLookup'..." -ForegroundColor DarkCyan
		$resolvedSubId = $null

		# First try current context (fast path)
		$ctx = Get-AzContext -ErrorAction SilentlyContinue
		if ($ctx) {
			try {
				if (Get-AzResourceGroup -Name $rgForLookup -ErrorAction SilentlyContinue) {
					$resolvedSubId = $ctx.Subscription.Id
				}
			} catch { }
		}

		# Enumerate subscriptions if still not resolved
		if (-not $resolvedSubId) {
			try {
				$subs = Get-AzSubscription -ErrorAction Stop
				foreach ($sub in $subs) {
					try {
						Set-AzContext -Subscription $sub.Id -ErrorAction Stop | Out-Null
						if (Get-AzResourceGroup -Name $rgForLookup -ErrorAction SilentlyContinue) { $resolvedSubId = $sub.Id; break }
					} catch { }
				}
			} catch {
				Write-Warning "Failed enumerating subscriptions while resolving subscription id: $($_.Exception.Message)"
			}
		}

		if ($resolvedSubId) {
			Write-Host "Resolved subscription id '$resolvedSubId' for resource group '$rgForLookup'." -ForegroundColor Green
			Set-AzdValue -Name 'AZURE_SUBSCRIPTION_ID' -Value $resolvedSubId
			$subscriptionId = $resolvedSubId
			# Ensure context is set to resolved subscription
			if ((Get-AzContext).Subscription.Id -ne $subscriptionId) { Set-AzContext -Subscription $subscriptionId | Out-Null }
		} else {
			Write-Warning "Unable to resolve subscription id using resource group '$rgForLookup'. Proceeding without setting AZURE_SUBSCRIPTION_ID."
		}
	}
}

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

# 1a. API App Registration
$apiAppDisplayName = 'MyToDoApp-Api'
$webClientId = Get-AzdValue -Name 'CLIENT_ID'
if (-not $webClientId) { throw 'CLIENT_ID is missing after web app registration; cannot configure API registration.' }
Ensure-ApiAppRegistration -ApiAppDisplayName $apiAppDisplayName -WebAppClientId $webClientId

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

# SECOND-CHANCE SUBSCRIPTION RESOLUTION
if (-not $subscriptionId) {
	$ctx = Get-AzContext -ErrorAction SilentlyContinue
	if ($ctx -and $ctx.Subscription -and $ctx.Subscription.Id) {
		$subscriptionId = $ctx.Subscription.Id
		Set-AzdValue -Name 'AZURE_SUBSCRIPTION_ID' -Value $subscriptionId
		Write-Host "Captured subscription id from current context: $subscriptionId" -ForegroundColor Green
	} else {
		Write-Warning "Subscription id still not resolved after resource group handling. Model enumeration will fail without it."
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
$null = if (-not $subscriptionId) { throw 'Subscription id is missing; cannot enumerate models. Ensure you are logged in (Connect-AzAccount) and that a subscription is selected (Set-AzContext).' }
$models = Get-AccountModelsMultiVersion -SubId $subscriptionId -Rg $resourceGroup -Acct $accountName
if (-not $models -or $models.Count -eq 0) { throw 'No models returned from Azure OpenAI account; aborting preup hook.' }

# Filter to OpenAI models only (other provider models cause quota retrieval warnings due to ValidateSet('OpenAI'))
$originalModelCount = $models.Count
$models = $models | Where-Object { [string]::IsNullOrWhiteSpace($_.format) -or $_.format -ieq 'OpenAI' }
if ($models.Count -lt $originalModelCount) {
	Write-Host ("Filtered models: using {0} OpenAI models out of {1} total (skipped {2} non-OpenAI)." -f $models.Count, $originalModelCount, ($originalModelCount - $models.Count)) -ForegroundColor DarkGray
}

# Get quota for each model (parallel when possible)
$allQuota = @()
$pwshSupportsParallel = $false
try {
	$feParams = (Get-Command ForEach-Object).Parameters
	if ($PSVersionTable.PSVersion.Major -ge 7 -and $feParams.ContainsKey('Parallel')) { $pwshSupportsParallel = $true }
} catch { }
$throttle = [int]([Environment]::GetEnvironmentVariable('AOAI_QUOTA_DOP'))
if (-not $throttle -or $throttle -lt 1) { $throttle = 8 }

if ($pwshSupportsParallel) {
	Write-Host ("Retrieving quota in parallel (ThrottleLimit={0})..." -f $throttle) -ForegroundColor DarkGreen
	# Pre-fetch account once to avoid doing it per parallel task
	try {
		$acctObj = Get-AzCognitiveServicesAccount -ResourceGroupName $resourceGroup -Name $accountName -ErrorAction Stop
	} catch {
		Write-Warning "Failed to retrieve Cognitive Services account for quota lookups: $($_.Exception.Message). Falling back to sequential mode."
		$pwshSupportsParallel = $false
	}
	if ($pwshSupportsParallel) {
		$acctSubId = ($acctObj.Id -split '/')[2]
		$acctLoc   = $acctObj.Location
		$apiVersionCap = '2024-10-01'
		$quotas = $models | ForEach-Object -Parallel {
			$fmt = if ([string]::IsNullOrWhiteSpace($_.format)) { 'OpenAI' } else { $_.format }
			try {
				Write-Host "  [Parallel] Getting available quota for Model '$($_.name)' v '$($_.version)'" -ForegroundColor DarkCyan
				function _Encode([string]$v){ [System.Uri]::EscapeDataString($v) }
				$relPath = "/subscriptions/$($using:acctSubId)/providers/Microsoft.CognitiveServices/modelCapacities?api-version=$($using:apiVersionCap)&modelFormat=$(_Encode $fmt)&modelName=$(_Encode $_.name)&modelVersion=$(_Encode $_.version)"
				$resp = Invoke-AzRestMethod -Method GET -Path $relPath -ErrorAction Stop
				$payload = $resp.Content | ConvertFrom-Json
				if (-not $payload.value) { return }
				$rows = $payload.value | Where-Object { $_.location -ieq $using:acctLoc }
				if (-not $rows) { return }
				$rows = $rows | Where-Object { $_.properties.skuName -notmatch 'Batch$' } | Where-Object { ([int]$_.properties.availableCapacity) -gt 0 }
				if (-not $rows) { return }
				$rows | ForEach-Object { [pscustomobject]@{ SubscriptionId=$using:acctSubId; Location=$_.location; SkuName=$_.properties.skuName; ModelFormat=$_.properties.model.format; ModelName=$_.properties.model.name; ModelVersion=$_.properties.model.version; AvailableCapacity=$_.properties.availableCapacity } } | Sort-Object Location, SkuName
			} catch {
				Write-Warning "Failed quota retrieval for Model $($_.name) v $($_.version): $($_.Exception.Message)"
			}
		} -ThrottleLimit $throttle
		foreach ($q in $quotas) { if ($q) { $allQuota += $q } }
	}
} else {
	Write-Host "Parallel quota retrieval not supported in this PowerShell version; running sequentially." -ForegroundColor Yellow
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
}

if (-not $allQuota -or $allQuota.Count -eq 0) { Write-Warning 'No quota data collected.'; return }

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

