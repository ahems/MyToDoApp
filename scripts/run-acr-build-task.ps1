#!/usr/bin/env pwsh

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
# Check if the resource group exists
$rgExists = az group exists --name $resourceGroupName

if ($rgExists -eq "false") {
    Write-Output "Resource group $resourceGroupName does not exist."
    exit 1
}

# Log in to Azure
Write-Output "Logging in to Azure..."
az login --tenant $tenantId

# Set the subscription
az account set --subscription $subscriptionId

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