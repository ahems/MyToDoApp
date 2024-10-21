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

# Get Web and API App Services
$webApp = Get-AzWebApp -ResourceGroupName $selectedResourceGroup | Where-Object { $_.Name -like "todoapp-webapp-web-*" } | Select-Object -First 1
$apiApp = Get-AzWebApp -ResourceGroupName $selectedResourceGroup | Where-Object { $_.Name -like "todoapp-webapp-api-*" } | Select-Object -First 1

if (-not $webApp) {
    Write-Error "No web app found in the resource group $selectedResourceGroup that begins with 'todoapp-webapp-web-'"
}
if (-not $apiApp) {
    Write-Error "No web app found in the resource group $selectedResourceGroup that begins with 'todoapp-webapp-api-'"
}

# Get the name of the first ACR in the resource group
$acrName = (Get-AzContainerRegistry -ResourceGroupName $selectedResourceGroup | Select-Object -First 1).Name

# Check if an ACR was found
if (-not $acrName) {
    Write-Output "No ACR found in resource group $selectedResourceGroup"
    exit 1
}
Write-Output "Found Azure Container Registry: $acrName"

# Get the ACR login server
$acrLoginServer = (Get-AzContainerRegistry -ResourceGroupName $selectedResourceGroup -Name $acrName).LoginServer

# Get the Id of the User Managed Identity
$userManagedIdentityId = (Get-AzUserAssignedIdentity -ResourceGroupName $selectedResourceGroup | Select-Object -First 1).ClientId
# Check if a User Managed Identity was found
if (-not $userManagedIdentityId) {
    Write-Output "No User Managed Identity found in resource group $selectedResourceGroup"
    exit 1
}

$blankPassword = $null

# Assign the User Managed Identity to the Web App
Set-AzWebApp -ResourceGroupName $selectedResourceGroup -Name $webApp.Name -AssignIdentity $true
# Update the Web App to use the User Managed Identity for pulling images from ACR
Set-AzWebApp -ResourceGroupName $selectedResourceGroup -Name $webApp.Name -ContainerRegistryUrl "https://$acrLoginServer" -ContainerRegistryUser $userManagedIdentityId -ContainerRegistryPassword $blankPassword

# Assign the User Managed Identity to the API App
Set-AzWebApp -ResourceGroupName $selectedResourceGroup -Name $apiApp.Name -AssignIdentity $true
# Update the API App to use the User Managed Identity for pulling images from ACR
Set-AzWebApp -ResourceGroupName $selectedResourceGroup -Name $apiApp.Name -ContainerRegistryUrl "https://$acrLoginServer" -ContainerRegistryUser $userManagedIdentityId -ContainerRegistryPassword $blankPassword

# Restart the Web App
Restart-AzWebApp -ResourceGroupName $selectedResourceGroup -Name $webApp.Name

# Restart the API App
Restart-AzWebApp -ResourceGroupName $selectedResourceGroup -Name $apiApp.Name