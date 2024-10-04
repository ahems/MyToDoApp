param acrName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param location string = resourceGroup().location
param repositoryUrl string = 'https://github.com/ahems/MyToDoApp'
@secure()
param gitAccessToken string

module buildTaskForWeb 'modules/task.bicep' = {
  name: 'acrBuildTaskForWeb'
  params: {
    acrName: acrName
    location: location
    acrTaskName: 'buildWebApp'
    contextAccessToken: gitAccessToken
    contextPath: './'
    repositoryUrl: repositoryUrl
    repoName: 'todoapp'
    taskBuildVersionTag: 'latest'
  }
}

module buildTaskForAPI 'modules/task.bicep' = {
  name: 'acrBuildTaskForApi'
  params: {
    acrName: acrName
    location: location
    acrTaskName: 'buildAPIApp'
    contextAccessToken: gitAccessToken
    contextPath: './api'
    repositoryUrl: repositoryUrl
    repoName: 'todoapi'
    taskBuildVersionTag: 'latest'
  }
}
