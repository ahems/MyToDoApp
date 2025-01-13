using 'deploy.bicep'

param aadAdminLogin = readEnvironmentVariable('NAME')
param aadAdminObjectId = readEnvironmentVariable('OBJECT_ID')
param webAppClientSecret = readEnvironmentVariable('CLIENT_SECRET')
param webAppClientId = readEnvironmentVariable('CLIENT_ID')
param restoreOpenAi = true
param useFreeLimit = true
