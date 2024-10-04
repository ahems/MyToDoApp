#!/usr/bin/env pwsh

# Log in to Azure using device code
Write-Output "Logging in to Azure..."
az login --tenant 16b3c013-d300-468d-ac64-7eda0820b6d3

# Set the subscription
az account set --subscription f7ce92eb-2ba4-4e2b-873b-7cb3f12abdd9

# List available resource groups
Write-Output "Available Resource Groups:"
az group list --query '[].{Name:name, Location:location}' -o table

# Prompt the user to select a resource group
$resourceGroupName = Read-Host -Prompt "Enter the name of the resource group you want to use"

# Check if the resource group exists
$rgExists = az group exists --name $resourceGroupName

if ($rgExists -eq "false") {
    Write-Output "Resource group $resourceGroupName does not exist."
    exit 1
}

# Get the name of the first ACR in the resource group
$acrName = az acr list --resource-group $resourceGroupName --query '[0].name' -o tsv

# Check if an ACR was found
if (-not $acrName) {
    Write-Output "No ACR found in resource group $resourceGroupName"
    exit 1
}

# Run the ACR task
az acr task run --name buildWebApp --registry $acrName
az acr task run --name buildAPIApp --registry $acrName