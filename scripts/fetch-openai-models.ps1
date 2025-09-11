# Define the class structure to match the JSON model retuned by the API
# This script fetches the models from the OpenAI API and converts them into strongly typed PowerShell objects.
class RateLimit {
    [string]$key
    [int]$renewalPeriod
    [int]$count
}

class Cost {
    [string]$name
    [string]$meterId
    [string]$unit
}

class Sku {
    [string]$name
    [string]$usageName
    [int]$default
    [int]$maximum
    [int]$minimum
    [int]$step
}

class Capability {
    [bool]$chatCompletion
    [bool]$assistants
    [bool]$fineTune
    [bool]$audio
    [bool]$realtime
    [bool]$jsonObjectResponse
    [bool]$jsonSchemaResponse
}

class SystemData {
    [string]$createdBy
    [string]$createdByType
    [datetime]$createdAt
    [string]$lastModifiedBy
    [string]$lastModifiedByType
    [datetime]$lastModifiedAt
}

class Model {
    [string]$format
    [string]$name
    [string]$version
    [string]$description
    [bool]$isDefaultVersion
    [Sku[]]$skus
    [RateLimit[]]$rateLimits
    [Cost[]]$costs
    [Capability]$capabilities
    [SystemData]$systemData
    [string]$lifecycleStatus
    [datetime]$deprecationDate
}

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

function Get-AzdValue {
    param([Parameter(Mandatory)][string]$Name,[string]$Default='')
    $val = azd env get-value $Name 2>$null
    if (-not $val -or $val -match "^ERROR:") { return $Default }
    return $val.Trim()
}

function Set-AzLoginContext {
    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        Write-Host "Logging in to Azure..."
        Connect-AzAccount -Subscription $SubscriptionId | Out-Null
    } elseif ((Get-AzContext).Subscription.Id -ne $SubscriptionId) {
        Set-AzContext -Subscription $SubscriptionId | Out-Null
    }
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

function Get-AccountModelsMultiVersion {
    param(
        [string]$SubId,[string]$Rg,[string]$Acct
    )
    $apiVersion = '2025-07-01-preview' #,'2025-06-01','2025-04-01-preview','2024-10-01','2024-06-01-preview','2024-04-01-preview','2023-10-01-preview','2023-06-01-preview','2023-05-01')
    $url = "/subscriptions/$SubId/resourceGroups/$Rg/providers/Microsoft.CognitiveServices/accounts/$Acct/models?api-version=$apiVersion"
    try {
        $resp = Invoke-AzRestMethod -Path $url -Method GET -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to call Azure OpenAI models endpoint: $($_.Exception.Message)"
        return @()
    }

    $json = $resp.Content | ConvertFrom-Json
    $models = @()
    if ($json -and $json.value) {
        foreach ($m in $json.value) {
            $model = [Model]::new()
            $model.format = $m.format
            $model.name = $m.name
            $model.version = $m.version
            $model.description = $m.description
            $model.isDefaultVersion = [bool]$m.isDefaultVersion
            $model.lifecycleStatus = $m.lifecycleStatus
            if ($m.deprecationDate) { $model.deprecationDate = [datetime]$m.deprecationDate }

            # Skus
            if ($m.skus) {
                $skus = foreach ($s in $m.skus) {
                    $skuObj = [Sku]::new()
                    $skuObj.name = $s.name
                    $skuObj.usageName = $s.usageName
                    $skuObj.default = $s.default
                    $skuObj.maximum = $s.maximum
                    $skuObj.minimum = $s.minimum
                    $skuObj.step = $s.step
                    $skuObj
                }
                $model.skus = $skus
            }

            # Rate limits
            if ($m.rateLimits) {
                $rls = foreach ($r in $m.rateLimits) {
                    $rlObj = [RateLimit]::new()
                    $rlObj.key = $r.key
                    $rlObj.renewalPeriod = $r.renewalPeriod
                    $rlObj.count = $r.count
                    $rlObj
                }
                $model.rateLimits = $rls
            }

            # Costs
            if ($m.costs) {
                $costObjs = foreach ($c in $m.costs) {
                    $cObj = [Cost]::new()
                    $cObj.name = $c.name
                    $cObj.meterId = $c.meterId
                    $cObj.unit = $c.unit
                    $cObj
                }
                $model.costs = $costObjs
            }

            # Capabilities
            if ($m.capabilities) {
                $cap = [Capability]::new()
                $cap.chatCompletion = [bool]$m.capabilities.chatCompletion
                $cap.assistants = [bool]$m.capabilities.assistants
                $cap.fineTune = [bool]$m.capabilities.fineTune
                $cap.audio = [bool]$m.capabilities.audio
                $cap.realtime = [bool]$m.capabilities.realtime
                $cap.jsonObjectResponse = [bool]$m.capabilities.jsonObjectResponse
                $cap.jsonSchemaResponse = [bool]$m.capabilities.jsonSchemaResponse
                $model.capabilities = $cap
            }

            # System Data
            if ($m.systemData) {
                $sd = [SystemData]::new()
                $sd.createdBy = $m.systemData.createdBy
                $sd.createdByType = $m.systemData.createdByType
                if ($m.systemData.createdAt) { $sd.createdAt = [datetime]$m.systemData.createdAt }
                $sd.lastModifiedBy = $m.systemData.lastModifiedBy
                $sd.lastModifiedByType = $m.systemData.lastModifiedByType
                if ($m.systemData.lastModifiedAt) { $sd.lastModifiedAt = [datetime]$m.systemData.lastModifiedAt }
                $model.systemData = $sd
            }

            $models += $model
        }
    }
    else {
        Write-Warning "No model data returned from service. Raw response: $($resp.Content)"
    }

    if ($models.Count -gt 0) {
    # Exclude deprecated models
    $originalCount = $models.Count
    $models = $models | Where-Object { $_.lifecycleStatus -notmatch '^Deprecated$' }
    $removed = $originalCount - $models.Count
    if ($removed -gt 0) { Write-Host "Excluded $removed deprecated model(s)." -ForegroundColor DarkYellow }
    # Exclude models whose name contains 'audio'
    $preAudioCount = $models.Count
    $models = $models | Where-Object { $_.name -notmatch '(?i)audio' }
    $audioRemoved = $preAudioCount - $models.Count
    if ($audioRemoved -gt 0) { Write-Host "Excluded $audioRemoved audio model(s)." -ForegroundColor DarkYellow }
        Write-Host "Azure OpenAI Models ($($models.Count)):" -ForegroundColor Cyan
        $models |
            Select-Object @{n='Name';e={$_.name}},
                          @{n='Version';e={$_.version}},
                          @{n='Format';e={$_.format}},
                          @{n='Default';e={$_.isDefaultVersion}},
                          @{n='Lifecycle';e={$_.lifecycleStatus}},
                          @{n='Deprecation';e={ if ($_.deprecationDate) { $_.deprecationDate.ToString('u') } else { '' }}},
                          @{n='Chat';e={ if ($_.capabilities) { $_.capabilities.chatCompletion } }},
                          @{n='Assist';e={ if ($_.capabilities) { $_.capabilities.assistants } }},
                          @{n='FineTune';e={ if ($_.capabilities) { $_.capabilities.fineTune } }},
                          @{n='Realtime';e={ if ($_.capabilities) { $_.capabilities.realtime } }} |
            Sort-Object Name, Version |
            Format-Table -AutoSize | Out-String | Write-Host
    }

    return $models
}

