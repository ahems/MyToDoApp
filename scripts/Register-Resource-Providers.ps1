# Check if the PowerShell version is at least 7
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "This script requires PowerShell 7 or above. Please upgrade your PowerShell version - https://aka.ms/PSWindows"
    exit
}

# Install Azure PowerShell if not already installed
if (-not (Get-Module -ListAvailable -Name Az)) {
    Install-Module -Name Az -AllowClobber -Scope CurrentUser
}

# Login to Azure
Connect-AzAccount

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
