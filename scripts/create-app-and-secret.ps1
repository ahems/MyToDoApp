# Install Azure PowerShell if not already installed
if (-not (Get-Module -ListAvailable -Name Az)) {
    Install-Module -Name Az -AllowClobber -Scope CurrentUser
}

# Read TenantId and SubscriptionId from environment variables
$tenantId = (Get-Item -Path Env:TENANT_ID).Value
$subscriptionId = (Get-Item -Path Env:SUBSCRIPTION_ID).Value
$resourceGroupName = (Get-Item -Path Env:RESOURCE_GROUP).Value

# Check if the environment variables are set
if (-not $tenantId) {
    Write-Error "TENANT_ID environment variable is not set."
    exit 1
}

if (-not $subscriptionId) {
    Write-Error "SUBSCRIPTION_ID environment variable is not set."
    exit 1
}
if (-not $resourceGroupName) {
    Write-Error "RESOURCE_GROUP environment variable is not set."
    exit 1
}

# Login to Azure
Connect-AzAccount -TenantId $tenantId
Set-AzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Name "MyContext" -Force

# Variables
$appName = "MyToDoApp"

# Create an Azure AD Application Registration if it doesn't exist
$app = Get-AzADApplication -DisplayName $appName

if (-not $app) {
    Write-Output "Application not found. Creating a new Azure AD Application Registration..."
    New-AzADApplication -DisplayName $appName -IdentifierUris "https://$appName"
    
    # Wait for 5 seconds to ensure the application is created
    Start-Sleep -Seconds 5
    
    # Fetch the Azure AD application registration by display name again
    $app = Get-AzADApplication -DisplayName $appName
}

# Look up the default URL of the first web app in the resource group that begins with "todoapp-webapp-web-"
$webApp = Get-AzWebApp -ResourceGroupName $resourceGroupName | Where-Object { $_.Name -like "todoapp-webapp-web-*" } | Select-Object -First 1

if ($webApp) {
    #Set the reply URL
    Set-AzADApplication -ObjectId $app.Id -ReplyUrls "https://$($webApp.DefaultHostName)/getAToken"
} else {
    Write-Error "No web app found in the resource group $resourceGroupName that begins with 'todoapp-webapp-web-'"
}

# Check if the Service Principal already exists
$sp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction SilentlyContinue

if ($sp) {
    Write-Output "Service Principal already exists. Skipping creation of Client Secret."
} else {
    
    # Create a Service Principal for the Application
    $sp = New-AzADServicePrincipal -ApplicationId $app.AppId

    # Create a Client Secret
    $password = New-AzADSpCredential -ObjectId $sp.Id -EndDate (Get-Date).AddYears(1)

    # Output the Values
    $clientId = $app.AppId
    $clientSecret = $password.SecretText
    $authority = "https://login.microsoftonline.com/$tenantId"

    Write-Output "CLIENTID: $clientId"
    Write-Output "CLIENTSECRET: $clientSecret"
    Write-Output "AUTHORITY: $authority"

    $env:AUTHORITY = $authority
    $env:CLIENTID = $clientId
    $env:CLIENTSECRET = $clientSecret
}