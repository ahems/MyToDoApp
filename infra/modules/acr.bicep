param acrName string = 'todoappacr${toLower(uniqueString(resourceGroup().id))}'

resource acr 'Microsoft.ContainerRegistry/registries@2022-12-01' = {
  name: acrName
  location: resourceGroup().location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
    zoneRedundancy: 'Disabled'
  }
}

output name string = acr.name
