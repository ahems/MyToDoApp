param acrTaskName string = 'buildAPIApp'
param taskBuildVersionTag string = uniqueString(utcNow())
param acrName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param location string = resourceGroup().location
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param contextPath string = 'https://github.com/ahems/MyToDoApp.git#main:api'
param repoName string = 'todoapi'
param useAuthorization bool = true
param containerGroupName string = 'cg-${uniqueString(acrTaskName)}'

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource acrTask 'Microsoft.ContainerRegistry/registries/tasks@2019-06-01-preview' = {
  parent: acr
  location: location
  name: acrTaskName
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${azidentity.id}': {}
    }
  }
  properties: {
    platform: {
      os: 'Linux'
      architecture: 'amd64'
    }
    step: {
      dockerFilePath: './dockerfile'
      contextPath: contextPath
      type: 'Docker'
      arguments: [
        {
          name: 'USE_AUTH'
          value: '${useAuthorization}'
        }
      ]
      isPushEnabled: true
      noCache: false
      imageNames: [
        '${acr.properties.loginServer}/${repoName}:${taskBuildVersionTag}'
      ]
    }
    trigger: {
      baseImageTrigger: {
        name: 'RuntimeBaseImageTrigger'
        baseImageTriggerType: 'Runtime'
        status: 'Enabled'
      }
    }
  }
}

// Run a CLI script to manually kick off the tasks that build the web and API apps in the ACR
resource runTask 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'acr-task-run-script-${acrTaskName}'
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
    azPowerShellVersion: '7.0.0'
    containerSettings: {
      containerGroupName: containerGroupName
    }
    environmentVariables: [
      {
        name: 'REGISTRY_NAME'
        value: acr.name
      }
      {
        name: 'TASK_NAME'
        value: acrTaskName
      }
      { 
        name: 'SUBSCRIPTION_ID'
        value: subscription().subscriptionId
      }
      { 
        name: 'RESOURCE_GROUP_NAME'
        value: resourceGroup().name
      }
    ]
    scriptContent: '''
    # az acr task run --name $TASK_NAME --registry $REGISTRY_NAME --no-logs --no-wait

    $apiVersion = "2019-04-01"
    $uri = "https://management.azure.com/subscriptions/$env:SUBSCRIPTION_ID/resourceGroups/$env:RESOURCE_GROUP_NAME/providers/Microsoft.ContainerRegistry/registries/$env:REGISTRY_NAME/scheduleRun?api-version=$apiVersion"
    $body = @{
        taskName = $env:TASK_NAME
        type = "TaskRunRequest"
        platform = @{
          os = "Linux"
          architecture = "amd64"
        }
    } | ConvertTo-Json
    $secureToken = (Get-AzAccessToken -AsSecureString).Token
    $ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    try {
      $token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)
      Invoke-RestMethod -Method Post -Uri $uri -Headers @{Authorization = "Bearer $token"} -ContentType "application/json" -Body $body
    } catch {
        Write-Error "An error was caught and swallowed: $_"
    } finally {
      [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ssPtr)
    }
    '''
    timeout: 'PT5M'
    cleanupPreference: 'OnSuccess'
  }
  dependsOn: [
    acrTask
  ]
}
