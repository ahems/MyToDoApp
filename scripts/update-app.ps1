# Check if the PowerShell version is at least 7
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "This script requires PowerShell 7 or above. Please upgrade your PowerShell version - https://aka.ms/PSWindows"
    exit
}

# Install Azure PowerShell if not already installed
if (-not (Get-Module -ListAvailable -Name Az)) {
    Install-Module -Name Az -AllowClobber -Scope CurrentUser
}

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Install-Module Microsoft.Graph -Scope CurrentUser
}

# Variables
$appName = "MyToDoApp"

# Login to Azure
Connect-AzAccount

# Get Azure AD Application Registration for the App
$app = Get-AzADApplication -DisplayName $appName

if ($app) {
    Write-Output "Application found. Updating the Azure AD Application Registration..."

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
    Write-Output "Finding Web app that begins with 'todoapp-webapp-web-'..."
    # Look up the default URL of the first web app in the resource group that begins with "todoapp-webapp-web-"
    $webApp = Get-AzWebApp -ResourceGroupName $selectedResourceGroup | Where-Object { $_.Name -like "todoapp-webapp-web-*" } | Select-Object -First 1

    if ($webApp) {
        #Set the reply URLs for the new Azure AD Application
        Write-Output "Web App found. Setting reply URL to https://$($webApp.DefaultHostName)/getAToken"
        Set-AzADApplication -ObjectId $app.Id -ReplyUrls @("https://$($webApp.DefaultHostName)/getAToken", "http://localhost:5000/getAToken") -LogoutUrl "https://$($webApp.DefaultHostName)/logout"
    } else {
        Write-Error "No web app found in the resource group $selectedResourceGroup that begins with 'todoapp-webapp-web-'"
    }
} else {
    Write-Error "Application not found. Please run the create-app-and-secret.ps1 script to create the Azure AD Application Registration."
}