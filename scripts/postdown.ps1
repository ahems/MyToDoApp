Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#############################################
# Helpers: PSGallery trust & Module handling
#############################################
function Set-PsGalleryTrusted {
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

function Import-ModuleIfNeeded {
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

function Remove-AzdValue {
    param([Parameter(Mandatory)][string]$Name)
    try {
        azd env unset $Name | Out-Null
    } catch {
        # Fallback if unset is unavailable
        azd env set $Name '' | Out-Null
    }
}

#############################################
# Azure Login Context
#############################################
function Connect-AzContextIfNeeded {
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
# Remove Entra ID (AAD) Application + SP
#############################################
function Remove-AppRegistration {
    [CmdletBinding()]
    param(
        [string]$ClientId,
        [string]$AppDisplayName = 'MyToDoApp'
    )

    $app = $null
    if ($ClientId) {
        Write-Host "Locating application by CLIENT_ID ($ClientId)..." -ForegroundColor Cyan
        $app = Get-AzADApplication -ApplicationId $ClientId -ErrorAction SilentlyContinue
    }
    if (-not $app) {
        Write-Host "CLIENT_ID not set or app not found by id; trying display name '$AppDisplayName'..." -ForegroundColor Yellow
        $app = Get-AzADApplication -DisplayName $AppDisplayName -ErrorAction SilentlyContinue
    }
    if (-not $app) {
        Write-Warning "No matching Azure AD application found to remove. Skipping."
        return
    }

    Write-Host "Found application: $($app.DisplayName) (AppId=$($app.AppId))" -ForegroundColor Green

    # Remove Service Principal first (if exists)
    $sp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction SilentlyContinue
    if ($sp) {
        Write-Host "Removing service principal: $($sp.DisplayName) (ObjectId=$($sp.Id))" -ForegroundColor DarkYellow
    try { Remove-AzADServicePrincipal -ObjectId $sp.Id -Confirm:$false -ErrorAction Stop } catch { Write-Warning "Failed to remove SP: $($_.Exception.Message)" }
        Start-Sleep -Seconds 2
    } else {
        Write-Host "No service principal found for application; continuing..." -ForegroundColor Gray
    }

    # Remove Application
    Write-Host "Removing application registration (ObjectId=$($app.Id))" -ForegroundColor DarkYellow
    try { Remove-AzADApplication -ObjectId $app.Id -Confirm:$false -ErrorAction Stop } catch { throw }

    Write-Host "Application registration removed." -ForegroundColor Green
}

#############################################
# MAIN EXECUTION FLOW
#############################################
Set-PsGalleryTrusted
Import-ModuleIfNeeded -Name Az.Accounts -MinVersion '2.12.0'
Import-ModuleIfNeeded -Name Az.Resources

$tenantId       = Get-AzdValue -Name 'TENANT_ID'
$subscriptionId = Get-AzdValue -Name 'AZURE_SUBSCRIPTION_ID'
Connect-AzContextIfNeeded -TenantId $tenantId -SubscriptionId $subscriptionId

$clientId = Get-AzdValue -Name 'CLIENT_ID'
$appDisplayName = 'MyToDoApp'

Remove-AppRegistration -ClientId $clientId -AppDisplayName $appDisplayName

# Clear env values now that app is gone
Remove-AzdValue -Name 'CLIENT_ID'
Remove-AzdValue -Name 'CLIENT_SECRET'

# Remove .env file generated by postup.ps1 for local debugging
try {
    $projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $envFile = Join-Path $projectRoot '.env'
    if (Test-Path -Path $envFile -PathType Leaf) {
        Write-Host "Removing generated .env file at $envFile" -ForegroundColor DarkCyan
        Remove-Item -Path $envFile -Force -ErrorAction Stop
        Write-Host ".env file removed." -ForegroundColor Green
    } else {
        Write-Host ".env file not present; nothing to remove." -ForegroundColor Gray
    }
} catch {
    Write-Warning "Failed to remove .env file: $($_.Exception.Message)"
}

Write-Host "postdown.ps1 completed (app registration & local artifact cleanup)." -ForegroundColor Cyan
