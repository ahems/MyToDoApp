param appInsightsName string = 'todoapp-appinsights-${toLower(uniqueString(resourceGroup().id))}'
param aciName string = 'todoapp-ci-${uniqueString(resourceGroup().id)}'
param keyVaultName string = 'todoapp-kv-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param aciDnsLabel string = 'todoapp${uniqueString(resourceGroup().id)}'
param containerRegistryName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param imageNameAndVersion string = 'mytodoapp:latest'
param aciImage string = '${containerRegistryName}.azurecr.io/${imageNameAndVersion}'
param aciCpuCores int = 1
param aciMemoryGb int = 1

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: identityName
}

resource acr 'Microsoft.ContainerRegistry/registries@2022-12-01' existing = {
  name: containerRegistryName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource aci 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: aciName
  location: location
  dependsOn: [acr]
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${azidentity.id}': {}
    }
  }
  properties: {
    imageRegistryCredentials: [
      {
        server: '${containerRegistryName}.azurecr.io'
        username: acr.listCredentials().username  
        password: acr.listCredentials().passwords[0].value
      }
    ]
    osType: 'Linux'
    restartPolicy: 'Never'
    ipAddress: {
      type: 'Public'
      dnsNameLabel: aciDnsLabel
      ports: [
        {
          protocol: 'TCP'
          port: 80
        }
      ]
    }
    containers: [
      {
        name: 'todoapp'
        properties: {
          environmentVariables: [
            {
              name: 'KEY_VAULT_NAME'
              value: keyVaultName
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: azidentity.properties.clientId
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsights.properties.ConnectionString
            }
            {
              name: 'API_URL'
              value: 'add value here'
            }
          ]
          image: aciImage
          ports: [
            {
              port: 80
              protocol: 'TCP'
            }
          ]
          resources: {
            requests: {
              cpu: aciCpuCores
              memoryInGB: aciMemoryGb
            }
          }
        }
      }
    ]
  }
}
