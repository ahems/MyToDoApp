param webAppName string = 'todoapp-webapp-web-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param containerRegistryName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param containerGroupName string = 'cg-${uniqueString(webAppName)}'
param imageNameAndVersion string = 'todoapp:latest'
param acrWebhookName string = 'todoappwebhook'

var websiteContributorRoleID = 'de139f84-1756-47ae-9be6-808fbbe84772'

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
}

resource webApp 'Microsoft.Web/sites@2024-04-01' existing = {
  name: webAppName
}

// Apply website Contributor Role to MI so we can run our custom Script using it
resource websiteContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid(webApp.id)
  scope: webApp
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', websiteContributorRoleID) // Website Contributor role
    principalId: azidentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Run a AZ CLI script to configure continuous deployment for the web app and then create a webhook for the ACR. (No way I could find to do this in Powershell unfortunately)
resource configureContinuousDeployment 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'cd-config-script-${webApp.name}'
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${azidentity.id}': {}
    }
  }
  properties: {
    retentionInterval: 'PT60M'
    azPowerShellVersion: '11'
    containerSettings: {
      containerGroupName: containerGroupName
    }
    environmentVariables: [
      {
        name: 'WEBAPP_NAME'
        value: webApp.name
      }
      {
        name: 'RESOURCE_GROUP_NAME'
        value: resourceGroup().name
      }
      {
        name: 'WEBHOOK_NAME'
        value: acrWebhookName
      }
      {
        name: 'REGISTRY_NAME'
        value: acr.name
      }
      {
        name: 'IMAGE_NAME'
        value: imageNameAndVersion
      }
      {
        name: 'LOCATION'
        value: location
      }
      {
        name: 'SUBSCRIPTION_ID'
        value: subscription().subscriptionId
      }
      {
        name: 'RESOURCE_MANAGER_ENDPOINT'
        value: environment().resourceManager
      }
    ]
    scriptContent: '''
      # URI=$(az webapp deployment container config --enable-cd true --name $WEBAPP_NAME --resource-group $RESOURCE_GROUP_NAME --query CI_CD_URL --output tsv)
      # az acr webhook create --name $WEBHOOK_NAME --registry $REGISTRY_NAME --uri $URI --actions push --scope $IMAGE_NAME

      $subscriptionId = $env:SUBSCRIPTION_ID
      $resourceGroupName = $env:RESOURCE_GROUP_NAME
      $registryName = $env:REGISTRY_NAME
      $webhookName = $env:WEBHOOK_NAME
      $webAppName = $env:WEBAPP_NAME
      $location = $env:LOCATION
      $imageName = $env:IMAGE_NAME
      $resourceManagerEndpoint = $env:RESOURCE_MANAGER_ENDPOINT.TrimEnd('/')

      $uri = "$resourceManagerEndpoint/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/sites/$webAppName/config/publishingcredentials/list?api-version=2023-01-01"
      Write-Output $uri
      
      $acruri = "$resourceManagerEndpoint/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.ContainerRegistry/registries/$registryName/webhooks/$webhookName?api-version=2023-11-01-preview"
      Write-Output $acruri

      $secureToken = (Get-AzAccessToken -AsSecureString).Token
      $ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
      
      try {

        $token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)

        $headers = @{
          "Authorization" = "Bearer $token"
          "Content-Type"  = "application/json"
        }

        Write-Output "Enabling CD for $webAppName..."
        $result = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers
        Write-Debug $result

        $serviceUri = $result.properties.scmUri + "/docker/hook"

        $body = @{
            location = "$location"
            properties = @{
              serviceUri = "$serviceUri"
              status = "enabled"
              scope = "$imageName"
              actions = @("push")
            }
        } | ConvertTo-Json

        Write-Output "Creating Web Hook on ACR for $webAppName"
        $result2 = Invoke-RestMethod -Uri $acruri -Method PUT -Headers $headers -Body $body
        Write-Debug $result2

      } catch {
        Write-Error "An error was caught and swallowed: $_"
      } finally {
          [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ssPtr)
      }

    '''
    timeout: 'PT5M'
    cleanupPreference: 'OnSuccess'
  }
}
