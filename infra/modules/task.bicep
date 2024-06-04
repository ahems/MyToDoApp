param acrTaskName string = 'build-todo-app'
param taskBuildVersionTag string = uniqueString(utcNow())
param acrName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param location string = resourceGroup().location
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
@secure()
param contextAccessToken string
param contextPath string


resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: identityName
}
resource acr 'Microsoft.ContainerRegistry/registries@2022-12-01' existing = {
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
      contextAccessToken: contextAccessToken
      dockerFilePath: './dockerfile'
      contextPath: contextPath
      type: 'Docker'
      isPushEnabled: true
      noCache: false
      imageNames: [
        '${acr.properties.loginServer}/todoapp:${taskBuildVersionTag}'
      ]
    }
    trigger: {
      timerTrigger: {
        schedule: '0 0 * * *'
        status: 'Disabled'
      }
      sourceTriggers: [ 
        {
        sourceRepository: sourceRepository
        branch: 'main'
        repositoryUrl: repositoryUrl
        sourceControlType: 'Github'
        soruceControlAuthProperties: {
          token: contextAccessToken
        }
        sourceTriggerEvents: [
          'commit'
        ]
        status: 'Enabled'
      }
    }
    status: 'Enabled'
  }
}