# Deploying the ToDo App To Azure

## Option 1 - Deployment from Visual Studio Code to Web Apps

We can use Visual Studio Code to deploy the Bicep Scripts directly to Azure. Follow these steps:

* Clone the code from this [repository](https://github.com/ahems/MyToDoApp) to your own repo
* Download the code from your cloned repo to your local machine
* Run the "/scripts/create-app-and-secret.ps1" Powershell script in a terminal in VS Code to create an App and Client Secret in your Entra ID tenant, which it will output so you can use them in the next step. Your deployed App will use these values to Authenticate users.
* Set these environment variables:
  * TENANT_ID - If you want to use a particular Entra ID Tenant when authenticating (optional)
  
  ```azurecli
  azd env set "TENANT_ID" "7c55576f-e738-4097-8c71-053078eadf3f"
   ```

  * CLIENT_ID - get this value from the output of the script ran in the previous step
  * CLIENT_SECRET - get this value from the output of the script ran in the previous step
  * NAME - your accounts' name as it appears in Entra ID, used to set the admin of the database. You can get this value by running:

   ```azurecli
   az ad signed-in-user show --query userPrincipalName -o tsv
   ```

  * OBJECT_ID - your accounts' ObjectID in Entra ID. Get this value using:

   ```azurecli
   az ad signed-in-user show --query id -o tsv
   ```

* (Optional) If your Azure subscription is new, run the "/scripts/Register-Resource-Providers.ps1" Powershell script from a Terminal in VS Code
* Right-Click on the file "/infra/deploy.bicep" and select "Deploy Bicep File...". Select or create the Resource Group for the name you set the RESOURCE_GROUP variable to, and select the "deploy.bicepparam" parameters file which will expect environment variables above to be set as per the previous steps. Wait for this to complete.
* Run the "/scripts/update-app.ps1" Powershell script in a terminal in VS Code to update the app registration with the URL of the newly created web app.

### Configure Database

The next step is to configure the Database. Follow these steps:

* Log in to the database using the Azure Portal, using Query Editor and Entra ID Authentication.
* Get the name of your User Managed Identity by running this Powershell Command, replacing "MyToDoApp" with the name of your Resource Group (if different):

```powershell
(Get-AzUserAssignedIdentity -ResourceGroupName "MyToDoApp" | Select-Object -First 1).Name
```

* In Query Editor in the Azure Portal, select the "ToDo" database, create a query and run this command tp grant the User Managed Identity Access to the database, replacing "todoapp-identity-jvmw6a2wit3yu" example below with the name of your Managed Identity retrieved from the previous step:

```sql
CREATE USER [todoapp-identity-xyjya2a3yrfuw] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [todoapp-identity-xyjya2a3yrfuw];
ALTER ROLE db_datawriter ADD MEMBER [todoapp-identity-xyjya2a3yrfuw];
ALTER ROLE db_ddladmin ADD MEMBER [todoapp-identity-xyjya2a3yrfuw];
```

This will give your User Managed Identity access to the ToDo Database.

* Finally, run this script to create the ToDo Database table that will hold all our data:

```sql
CREATE TABLE todo (
    id INT IDENTITY(1,1) PRIMARY KEY,
    name NVARCHAR(100) NOT NULL,
    recommendations_json JSON,
    notes NVARCHAR(100),
    priority INT DEFAULT 0,
    completed BIT DEFAULT 0,
    due_date NVARCHAR(50),
    oid NVARCHAR(50)
);
```

You should now be able to launch the web app and see the site.

### Host in Azure Container Apps

You can use either Azure Web Apps (the default) or Azure Container Apps to host the Web App and API app. To use Azure Container Apps, follow these steps:

* Right-Click on the file "/infra/deploy-aca.bicep", select "Deploy Bicep File...". Select your previous Resource Group, no parameters file and wait for it to complete. This will deploy the two Web Apps and set all necessary App Settings using the values from your KeyVault.

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

## Custom Redis Session Backend (Entra ID Rationale)

This application uses Azure Cache for Redis with Entra ID (AAD) authentication only (access keys disabled). During development we observed that the default Flask-Session (Redis) backend occasionally failed to persist session data when using AAD token-based auth via the `redis_entraid` credential provider. The symptom was an MSAL login loop ("no prior log_in() info") because the state stored in the server-side session never appeared in Redis — no errors were raised, the key simply never materialized.

### Why a custom backend?
The stock Flask-Session save path relies on its own Redis client operations which, under AAD token auth, silently produced no stored key in this environment. A minimal custom `SessionInterface` was implemented that:
* Generates a session id (SID) and stores the session dict using a single `SETEX` with a TTL.
* Uses binary (pickle) serialization exactly once per request save.
* Avoids wrappers / pipelines that previously obscured failures.
* Always activates when `REDIS_CONNECTION_STRING` is defined (no extra env toggle required).

### Security & Hardening
* No debug or probe endpoints (e.g. `_session_dump`, `_redis_write_probe`) are present in production; they were removed after diagnosing the issue.
* Redis is accessed exclusively over TLS (`rediss://`) with Managed Identity (or a local dev principal) obtaining AAD tokens; no static keys are stored in config.
* `decode_responses` is not enabled to prevent accidental string decoding of pickled binary session blobs.
* Session cookie settings: `HttpOnly`, `Secure` (in non-local environments), `SameSite=Lax` to support normal AAD redirect flows.

### Local Development Support
For local runs (when `IS_LOCALHOST=true`):
* A fallback lightweight AAD credential provider can be enabled by setting `REDIS_LOCAL_PRINCIPAL_ID` along with `REDIS_CONNECTION_STRING`. It acquires tokens via `DefaultAzureCredential` (excluding Managed Identity) and presents them to Redis so you can test against the same Entra-only cache.

### Relevant Environment Variables
| Variable | Purpose |
|----------|---------|
| `REDIS_CONNECTION_STRING` | `rediss://host:6380/0` style URL enabling Redis + custom session backend. |
| `AZURE_CLIENT_ID` | If set, selects a User Assigned Managed Identity for Key Vault & Redis token acquisition. |
| `IS_LOCALHOST` | Enables local dev behaviors (non-secure cookie, optional local principal auth). |
| `REDIS_LOCAL_PRINCIPAL_ID` | (Local only) Principal/alias configured in Redis access policy for AAD token auth during development. |
| `KEY_VAULT_NAME` | Name of Key Vault holding auth secrets (authority, client id, secret, redirect URI). |

### Operational Notes
* No application changes are required to benefit from the custom backend; it replaces Flask-Session automatically when Redis is configured.
* If the Redis cache becomes temporarily unavailable, session retrieval will yield a new empty session instead of throwing, mirroring Flask's default resilience.
* Future migration back to the upstream backend would require validating a fixed/flask-session version under AAD token auth and removing the custom interface block in `app.py`.

### Troubleshooting
| Symptom | Check |
|---------|-------|
| Users loop back to login | Confirm Redis key creation for a session id (use Azure Cache console metrics; no in-app dump route). |
| Session disappears quickly | Verify TTL configuration (default 3600s) and ensure container clock skew is nominal. |
| Redis auth errors | Ensure Managed Identity (or local principal) has a Redis data-plane access policy with appropriate permissions. |

This section documents why the code diverges from a standard Flask-Session configuration and provides the context needed for future maintainers to reevaluate once upstream support for Entra ID token scenarios improves.
