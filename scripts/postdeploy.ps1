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

    # Extract base URL from redirect URL (remove /getAToken)
    $baseUrl = $redirectUrl -replace '/getAToken$', ''
    
    # Update reply URLs (redirect URIs) and logout URL using Az module
    Set-AzADApplication -ObjectId $app.Id -ReplyUrls @("$redirectUrl/getAToken", "http://localhost:5000/getAToken") | Out-Null
    
    # Update logout URL
    Write-Output "Setting logout redirect URI to: $baseUrl"
    Update-AzADApplication -ObjectId $app.Id -Web @{ LogoutUrl = $baseUrl } | Out-Null

} else {
    Write-Error "Application not found. Please run the create-app-and-secret.ps1 script to create the Azure AD Application Registration."
}

# Update API Container App with APP_URL environment variable
Write-Output "Updating API Container App with APP_URL environment variable..."

# Get the API service name from azd environment
$apiServiceName = azd env get-value 'SERVICE_API_NAME'
$resourceGroupName = azd env get-value 'AZURE_RESOURCE_GROUP'

if ($apiServiceName -and $resourceGroupName) {
    Write-Output "API Service Name: $apiServiceName"
    Write-Output "Resource Group: $resourceGroupName"
    
    # Install Az.App module if not already installed (for Container Apps)
    if (-not (Get-Module -ListAvailable -Name Az.App)) {
        Write-Output "Installing Az.App module..."
        Install-Module Az.App -Scope CurrentUser -Force -Confirm:$false
    }
    
    Import-Module Az.App -ErrorAction Stop
    
    # Get the Container App
    $containerApp = Get-AzContainerApp -ResourceGroupName $resourceGroupName -Name $apiServiceName -ErrorAction SilentlyContinue
    
    if ($containerApp) {
        Write-Output "Found API Container App: $apiServiceName"
        
        # Extract base URL from redirect URL (this is the frontend app URL)
        $appUrl = $redirectUrl -replace '/getAToken$', ''
        Write-Output "Setting APP_URL to: $appUrl"
        
        # Update the Container App using az CLI with --set-env-vars
        # This command will add or update the APP_URL environment variable without affecting others
        Write-Output "Updating Container App environment variables..."
        az containerapp update `
            --name $apiServiceName `
            --resource-group $resourceGroupName `
            --set-env-vars "APP_URL=$appUrl" `
            --output none
        
        if ($LASTEXITCODE -eq 0) {
            Write-Output "Successfully updated APP_URL environment variable in API Container App."
        } else {
            Write-Error "Failed to update Container App environment variables. Exit code: $LASTEXITCODE"
        }
    } else {
        Write-Warning "API Container App '$apiServiceName' not found in resource group '$resourceGroupName'."
    }
} else {
    Write-Warning "SERVICE_API_NAME or AZURE_RESOURCE_GROUP not found in azd environment. Skipping API Container App update."
}