using 'deploy.bicep'

param aadAdminLogin = readEnvironmentVariable('EMAIL')
param aadAdminObjectId = readEnvironmentVariable('OBJECT_ID')
param repositoryUrl = readEnvironmentVariable('repositoryUrl')
param gitAccessToken = readEnvironmentVariable('gitAccessToken')
