# Scripts Documentation

This directory contains PowerShell scripts that automate Azure deployment workflows for the MyToDoApp application. These scripts are executed automatically by `azd` (Azure Developer CLI) at various stages of the deployment lifecycle.

## Execution Order

When you run `azd up` or other `azd` commands, these scripts execute in the following order:

1. **[preup.ps1](#1-preupps1)** - Runs before infrastructure provisioning
2. **[postprovision.ps1](#2-postprovisionps1)** - Runs after infrastructure is provisioned
3. **[postdeploy.ps1](#3-postdeployps1)** - Runs after application deployment
4. **[postup.ps1](#4-postupps1)** - Runs after successful `azd up` completion
5. **[postdown.ps1](#5-postdownps1)** - Runs after tearing down infrastructure with `azd down`

---

## 1. preup.ps1

**Execution Phase:** Before `azd provision` (pre-infrastructure deployment)

**Purpose:** Prepares the Azure environment by creating Azure AD app registrations and discovering available Azure OpenAI models with quota.

### What it does

**Azure AD App Registrations:**

- Creates the **web application** registration (`MyToDoApp`)
  - Generates OAuth client ID and client secret
  - Creates service principal for the app
  - Stores credentials in `azd` environment variables
- Creates the **API application** registration (`MyToDoApp-Api`)
  - Configures Application ID URI (format: `api://<guid>`)
  - Defines an `Api.Access` app role for application permissions
  - Assigns the web app service principal to the API app role
  - Enables web-to-API authentication via client credentials flow

**Azure OpenAI Discovery:**

- Enumerates all available models in the Azure OpenAI account
- Retrieves quota availability for each model in the deployment region
- Selects the best available chat model (e.g., GPT-4, GPT-3.5-turbo)
- Selects the best available embedding model (e.g., text-embedding-ada-002)
- Prioritizes models with highest available capacity
- Stores model selection in `azd` environment for Bicep deployment

**Environment Setup:**

- Sets `TENANT_ID`, `AZURE_SUBSCRIPTION_ID` from current Azure context
- Captures `NAME` (user email) and `OBJECT_ID` (user principal ID)
- Creates resource group if it doesn't exist
- Derives Azure OpenAI account name if not specified

### Key Functions

- `Ensure-AppRegistration`: Creates or validates web app registration with OAuth secret
- `Ensure-ApiAppRegistration`: Creates API app with app roles and assigns permissions
- `Ensure-OpenAIAccount`: Creates Azure OpenAI account if missing
- `Get-AccountModelsMultiVersion`: Enumerates available models using Azure REST API
- `Get-AoaiModelAvailableQuota`: Retrieves real-time quota availability per model/region

### Environment Variables Set

| Variable | Description |
|----------|-------------|
| `CLIENT_ID` | Web app OAuth client ID |
| `CLIENT_SECRET` | Web app OAuth client secret |
| `API_APP_ID` | API app client ID (GUID only) |
| `API_APP_OBJECT_ID` | API app Azure AD object ID |
| `API_APP_ROLE_ID` | App role ID for `Api.Access` permission |
| `API_APP_ID_URI` | Full API identifier URI (e.g., `api://guid`) |
| `chatGptDeploymentVersion` | Selected chat model version |
| `chatGptSkuName` | Selected chat model SKU |
| `chatGptModelName` | Selected chat model name |
| `availableChatGptDeploymentCapacity` | Available quota for chat model |
| `embeddingDeploymentVersion` | Selected embedding model version |
| `embeddingDeploymentSkuName` | Selected embedding model SKU |
| `embeddingDeploymentModelName` | Selected embedding model name |
| `availableEmbeddingDeploymentCapacity` | Available quota for embedding model |
| `AZURE_LOCATION` | Deployment region (default: eastus2) |
| `AZURE_RESOURCE_GROUP` | Resource group name (derived if missing) |
| `AZURE_OPENAI_ACCOUNT_NAME` | Azure OpenAI account name |
| `NAME` | Current user email/account |
| `OBJECT_ID` | Current user principal ID |
| `SQL_DATABASE_NAME` | Name of the Database (default: todo) |

### Performance Optimization

- **Parallel quota retrieval:** Uses PowerShell 7+ parallel execution (throttle limit: 8)
- **Idempotent:** Safe to run multiple times; skips existing resources
- **Quota-aware:** Only selects models with available capacity
- **Fallback logic:** Uses sequential execution if parallel not supported

### preup.ps1 Error Handling

- Validates Azure login context before operations
- Checks for required modules (Az.Accounts, Az.Resources, Az.CognitiveServices)
- Skips model discovery if selections already exist
- Provides detailed warnings for missing quota or API failures

---

## 2. postprovision.ps1

**Execution Phase:** After `azd provision` completes (post-infrastructure provisioning)

**Purpose:** Configures Azure SQL Database permissions for the managed identity and creates the `todo` table schema immediately after infrastructure deployment.

### What postprovision.ps1 Does

**Module Installation:**

- Trusts PSGallery repository to suppress untrusted prompts
- Installs Microsoft.Graph module if not present
- Installs required Az modules: `Az.Resources`, `Az.ManagedServiceIdentity`, `Az.Sql`

**Managed Identity Database Permissions:**

- Locates or auto-discovers the user-assigned managed identity in the resource group
- Locates or auto-discovers the Azure SQL Server in the resource group
- Obtains Azure AD access token for SQL Database authentication
- Loads SQL from `assign-database-roles.sql` with template substitution
- Creates external user in the database mapped to the managed identity
- Grants database roles: `db_datareader`, `db_datawriter`, `db_ddladmin`

**Database Schema Creation:**

- Loads SQL from `create-tables.sql` for table creation
- Creates the `dbo.todo` table if it doesn't exist
- Defines schema with columns: `id`, `name`, `recommendations_json`, `notes`, `priority`, `completed`, `due_date`, `oid`
- Adds JSON validation constraint for `recommendations_json` column
- Sets default values for `priority` (0) and `completed` (false)

### Table Schema

```sql
CREATE TABLE dbo.todo (
    id INT IDENTITY(1,1) PRIMARY KEY,
    name NVARCHAR(100) NOT NULL,
    recommendations_json NVARCHAR(MAX) NULL,
    notes NVARCHAR(100) NULL,
    priority INT NOT NULL DEFAULT(0),
    completed BIT NOT NULL DEFAULT(0),
    due_date NVARCHAR(50) NULL,
    oid NVARCHAR(50) NULL,
    CONSTRAINT CK_todo_recommendations_json_isjson CHECK (
        recommendations_json IS NULL OR ISJSON(recommendations_json)=1
    )
);
```

### postprovision.ps1 Key Functions

- `Convert-SecureIfNeededToPlainText`: Converts SecureString tokens to plain text
- `Get-AzAccessToken`: Retrieves Azure AD token for SQL authentication
- ADO.NET execution using `Microsoft.Data.SqlClient` with AccessToken authentication
- **SQL Template Substitution**: Replaces `{{IDENTITY_NAME}}` placeholder in SQL files with actual identity name
- **SQL Script Loading**: Loads SQL from external `.sql` files for better maintainability

### External SQL Files

| File | Purpose |
|------|---------|
| `assign-database-roles.sql` | Creates external user and grants database roles to managed identity |
| `create-tables.sql` | Creates the `dbo.todo` table schema |

### Environment Variables Used

| Variable | Description | Source | Default |
|----------|-------------|--------|---------|
| `TENANT_ID` | Azure AD tenant ID | azd environment | None |
| `AZURE_RESOURCE_GROUP` | Resource group name | azd environment | None |
| `USER_MANAGED_IDENTITY_NAME` | Managed identity name | azd environment (auto-discovered if missing) | First found in RG |
| `SQL_SERVER_NAME` | SQL server name | azd environment (auto-discovered if missing) | First found in RG |
| `SQL_DATABASE_NAME` | SQL database name | azd environment | `todo` |

### Why This Runs Automatically

Unlike manual troubleshooting scripts, `postprovision.ps1` is configured as an `azd` hook in `azure.yaml` to run automatically after infrastructure provisioning. This ensures:

- Database is ready for application deployment
- Managed identity has proper permissions before containers start
- Table schema exists before Data API Builder attempts to query it
- Eliminates manual configuration steps

### Idempotency

- **Safe to run multiple times:** All operations check for existence before creation
- **Skip existing users:** Won't fail if managed identity user already exists
- **Skip existing roles:** Only grants roles if not already assigned
- **Skip existing table:** Won't recreate `todo` table if it exists

### Authentication Method

Uses **Azure AD token-based authentication** instead of SQL username/password:

1. Obtains access token via `Get-AzAccessToken -ResourceUrl 'https://database.windows.net/'`
2. Creates `SqlConnection` with token via `AccessToken` property
3. Executes T-SQL with admin privileges from current user context
4. Managed identity receives database roles for application access

### postprovision.ps1 Error Handling

- Validates Azure login context before operations
- Auto-discovers resources if environment variables missing
- Sets discovered resource names in azd environment for future runs
- Validates SQL script files exist before attempting to load
- Provides detailed error messages for T-SQL failures
- Exits with error code 1 on critical failures (missing identity, server, or SQL files)

---

## 3. postdeploy.ps1

**Execution Phase:** After `azd deploy` completes (post-application deployment)

**Purpose:** Updates the Azure AD web app registration with the correct redirect URIs and logout URL after the container app is deployed.

### What postdeploy.ps1 Does

**Redirect URI Configuration:**

- Retrieves the deployed web app URL from `azd` environment (`APP_REDIRECT_URI`)
- Updates the Azure AD app registration with production redirect URI
- Adds local development redirect URI for debugging
- Sets the logout redirect URL to the web app base URL

**URIs Configured:**

- Production redirect: `https://todoapp-app-xyz.azurecontainerapps.io/getAToken`
- Local development: `http://localhost:5000/getAToken`
- Logout redirect: `https://todoapp-app-xyz.azurecontainerapps.io` (base URL)

### Why This Script Exists

The redirect URIs depend on the deployed container app's URL, which isn't known until after Bicep deployment completes. This script bridges that gap by updating the app registration with the correct URLs after the infrastructure is provisioned.

### Authentication Flow Impact

1. User clicks "Sign In" on web app
2. Flask redirects to Azure AD with `redirect_uri=https://<app-url>/getAToken`
3. User authenticates with Azure AD
4. Azure AD validates redirect URI matches app registration
5. Azure AD redirects back to `/getAToken` with authorization code
6. Flask exchanges code for access token

### Key Operations

- Retrieves `MyToDoApp` app registration by display name
- Updates `ReplyUrls` (redirect URIs) using `Set-AzADApplication`
- Updates `LogoutUrl` using `Update-AzADApplication`
- Validates `APP_REDIRECT_URI` environment variable exists

### postdeploy.ps1 Error Handling

- Fails if `APP_REDIRECT_URI` not found in environment
- Requires existing Azure AD app registration
- Validates Azure login context before operations

---

## 4. postup.ps1

**Execution Phase:** After `azd up` completes (post-deployment)

**Purpose:** Generates a `.env` file at the project root for local development by pulling configuration from the deployed Azure environment.

### What postup.ps1 Does

**Environment File Generation:**

- Reads the current `azd` environment variables
- Creates or updates `.env` file with local development settings
- Preserves existing comments and non-target variables
- Quotes values containing special characters (whitespace, `#`, `;`, `:`, `=`)

**Local Development Variables:**

- `IS_LOCALHOST=true` - Marker for local execution code paths
- `APPLICATIONINSIGHTS_CONNECTION_STRING` - Telemetry endpoint
- `REDIS_CONNECTION_STRING` - Redis connection with Entra ID authentication
- `AZURE_CLIENT_ID` - Managed identity client ID for local development
- `KEY_VAULT_NAME` - Key Vault for secrets retrieval
- `API_URL` - Backend GraphQL API endpoint
- `REDIS_LOCAL_PRINCIPAL_ID` - User's principal ID for Redis AAD authentication

### postup.ps1 Key Functions

- `Get-AzdValue`: Retrieves variable from `azd` environment with error handling
- `Quote-EnvValue`: Safely quotes values for `.env` format
- `Parse-EnvFile`: Parses existing `.env` file preserving structure
- `Update-EnvFile`: Merges new values with existing file

### postup.ps1 Behavior

- **Idempotent:** Updates existing `.env` without losing other content
- **Selective:** Only syncs variables that exist in `azd` environment
- **Safe:** Skips variables with missing values (logs warning)
- **POSIX-friendly:** Ensures file ends with newline

### Local Development Workflow

1. Run `azd up` to deploy Azure infrastructure
2. `postup.ps1` automatically generates `.env` file
3. Local Flask app reads `.env` on startup
4. Application uses local Azure CLI credentials for authentication
5. Connects to deployed Azure resources (Redis, SQL, OpenAI, Key Vault)

### File Format

```env
IS_LOCALHOST=true
APPLICATIONINSIGHTS_CONNECTION_STRING='InstrumentationKey=abc...'
REDIS_CONNECTION_STRING='rediss://identity-name@hostname:6380/0'
AZURE_CLIENT_ID=12345678-1234-1234-1234-123456789abc
KEY_VAULT_NAME=todoapp-kv-abc123def456
API_URL=https://todoapp-api-abc123.azurecontainerapps.io/graphql
REDIS_LOCAL_PRINCIPAL_ID=87654321-4321-4321-4321-cba987654321
```

---

## 5. postdown.ps1

**Execution Phase:** After `azd down` (post-infrastructure teardown)

**Purpose:** Cleans up Azure AD app registrations and local development artifacts after the infrastructure has been deleted.

### What postdown.ps1 Does

**Azure AD Cleanup:**

- Removes the **web application** registration (`MyToDoApp`)
  - Deletes service principal first (to avoid orphaned SPs)
  - Deletes app registration and all associated credentials
- Removes the **API application** registration (`MyToDoApp-Api`)
  - Deletes app roles and permissions
  - Deletes service principal and app registration

**Environment Cleanup:**

- Unsets all app registration variables from `azd` environment:
  - `CLIENT_ID`, `CLIENT_SECRET`
  - `API_APP_ID`, `API_APP_OBJECT_ID`
  - `API_APP_ROLE_ID`, `API_APP_ID_URI`
- Removes generated `.env` file from project root

### postdown.ps1 Key Functions

- `Remove-AppRegistration`: Safely deletes app registration and service principal
- `Remove-AzdValue`: Unsets variables from `azd` environment
- `Connect-AzContextIfNeeded`: Ensures Azure authentication before deletion

### Deletion Order

1. Locate app registration by client ID or display name
2. Delete service principal (if exists)
3. Delete app registration
4. Clear `azd` environment variables
5. Remove local `.env` file

### Safety Features

- **Idempotent:** Safe to run multiple times
- **Defensive:** Continues if resources already deleted
- **Logging:** Provides detailed feedback on each deletion step
- **Fallback:** Tries display name if client ID lookup fails

### When to Use

- **After `azd down`:** Automatically cleans up app registrations
- **Manual cleanup:** Run directly to remove orphaned registrations
- **Development reset:** Clean slate before re-provisioning

### Warning

This script permanently deletes Azure AD app registrations. Ensure you have backups of any custom configuration or credentials before running. Deleted app registrations can be restored from Azure AD's "Deleted applications" for 30 days.

---

## Common Patterns

### Module Management

All scripts follow a consistent pattern for PowerShell module management:

```powershell
# Trust PSGallery to avoid prompts
function Ensure-PsGalleryTrusted { ... }

# Install and import required modules
function Ensure-Module {
    param([string]$Name, [string]$MinVersion)
    # Install if missing, import with error handling
}
```

### Azure Context Handling

```powershell
function Ensure-AzLogin {
    param([string]$TenantId, [string]$SubscriptionId)
    # Connect if not logged in
    # Switch subscription if needed
}
```

### azd Environment Integration

```powershell
function Get-AzdValue {
    param([string]$Name, [string]$Default='')
    # Retrieve from azd env with ANSI color handling
    # Detect error patterns and return default
}

function Set-AzdValue {
    param([string]$Name, [string]$Value)
    azd env set $Name $Value | Out-Null
}
```

---

## Troubleshooting

### Script Execution Policy

If scripts fail with "execution policy" errors:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

### Azure PowerShell Version

Ensure you have the latest Az modules:

```powershell
Update-Module Az.Accounts, Az.Resources, Az.CognitiveServices -Force
```

### Parallel Execution Issues

If quota retrieval is slow, set throttle limit:

```powershell
$env:AOAI_QUOTA_DOP = 16  # Increase parallel degree
```

### App Registration Conflicts

If app registrations already exist with different configuration:

```powershell
# Manually delete conflicting apps
Remove-AzADApplication -DisplayName "MyToDoApp"
Remove-AzADApplication -DisplayName "MyToDoApp-Api"

# Re-run preup.ps1
./scripts/preup.ps1
```

### Missing Quota

If no models have available quota in your region:

```bash
# Try a different region
azd env set AZURE_LOCATION "eastus"
azd provision
```

---

## Extending the Scripts

### Adding New Environment Variables

To sync additional variables in `postup.ps1`:

```powershell
$desiredVariables = @(
    # Existing entries...
    @{ Target='NEW_VAR'; Candidates=@('SOURCE_VAR_1','SOURCE_VAR_2') }
)
```

### Custom Model Selection Logic

To change model selection criteria in `preup.ps1`:

```powershell
# Modify the sorting logic (line ~750)
$sorted = $allQuota | Sort-Object -Property @{
    Expression={ [int]$_.AvailableCapacity }; 
    Descending=$true
}, @{
    Expression={$_.ModelVersion}; 
    Descending=$true
}

# Add custom filters
$chatPick = $sorted | Where-Object { $_.ModelName -like '*gpt-4*' } | Select-Object -First 1
```

### Additional App Registration Configuration

To add custom app registration settings in `preup.ps1`:

```powershell
# After line ~250 (app creation)
Update-AzADApplication -ObjectId $app.Id -SignInAudience 'AzureADMultipleOrgs'
# Add required resource access, optional claims, etc.
```

---

## Script Dependencies

### PowerShell Modules

- **Az.Accounts** (>= 2.12.0) - Azure authentication and context
- **Az.Resources** - Azure AD app registration management
- **Az.CognitiveServices** - Azure OpenAI account operations

### External Tools

- **azd** (Azure Developer CLI) - Environment variable storage and lifecycle hooks
- **Azure CLI** (optional) - Used by local development for authentication

### Minimum PowerShell Version

- **PowerShell 5.1+** - Windows PowerShell or PowerShell Core
- **PowerShell 7+** - Recommended for parallel quota retrieval

---

## Security Considerations

### Credential Storage

- **Client secrets** stored in `azd` environment (encrypted on disk)
- **Never commit** `.env` file to source control (add to `.gitignore`)
- **Rotate secrets** annually via Azure AD app registration

### Service Principal Permissions

- Web app SP granted `Api.Access` app role on API registration
- No directory-level permissions required
- Follows principle of least privilege

### Local Development

- Uses **Azure CLI** or **Visual Studio** credentials for managed identity
- **REDIS_LOCAL_PRINCIPAL_ID** enables Redis AAD authentication locally
- No local secrets required (all retrieved from Key Vault)

---

## Additional Resources

- [Azure Developer CLI Documentation](https://learn.microsoft.com/azure/developer/azure-developer-cli/)
- [Azure AD App Registrations](https://learn.microsoft.com/azure/active-directory/develop/quickstart-register-app)
- [Azure OpenAI Quota Management](https://learn.microsoft.com/azure/ai-services/openai/quotas-limits)
- [PowerShell Az Module](https://learn.microsoft.com/powershell/azure/)
