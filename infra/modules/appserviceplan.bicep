param appServicePlanName string = 'todoapp-asp-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param appServicePlanSku string = 'B1'

resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: appServicePlanSku
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}
