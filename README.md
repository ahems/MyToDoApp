# Deploying the ToDo App To Azure

## Option 1 - Deployment from Visual Studio Code

We can use Visual Studio Code to deploy the Bicep Scripts directly to Azure. Follow these steps:

* Clone the code from this [repository](https://github.com/ahems/MyToDoApp) to your own repo
* Create a PAT with Repo scope in your own repo and make a note of the secret value
* Set these environment variables:
  * gitAccessToken - use the value in the previous step
  * repositoryUrl - use the URL of your cloned GitHub repo
  * TENANT_ID - the GUID of the ID of your Entra ID tenant
  * SUBSCRIPTION_ID - the GUID of the ID of your Azure Subscription
  * RESOURCE_GROUP - the name of the Resource Group yuo will deploy to
  * EMAIL - your email address or get it by running (az account list | ConvertFrom-Json).user[1].name
  * OBJECT_ID - this is the ObjectID of your account in Entra ID. Get this value using: az ad user list --upn (az account list | ConvertFrom-Json).user[1].name) | ConvertFrom-Json).objectId
* Download the code from your cloned repo to your local machine
* (Optional) If your Azure subscription is new, run the "/scripts/Register-Resource-Providers.ps1" Powershell script from a Terminal in VS Code
* Right-Click on the file "/infra/deploy.bicep" and select "Deploy Bicep File...". Select or create the Resource Group for the name you set the RESOURCE_GROUP variable and the "deploy.bicepparam" parameters file. Wait for it to complete.
* Run the "/scripts/create-app-and-secret.ps1" Powershell script in a terminal in VS Code to create an App and Client Secret in your Entra ID tenant. Your deployed App will use to Authenticate users.
* Right-Click on the file "/infra/deploy-authentication.bicep" and select "Deploy Bicep File...". Select your previous Resource Group, use the "deploy-authentication.bicepparams" parameters file to use your local environment variables to set values in the KeyVault created in the previous step.
* Right-Click on the file "/infra/deploy-acr-build-tasks.bicep", select "Deploy Bicep File...". Select your previous Resource Group, the "/infra/deploy-acr-build-tasks.bicepparam" parameters file to create two tasks in your Azure Container Registry to build the apps and push them to the Container Registry.
* Run the "/scripts/run-acr-build-task.ps1" Powershell script in a terminal in VS Code to manually kick off the tasks created in the previous step. This will pull down the source code from your cloned GitHub repo, build it and push it to the Container Registry.

### Host in Web Apps

* Right-Click on the file "/infra/deploy-webapps.bicep", select "Deploy Bicep File...". Select your previous Resource Group, no parameters file and wait for it to complete. This will deploy the two Web Apps and set all necessary App Settings using the values from your KeyVault. NOTE: You may need to go to "Deployment Center" of each of your web apps and select the identity in the "Identity" drop-down if it's not already populated in order for the web apps to successfully pull the docker images from your Container registry.

### Host in Azure Container Apps

* Right-Click on the file "/infra/deploy-aca.bicep", select "Deploy Bicep File...". Select your previous Resource Group, no parameters file and wait for it to complete. This will deploy the two Web Apps and set all necessary App Settings using the values from your KeyVault.

### Configure Database