function Get-AoaiModelAvailableQuota {
    [CmdletBinding()]
    param(
        # Your existing Cognitive Services account (Azure OpenAI resource)
        [Parameter(Mandatory=$true)] [string] $ResourceGroupName,
        [Parameter(Mandatory=$true)] [string] $AccountName,

        # The model you want to check
        [Parameter(Mandatory=$true)] [string] $ModelName,      # e.g. "o3-pro"
        [Parameter(Mandatory=$true)] [string] $ModelVersion,   # e.g. "v2025-06-10"

        # Optional: override (defaults to 'OpenAI')
        [Parameter()] [ValidateSet('OpenAI')] [string] $ModelFormat = 'OpenAI',

        # Optional: limit to a specific location or list all
        [Parameter()] [string] $Location,
        [switch] $AllRegions
    )

    # 1) Resolve the account to get subscription + default location
    $acct = Get-AzCognitiveServicesAccount -ResourceGroupName $ResourceGroupName -Name $AccountName -ErrorAction Stop
    $subscriptionId = ($acct.Id -split '/')[2]
    if (-not $Location) { $Location = $acct.Location }

    # 2) Build and call the Model Capacities - List management API
    $apiVersion = '2024-10-01'
    function _Encode([string]$v) { [System.Uri]::EscapeDataString($v) }
    $relPath = "/subscriptions/$subscriptionId/providers/Microsoft.CognitiveServices/modelCapacities?api-version=$apiVersion&modelFormat=$(_Encode $ModelFormat)&modelName=$(_Encode $ModelName)&modelVersion=$(_Encode $ModelVersion)"
    $resp = Invoke-AzRestMethod -Method GET -Path $relPath -ErrorAction Stop
    $payload = $resp.Content | ConvertFrom-Json

    if (-not $payload.value) {
        Write-Warning "No capacity entries returned. Check model name/version/format and permissions."
        return
    }

    # 3) Filter for the account's location unless -AllRegions is used
    $rows = if ($AllRegions) {
        $payload.value
    } else {
        $payload.value | Where-Object { $_.location -ieq $Location }
    }

    if (-not $rows) {
        Write-Warning "No matching capacity found for location '$Location'. Try -AllRegions to see other regions."
        return
    }

    # 4) Emit a clean object (one row per SKU per region)
    #    Exclude SKUs ending in 'Batch'
    $rows = $rows | Where-Object { $_.properties.skuName -notmatch 'Batch$' }
    if (-not $rows) { Write-Verbose "All entries excluded after removing *Batch SKUs."; return }
    #    Filter out zero-capacity entries
    $rows = $rows | Where-Object { ([int]$_.properties.availableCapacity) -gt 0 }
    if (-not $rows) {
       Write-Verbose "All capacity entries had zero AvailableCapacity after filtering."; return
    }
    $rows | ForEach-Object {
        [pscustomobject]@{
            SubscriptionId     = $subscriptionId
            Location           = $_.location
            SkuName            = $_.properties.skuName
            ModelFormat        = $_.properties.model.format
            ModelName          = $_.properties.model.name
            ModelVersion       = $_.properties.model.version
            AvailableCapacity  = $_.properties.availableCapacity
            # Some APIs also return availableFinetuneCapacity; include if needed:
            AvailableFineTuneCapacity = $_.properties.availableFinetuneCapacity
        }
    } | Sort-Object Location, SkuName
}
# --- Script Entry Point ---

