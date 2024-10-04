# Install Azure PowerShell if not already installed
if (-not (Get-Module -ListAvailable -Name Az)) {
    Install-Module -Name Az -AllowClobber -Scope CurrentUser
}

# Read TenantId and SubscriptionId from environment variables
$tenantId = (Get-Item -Path Env:TENANT_ID).Value
$subscriptionId = (Get-Item -Path Env:SUBSCRIPTION_ID).Value

# Check if the environment variables are set
if (-not $tenantId) {
    Write-Error "TENANT_ID environment variable is not set. Please set the environment variable and try again using the following command: $env:TENANT_ID = <your EntraID>" 
    exit 1
}

if (-not $subscriptionId) {
    Write-Error "SUBSCRIPTION_ID environment variable is not set.. Please set the environment variable and try again using the following command: $env:SUBSCRIPTION_ID = <your SUBSCRIPTION_ID>"
    exit 1
}

# Login to Azure
Connect-AzAccount -TenantId $tenantId
Set-AzContext -SubscriptionId $subscriptionId -TenantId $tenantId -Name "MyContext" -Force
# Get the list of all Resource Providers
$resourceProviders = Get-AzResourceProvider -ListAvailable

# Loop through each Resource Provider and register if not registered
foreach ($provider in $resourceProviders) {

    if ($provider.ProviderNamespace -eq "Wandisco.Fusion") {
        Write-Output "Skipping $($provider.ProviderNamespace)"
        continue
    }

    if ($provider.RegistrationState -ne "Registered") {
        Write-Output "Registering $($provider.ProviderNamespace)"
        Register-AzResourceProvider -ProviderNamespace $provider.ProviderNamespace -ErrorAction SilentlyContinue
    }
}
