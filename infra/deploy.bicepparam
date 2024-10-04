using 'deploy.bicep'

param aadAdminLogin = readEnvironmentVariable('EMAIL')
param aadAdminObjectId = readEnvironmentVariable('OBJECT_ID')
