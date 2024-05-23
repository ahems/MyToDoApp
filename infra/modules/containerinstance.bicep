param aciName string = 'todoapp-ci-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param aciDnsLabel string = 'todoapp${uniqueString(resourceGroup().id)}'
param containerRegistryName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param imageNameAndVersion string = 'mytodoapp:latest'
param aciImage string = '${containerRegistryName}.azurecr.io/${imageNameAndVersion}'
param aciCpuCores int = 1
param aciMemoryGb int = 1

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: identityName
  location: location
}

resource aci 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: aciName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {}
  }
  properties: {
    imageRegistryCredentials: [
      {
        identity: 'string'
        identityUrl: 'string'
        password: 'string'
        server: 'string'
        username: 'string'
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
              name: 'string'
              secureValue: 'string'
              value: 'string'
            }
          ]
          image: aciImage
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
