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

# Ensure Az.Resources (provides Get-AzADApplication / New-AzADApplication) is installed
if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
    Write-Output "Installing Az.Resources module..."
    Install-Module Az.Resources -Scope CurrentUser -Force -Confirm:$false
}

# Import required module
Import-Module Az.Resources -ErrorAction Stop

# Get tenant ID from azd environment
$tenantId = azd env get-value 'TENANT_ID'

$SubscriptionId = azd env get-value 'AZURE_SUBSCRIPTION_ID'
if( $SubscriptionId ) {
    Update-AzConfig -DefaultSubscriptionForLogin $SubscriptionId
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

# Get Redirect URI from azd environment
$redirectUrl = (azd env get-value 'APP_REDIRECT_URI' 2>$null).Trim()

if( $redirectUrl -ceq "ERROR: key 'APP_REDIRECT_URI' not found in the environment values") {
    Write-Error "APP_REDIRECT_URI not found in azd environment. Please ensure your infrastructure has been provisioned correctly."
    exit 1
} else {
    Write-Output "Using APP_REDIRECT_URI: $redirectUrl"
}

# Variables
$appName = "MyToDoApp"

# Get Azure AD Application Registration for the App
Write-Output "Retrieving Azure AD Application Registration for $appName..."
$app = Get-AzADApplication -DisplayName $appName -ErrorAction Stop

if ($app) {
    Write-Output "Application $appName found. Updating the Azure AD Application Registration..."

    # Update reply URLs (redirect URIs) using Az module
    Set-AzADApplication -ObjectId $app.Id -ReplyUrls @("$redirectUrl/getAToken", "http://localhost:5000/getAToken") | Out-Null

} else {
    Write-Error "Application not found. Please run the create-app-and-secret.ps1 script to create the Azure AD Application Registration."
}