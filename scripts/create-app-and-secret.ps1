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

# Create an Azure AD Application Registration for the App if it doesn't exist
$app = Get-AzADApplication -DisplayName $appName

if (-not $app) {
    Write-Output "Application not found. Creating a new Azure AD Application Registration..."
    New-AzADApplication -DisplayName $appName
    
    # Wait for 5 seconds to ensure the application is created
    Start-Sleep -Seconds 5
    
    # Fetch the Azure AD application registration by display name again
    $app = Get-AzADApplication -DisplayName $appName

    # Create a Service Principal for the Application
    $sp = New-AzADServicePrincipal -ApplicationId $app.AppId

    # Create a Client Secret
    $password = New-AzADSpCredential -ObjectId $sp.Id -EndDate (Get-Date).AddYears(1)

    # Output the Values
    $apiAppId = $app.AppId
    $clientSecret = $password.SecretText

    # Set environment variables
    [System.Environment]::SetEnvironmentVariable('CLIENT_ID', $apiAppId, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable('CLIENT_SECRET', $clientSecret, [System.EnvironmentVariableTarget]::Process)

    Write-Output "CLIENT_ID: $apiAppId"
    Write-Output "CLIENT_SECRET: $clientSecret"

} else {
    Write-Error "Application already exists. Please run the update-app.ps1 script to update the Azure AD Application Registration once the web app has been created."
}