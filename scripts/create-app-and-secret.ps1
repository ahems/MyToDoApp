# Check if the PowerShell version is at least 7
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "This script requires PowerShell 7 or above. Please upgrade your PowerShell version - https://aka.ms/PSWindows"
    exit
}

# Install Azure PowerShell if not already installed
if (-not (Get-Module -ListAvailable -Name Az)) {
    Install-Module -Name Az -AllowClobber -Scope CurrentUser
}

# Variables
$appName = "MyToDoApp"

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

# Create an Azure AD Application Registration if it doesn't exist
$app = Get-AzADApplication -DisplayName $appName

if (-not $app) {
    Write-Output "Application not found. Creating a new Azure AD Application Registration..."
    New-AzADApplication -DisplayName $appName
    
    # Wait for 5 seconds to ensure the application is created
    Start-Sleep -Seconds 5
    
    # Fetch the Azure AD application registration by display name again
    $app = Get-AzADApplication -DisplayName $appName
}

# Look up the default URL of the first web app in the resource group that begins with "todoapp-webapp-web-"
$webApp = Get-AzWebApp -ResourceGroupName $selectedResourceGroup | Where-Object { $_.Name -like "todoapp-webapp-web-*" } | Select-Object -First 1

if ($webApp) {
    #Set the reply URLs for the Azure AD Application
    Set-AzADApplication -ObjectId $app.Id -ReplyUrls @("https://$($webApp.DefaultHostName)/getAToken", "http://localhost:5000/getAToken")
    
} else {
    # Write-Error "No web app found in the resource group $selectedResourceGroup that begins with 'todoapp-webapp-web-'"
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

    Write-Output "CLIENT_ID: $clientId"
    Write-Output "CLIENT_SECRET: $clientSecret"

    $env:CLIENT_ID = $clientId
    $env:CLIENT_SECRET = $clientSecret
}