Ensure-PsGalleryTrusted
Ensure-Module -Name Az.Accounts -MinVersion '2.12.0'
Ensure-Module -Name Az.Resources
Ensure-Module -Name Az.CognitiveServices

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

Write-Host "Using initial values: Subscription=$SubscriptionId RG=$ResourceGroup Location=$Location ModelPrefix=$ModelName PreferredSKUs=$($PreferredSkus -join ',')"

# If account name absent attempt lightweight discovery or create deterministic default
if (-not $AccountName) {
    # Derive a deterministic account name (respect 64 char limit & allowed chars)
    $hash = ([System.BitConverter]::ToString((New-Guid).ToByteArray()) -replace '-','').Substring(0,8).ToLower()
    $AccountName = "todoapp-openai-$hash"
    Write-Host "Derived Azure OpenAI account name: $AccountName" -ForegroundColor Cyan
    azd env set AZURE_OPENAI_ACCOUNT_NAME $AccountName | Out-Null
}

# --- Main Flow ---
Set-AzLoginContext
Ensure-OpenAIAccount -SubId $SubscriptionId -Rg $ResourceGroup -Acct $AccountName -Loc $Location

Write-Host "Enumerating models for account '$AccountName' in region '$Location'..." -ForegroundColor Cyan
$enum = Get-AccountModelsMultiVersion -SubId $SubscriptionId -Rg $ResourceGroup -Acct $AccountName
$allQuota = @()
$enum | ForEach-Object {
    $fmt = if ([string]::IsNullOrWhiteSpace($_.format)) { 'OpenAI' } else { $_.format }
    try {
    Write-Host "  Getting quota for model '$($_.name)' version '$($_.version)'..." -ForegroundColor DarkCyan
        $quota = Get-AoaiModelAvailableQuota -ResourceGroupName $ResourceGroup -AccountName $AccountName -ModelName $_.name -ModelVersion $_.version -ModelFormat $fmt -ErrorAction Stop
        if ($quota) { $allQuota += $quota }
    }
    catch {
        Write-Warning "  Failed to retrieve quota for model '$($_.name)' version '$($_.version)': $($_.Exception.Message)"
    }
}

if ($allQuota.Count -gt 0) {
    Write-Host "\nAzure OpenAI Model Capacity (combined)" -ForegroundColor Cyan
    $allQuota | Sort-Object -Property @{Expression={ [int]$_.AvailableCapacity }; Descending=$true}, @{Expression={$_.ModelVersion}; Descending=$true} | Select-Object @{n='Model';e={$_.ModelName}}, @{n='Version';e={$_.ModelVersion}}, Location, SkuName, @{n='Available';e={[int]$_.AvailableCapacity}} | Format-Table -AutoSize | Out-String | Write-Host

    #TODO - Selection logic here - currently just picks the first available model
    $selected = $allQuota | Sort-Object -Property @{Expression={ [int]$_.AvailableCapacity }; Descending=$true}, @{Expression={$_.ModelVersion}; Descending=$true} | Select-Object -First 1
    $SelectedModelVersion = $selected.ModelVersion
    $SelectedModelSku = $selected.SkuName
    $SelectedModelCapacity = $selected.AvailableCapacity
    $ModelName = $selected.ModelName
    Write-Host "Selected model: $ModelName version $SelectedModelVersion SKU $SelectedModelSku with $SelectedModelCapacity available capacity." -ForegroundColor Green
    
    # Persist outputs for Bicep (param names match environment variable names azd will inject)
    azd env set chatGptDeploymentVersion $SelectedModelVersion | Out-Null
    azd env set chatGptSkuName $SelectedModelSku | Out-Null
    azd env set chatGptModelName $ModelName | Out-Null
    azd env set chatGptDeploymentCapacity $SelectedModelCapacity | Out-Null

    Write-Host "Environment updated: chatGptDeploymentVersion=$SelectedModelVersion chatGptSkuName=$SelectedModelSku" -ForegroundColor Cyan

    exit 0

} else {
    Write-Host "No quota data collected." -ForegroundColor DarkGray
}