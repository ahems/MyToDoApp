param client_app_name string = 'todoapp-webapp-web-${uniqueString(resourceGroup().id)}'
param identityName string = 'todoapp-identity-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location

var websiteContributorRoleID = 'de139f84-1756-47ae-9be6-808fbbe84772'

resource azidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

// Apply Application Administrator Role to MI so it can create app registrations
resource ApplicationAdministratorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', websiteContributorRoleID) // Website Contributor role
    principalId: azidentity.properties.principalId
  }
}

resource createAppRegistrationScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'client-app-registration-script-${client_app_name}'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${azidentity.id}': {}
    }
  }
  properties: {
    retentionInterval: 'P1D'
    azCliVersion: '2.64.0'
    environmentVariables: [
      {
        name: 'CLIENT_APP_NAME'
        value: client_app_name
      }
    ]
    scriptContent: '''
      #!/bin/bash
      set -e
      app=$(az ad app list --display-name $CLIENT_APP_NAME --query "[0]")

      if [ -z "$app" ]; then
      echo "Application not found. Creating a new Azure AD Application Registration...";
      app=$(az ad app create --display-name $CLIENT_APP_NAME);
      echo $app | jq -r '.appId';
      else
      echo "Application found. Skipping creation...";
      fi
    '''
    timeout: 'PT30M'
    cleanupPreference: 'OnSuccess'
  }
}
