using 'deploy-acr-build-tasks.bicep'

param repositoryUrl = readEnvironmentVariable('repositoryUrl')
param gitAccessToken = readEnvironmentVariable('gitAccessToken')
