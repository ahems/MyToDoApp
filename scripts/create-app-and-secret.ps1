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

# Variables
$appName = "MyToDoApp"

# Set environment variables used by Bicep Templates
$NAME = azd env get-value 'NAME'
$OBJECT_ID = azd env get-value 'OBJECT_ID'

if($NAME -ceq "ERROR: key 'NAME' not found in the environment values" -or $OBJECT_ID -ceq "ERROR: key 'OBJECT_ID' not found in the environment values") {
    Write-Output "Setting NAME and OBJECT_ID environment variables..."
    # Get the signed-in user's principal name (email)
    $NAME = (Get-AzContext).Account.Id
    azd env set 'NAME' $NAME

    # Get the signed-in user's object ID
    $OBJECT_ID = (Get-AzADUser -SignedIn).Id
    azd env set 'OBJECT_ID' $OBJECT_ID
}

# Create an Azure AD Application Registration for the App if it doesn't exist
$app = Get-AzADApplication -DisplayName $appName -ErrorAction Stop

if (-not $app) {
    Write-Output "Application not found. Creating a new Azure AD Application Registration..."
    New-AzADApplication -DisplayName $appName
    
    # Wait for 5 seconds to ensure the application is created
    Start-Sleep -Seconds 5
    
    # Fetch the Azure AD application registration by display name again
    $app = Get-AzADApplication -DisplayName $appName

    # Create a Service Principal for the Application
    $sp = New-AzADServicePrincipal -ApplicationId $app.AppId

    # Create a Client Secret
    $password = New-AzADSpCredential -ObjectId $sp.Id -EndDate (Get-Date).AddYears(1)

    # Output the Values
    $apiAppId = $app.AppId
    $clientSecret = $password.SecretText

    # Set environment variables
    azd env set 'CLIENT_ID' $apiAppId
    azd env set 'CLIENT_SECRET' $clientSecret

    Write-Output "Azure AD Application Registration and Service Principal created successfully."
} else {
    Write-Output "Application already exists - nothing to do."
}