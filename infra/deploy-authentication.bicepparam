using 'deploy-authentication.bicep'

param clientId = readEnvironmentVariable('CLIENT_ID')
param clientSecret = readEnvironmentVariable('CLIENT_SECRET')