The next step is to configure the Database, following these instructions [text](https://learn.microsoft.com/en-us/azure/app-service/tutorial-connect-msi-sql-database)

* Log in to the database using [SQL Server Management Studio](https://learn.microsoft.com/en-us/sql/ssms/download-sql-server-management-studio-ssms) and your email address.
* Select the "ToDo" database, create a query and run this command tp grant the User Managed Identity Access to the database, replacing "todoapp-identity-jvmw6a2wit3yu" example below with the name of your Managed Identity:

CREATE USER [todoapp-identity-jvmw6a2wit3yu] FROM EXTERNAL PROVIDER;

ALTER ROLE db_datareader ADD MEMBER [todoapp-identity-jvmw6a2wit3yu];
ALTER ROLE db_datawriter ADD MEMBER [todoapp-identity-jvmw6a2wit3yu];
ALTER ROLE db_ddladmin ADD MEMBER [todoapp-identity-jvmw6a2wit3yu];
GO

## Option 2 - Deployment via GitHub Actions using OpenID Connect and Bicep (IaC)

We can use GitHub Actions using OpenID Connect and Infrastructure-as-Code (IaC) using Bicep to deploy a new ACA revision when we build the code.

This will require performing the following tasks:

1. Forking this repository into your GitHub account
2. Configuring OpenID Connect in Azure
3. Setting Github Actions secrets

## Forking this repository into your GitHub account

* Fork this [repository](https://github.com/ahems/MyToDoApp) into your GitHub account by clicking on the "Fork" button at the top right of its page. Use the default name "MyToDoApp" for this fork in your repo.

## Create AAD Accounts

Use Azure Cloud Shell and Bash (not PowerShell) to run all the commands below in the subscription you want to deploy to.

## Configuring OpenID Connect in Azure

1. Use Bash in the same Cloud Shell to create an Azure AD application using all these commands. This is used to deploy the IaC to your Azure Subscription. Make a note of the appId value that is shown by the last step, you will use this value in later steps.

   ```bash
   uniqueAppName=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c10 ; echo '')
   echo $uniqueAppName
   appId=$(az ad app create --display-name $uniqueAppName --query appId --output tsv)
   echo $appId
   ```

2. Create a service principal for the Azure AD app. Make a note of the assigneeObjectId value that is shown by the last step, you will use this value in later steps.

   ```bash
   assigneeObjectId=$(az ad sp create --id $appId --query id --output tsv)
   echo $assigneeObjectId 
   ```

3. Create a role assignment for the Azure AD app. This gives that app contributor access to the currently selected subscription.

   ```bash
   subscriptionId=$(az account show --query id --output tsv)
   az role assignment create --role owner --subscription $subscriptionId --assignee-object-id  $assigneeObjectId --assignee-principal-type ServicePrincipal --scope /subscriptions/$subscriptionId
   ```

4. Configure a federated identity credential on the Azure AD app.

   You use workload identity federation to configure your Azure AD app registration to trust tokens from an external identity provider (IdP), in this case GitHub.

   In the parameter of the command below, replace `<your-github-username>` with your GitHub username used in your forked repo. If you name your new repository something other than `MyToDoApp`, you will need to replace `MyToDoApp` with the name of your repository. Also, if your deployment branch is not `main`, you will need to replace `main` with the name of your deployment branch.

   ```bash
   az ad app federated-credential create --id $appId --parameters '{ "name": "gha-oidc", "issuer": "https://token.actions.githubusercontent.com",  "subject": "repo:<your-github-username>/MyToDoApp:ref:refs/heads/main", "audiences": ["api://AzureADTokenExchange"], "description": "Workload Identity for MyToDoApp" }'
   ```

## Setting Github Actions secrets

1. Open your forked Github repository and click on the `Settings` tab.
2. In the left-hand menu, expand `Secrets and variables`, and click on `Actions`.
3. Click on the `New repository secret` button for each of the following secrets:
   * `AZURE_SUBSCRIPTION_ID`(run `az account show --query id --output tsv` to get this value)
   * `AZURE_TENANT_ID` (run `az account show --query tenantId --output tsv` to get the value)
   * `AZURE_CLIENT_ID` (this is the `appId` from the JSON output of the `az ad app create` command above. Use `echo $appId` to get the value from the same terminal used to run the previous commands)

## Triggering the "Deploy Azure Container App Revision" GitHub Actions workflow

* Enable GitHub Actions for your repository by clicking on the "Actions" tab, and clicking on the `I understand my workflows, go ahead and enable them` button. You might need to Refresh to see them.
* Click on the `Deploy Azure Container App Revision` Workflow on the left of the screen (you may need to refresh your Actions in order to see it).
* Click on the `Run workflow` button, accept the default options (leave the checkbox unchecked)