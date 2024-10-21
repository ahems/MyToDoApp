# Ensure Azure PowerShell module is installed and imported
if (-not (Get-Module -ListAvailable -Name Az)) {
    Install-Module -Name Az -AllowClobber -Scope CurrentUser
}
Import-Module Az

# Login to Azure
Connect-AzAccount

# Retrieve the list of resource groups
$resourceGroups = Get-AzResourceGroup

# Display the list of resource groups with numbers
Write-Output "Available Resource Groups:"
for ($i = 0; $i -lt $resourceGroups.Count; $i++) {
    Write-Output "$($i + 1). $($resourceGroups[$i].ResourceGroupName)"
}

# Prompt the user to select a resource group by entering a number
$selection = Read-Host "Enter the number of the resource group you want to select"

# Validate the input
if ($selection -match '^\d+$' -and $selection -gt 0 -and $selection -le $resourceGroups.Count) {
    $selectedResourceGroup = $resourceGroups[$selection - 1].ResourceGroupName
    Write-Output "You selected: $selectedResourceGroup"
} else {
    Write-Error "Invalid selection. Please run the script again and enter a valid number."
    exit
}

# Get the name of the first ACR in the resource group
$acrName = (Get-AzContainerRegistry -ResourceGroupName $selectedResourceGroup | Select-Object -First 1).Name

# Check if an ACR was found
if (-not $acrName) {
    Write-Output "No ACR found in resource group $selectedResourceGroup"
    exit 1
}
Write-Output "Found Azure Container Registry: $acrName"

# Run the ACR task
az acr task run --name buildWebApp --registry $acrName --no-logs --no-wait
az acr task run --name buildAPIApp --registry $acrName --no-logs --no-wait