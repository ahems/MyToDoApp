# Infrastructure Documentation

This directory contains the Infrastructure as Code (IaC) for the MyToDoApp application using Azure Bicep templates. The infrastructure deploys a modern, cloud-native todo application with Azure Entra ID (Azure AD) authentication, Azure AI Foundry integration, and a serverless architecture.

## Prerequisites

Before deploying this infrastructure, the [`preup.ps1`](../scripts/README.md#1-preupps1) script must run to prepare the environment. This script:

- Creates Azure AD app registrations for web and API authentication
- Creates the Azure AI Services account
- Discovers available Azure AI Foundry models and quota in the target region
- Sets environment variables that the Bicep templates consume

The Bicep templates then use these environment variables to deploy model deployments and configure authentication settings. For detailed information about the pre-deployment preparation, see the [Scripts Documentation](../scripts/README.md).

## Architecture Overview

The application consists of:

- **Frontend Web App**: Flask application with user authentication and UI
- **Backend API**: Data API Builder (DAB) providing REST/GraphQL endpoints (see [API Documentation](../api/README.md))
- **Database**: Azure SQL Database with Entra ID authentication
- **AI Services**: Azure AI Foundry for intelligent recommendations
- **Session Storage**: Azure Cache for Redis with Entra ID authentication
- **Monitoring**: Application Insights and Log Analytics

All services use **Azure Entra ID (Azure AD) authentication** with managed identities for secure, passwordless connections.

For information about the deployment lifecycle scripts, see the [Scripts Documentation](../scripts/README.md).

---

## Main Bicep File

### `main.bicep`

This is the orchestration file that deploys all infrastructure components. It:

- Defines all resource naming conventions using a unique resource token
- Coordinates the deployment order through module dependencies
- Passes configuration parameters to individual modules
- Outputs important values (connection strings, endpoints) back to Azure Developer CLI (azd)

**Key Features:**

- Uses user-assigned managed identity for all Azure service authentication
- Deploys resources in the correct dependency order
- Generates unique revision suffixes for container app deployments
- Calculates deployment capacities for OpenAI models based on available quota

---

## Configuration Parameters

### `main.parameters.json`

This file contains all the configurable parameters used by `main.bicep`. The Azure Developer CLI (azd) automatically substitutes values from your environment during deployment.

#### Required Parameters

| Parameter | Source | Description |
|-----------|--------|-------------|
| `environmentName` | `AZURE_ENV_NAME` | The name of your azd environment (e.g., "dev", "prod") |
| `aadAdminLogin` | `NAME` | Your Azure AD user email/name for admin access |
| `aadAdminObjectId` | `OBJECT_ID` | Your Azure AD user object ID for RBAC assignments |
| `webAppClientSecret` | `CLIENT_SECRET` | Client secret for the web app registration |
| `webAppClientId` | `CLIENT_ID` | Application ID of the web app registration |
| `apiAppIdUri` | `API_APP_ID_URI` | Application ID URI for the API (format: `api://<guid>`) |
| `cognitiveservicesname` | `AZURE_OPENAI_ACCOUNT_NAME` | Name for the Azure AI Foundry account |
| `cognitiveservicesLocation` | `AZURE_LOCATION` | Azure region for deployments |

#### Azure AI Foundry Chat Model Parameters

These parameters are automatically discovered and set by the [`preup.ps1`](../scripts/README.md#1-preupps1) script based on available quota in the target region:

| Parameter | Source | Description |
|-----------|--------|-------------|
| `chatGptDeploymentVersion` | `chatGptDeploymentVersion` | Model version (e.g., "0613", "1106") |
| `chatGptSkuName` | `chatGptSkuName` | SKU tier (e.g., "Standard", "GlobalStandard") |
| `chatGptModelName` | `chatGptModelName` | Model name (e.g., "gpt-35-turbo", "gpt-4") - prefers "mini" models |
| `availableChatGptDeploymentCapacity` | `availableChatGptDeploymentCapacity` | Available capacity in tokens per minute (TPM) |

#### Azure AI Foundry Embedding Model Parameters

These parameters are automatically discovered and set by the [`preup.ps1`](../scripts/README.md#1-preupps1) script:

| Parameter | Source | Description |
|-----------|--------|-------------|
| `embeddingDeploymentVersion` | `embeddingDeploymentVersion` | Embedding model version |
| `embeddingSkuName` | `embeddingDeploymentSkuName` | SKU for embeddings |
| `embeddingModelName` | `embeddingDeploymentModelName` | Embedding model name (e.g., "text-embedding-ada-002") - prefers "small" models |
| `availableEmbeddingDeploymentCapacity` | `availableEmbeddingDeploymentCapacity` | Available embedding capacity |

#### Feature Flags

| Parameter | Default | Description |
|-----------|---------|-------------|
| `restoreOpenAi` | `false` | Set to `true` to restore a soft-deleted Azure AI Foundry account |
| `useFreeLimit` | `false` | Set to `true` to use Azure SQL Database free tier |

**Note:** The azd CLI automatically reads these values from your `.azure/<env-name>/.env` file during deployment. The `${VARIABLE}` syntax in the JSON is replaced with actual values at deployment time.

---

## Infrastructure Modules

### `modules/identity.bicep`

Creates a user-assigned managed identity that serves as the security principal for all Azure resources in the application.

**What it does:**

- Creates a user-assigned managed identity
- Defines a custom role for deployment scripts
- Assigns the "Managed Identity Operator" role to itself
- Grants permissions needed for Azure CLI deployment scripts

**Why it's needed:**

- Enables passwordless authentication across all Azure services
- Provides a single identity for RBAC role assignments
- Allows the application to access Azure resources securely without storing credentials

**Outputs:**

- `identityid`: Resource ID of the managed identity
- `clientId`: Client ID for authentication
- `principalId`: Principal ID for role assignments

---

### `modules/keyvault.bicep`

Deploys Azure Key Vault for secure storage of application secrets and configuration values.

**What it does:**

- Creates an Azure Key Vault with RBAC authorization enabled
- Adds RBAC role assignments for the managed identity (`Key Vault Secrets User`)
- Stores secrets for all sensitive configuration values

**Why it's needed:**

- Stores sensitive configuration like connection strings, API keys, and OAuth credentials
- Provides secure, auditable access to secrets at runtime
- Eliminates hardcoded credentials from application code

**Secrets stored:**

- Authentication: `AUTHORITY`, `CLIENTID`, `CLIENTSECRET`
- Database: `SQLCONNECTIONSTRING`
- Redis: `REDISCONNECTIONSTRING`
- OpenAI: `AZUREOPENAIENDPOINT`
- Application Insights: `APPLICATIONINSIGHTSCONNECTIONSTRING`

**Outputs:**

- `keyVaultId`: Resource ID of the Key Vault
- `keyVaultName`: Name of the Key Vault
- `keyVaultUri`: HTTPS endpoint for accessing secrets

---

### `modules/authentication.bicep`

Stores Azure AD authentication configuration in Key Vault.

**What it does:**

- Stores the OAuth authority endpoint (Azure AD login URL)
- Not a typical resource module—just stores auth config values
- Uses deployment scripts to set Key Vault secrets

**Why it's needed:**

- Centralizes authentication configuration
- Makes the Azure AD authority URL available to containers via Key Vault

**Outputs:**

- `AUTHORITY`: Azure AD tenant login endpoint

---

### `modules/redis.bicep`

Deploys Azure Cache for Redis with Entra ID authentication for session storage.

**What it does:**

- Creates an Azure Cache for Redis (Basic C0 SKU by default)
- Enables Entra ID authentication and disables access keys
- Grants "Data Owner" access policy to the managed identity
- Grants "Data Owner" access policy to the admin user
- Configures TLS 1.2+ with SSL-only connections

**Why it's needed:**

- Stores user session data (login state, cached todos)
- Provides fast, distributed session storage across container replicas
- Uses Entra ID for passwordless authentication (no Redis password needed)
- Enables horizontal scaling of the web application

**Key features:**

- Passwordless authentication using Entra ID tokens
- The managed identity name is used as the Redis username
- Connection string format: `rediss://<identity-name>@<hostname>:6380/0`

**Outputs:**

- `redisHostName`: Redis server hostname
- `redisSslPort`: SSL port (6380)
- `entraConnectionString`: Entra-authenticated connection string

---

### `modules/database.bicep`

Deploys Azure SQL Database with Entra ID authentication using the Azure Verified Module (AVM).

**What it does:**

- Creates an Azure SQL Server with Entra ID-only authentication
- Creates a "todo" database with serverless General Purpose SKU (name configurable via `SQL_DATABASE_NAME` env var, default: `todo`)
- Configures the managed identity as the SQL admin
- Grants the admin user SQL admin access for local development
- Optionally enables Azure SQL Database free tier
- Stores connection string in Key Vault

**Post-deployment configuration:**

After the database is created, the [`postprovision.ps1`](../scripts/README.md#2-postprovisionps1) script runs to:

- Grant database roles (`db_datareader`, `db_datawriter`, `db_ddladmin`) to the managed identity
- Create the `dbo.todo` table schema with JSON validation constraints
- Configure external user mapping for passwordless authentication

**Why it's needed:**

- Stores todo items and user data
- Provides ACID transactions and relational queries
- Uses Entra ID authentication (no SQL passwords)
- Serverless SKU auto-pauses to save costs

**Database configuration:**

- SKU: `GP_S_Gen5_4` (4 vCores serverless)
- Max size: 32 GB
- Auto-pause delay: 60 minutes
- Authentication: Azure AD only (no SQL auth)

**Connection string format:**

```text
Server=tcp:<server>.database.windows.net,1433;Initial Catalog=todo;Authentication=Active Directory Default;
```

**Security note:** This module includes a permissive firewall rule (`0.0.0.0 - 255.255.255.255`) for development. For production, replace with restricted IP ranges or private endpoints.

---

### `modules/aiservices.bicep`

Deploys Azure AI Services (Azure AI Foundry) with chat and embedding model deployments.

**Prerequisites:**

This module requires the Azure AI Services account to already exist (created by [`preup.ps1`](../scripts/README.md#1-preupps1)) and uses environment variables set by that script to configure the model deployments.

**What it does:**

- References the existing Azure AI Services account (kind: AIServices)
- Deploys a chat model based on parameters from [`preup.ps1`](../scripts/README.md#model-selection-strategy) (e.g., GPT-4o-mini, GPT-3.5-turbo)
- Deploys an embedding model based on parameters from `preup.ps1` (e.g., text-embedding-3-small)
- Grants "Cognitive Services OpenAI Contributor" role to managed identity
- Grants "Cognitive Services OpenAI Contributor" role to admin user
- Stores endpoint and deployment name in Key Vault
- Optionally restores a soft-deleted OpenAI account

**Why it's needed:**

- Powers AI-driven todo recommendations and prioritization
- Provides natural language understanding for todo descriptions
- Generates embeddings for semantic search (future feature)

**Model deployments:**

1. **Chat model**: For conversational AI and text generation
   - Capacity determined by available quota (divided by 10)
   - SKU configured based on regional availability
2. **Embedding model**: For semantic similarity and search
   - Default: text-embedding-ada-002
   - Used for future recommendation features

**Key features:**

- Disables local auth (key-based) in favor of Entra ID
- Supports custom subdomain for consistent endpoint URLs
- Configurable public network access
- Batch deployment of models (@batchSize(1) for sequential deployment)

---

### `modules/applicationinsights.bicep`

Deploys Application Insights and Log Analytics workspace for monitoring and diagnostics.

**What it does:**

- Creates a Log Analytics workspace for log storage
- Creates an Application Insights component linked to the workspace
- Grants "Monitoring Metrics Publisher" role to managed identity
- Grants "Monitoring Metrics Publisher" role to admin user
- Configures 1 GB daily quota and 30-day retention

**Why it's needed:**

- Monitors application performance and availability
- Collects logs from container apps and other services
- Tracks user flows, exceptions, and dependencies
- Enables distributed tracing across web app and API
- Provides dashboards and alerts for operations

**Workspace configuration:**

- SKU: PerGB2018 (pay-as-you-go)
- Daily quota: 1 GB
- Retention: 30 days

---

### `modules/acr.bicep`

Deploys Azure Container Registry for storing Docker images.

**What it does:**

- Creates an Azure Container Registry (Basic SKU)
- Enables admin user for azd deployment push
- Grants "Contributor" role to managed identity
- Configures diagnostic logging to Log Analytics
- Tracks repository events and login events

**Why it's needed:**

- Stores Docker images for the web app and API containers
- Provides private registry for secure image distribution
- Enables Container Apps to pull images using managed identity
- Tracks image vulnerabilities and compliance (future feature)

**Diagnostic logs:**

- Container Registry Repository Events
- Container Registry Login Events
- All metrics

**Role assignments:**

- Managed identity: "Contributor" (for deployment scripts)
- Container Apps: "AcrPull" (assigned in aca.bicep)

---

### `modules/aca.bicep`

Deploys the Azure Container Apps environment and both container apps (web app and API).

**What it does:**

- Creates a Container Apps environment with Application Insights integration
- Deploys the **frontend web app** container with:
  - External ingress on port 80
  - Startup probe for managed identity readiness
  - Environment variables for Key Vault, Redis, OpenAI, and API access
  - Scale rules (0-3 replicas based on HTTP requests)
- Deploys the **backend API** container (see [API Documentation](../api/README.md)) with:
  - External ingress on port 5000
  - Environment variables for database, authentication, and Azure AD validation
  - Data API Builder (DAB) configuration for REST/GraphQL APIs
  - Managed Identity token wait logic via custom entrypoint
- Stores generated URLs in Key Vault (redirect URI, API URL)
- Uses a bootstrap image initially (replaced by azd deploy)

**Frontend (Web App) features:**

- Flask application with Azure AD authentication
- Session management via Redis
- Calls backend API with OAuth2 client credentials flow
- OpenAI integration for recommendations
- Startup probe waits for Redis MI token availability

**Backend (API) features:**

- Data API Builder (DAB) for automatic REST/GraphQL generation
- JWT validation using Azure AD (v1.0 endpoint)
- Filters data by user OID for multi-tenancy
- Connects to SQL Database using managed identity

**Environment variables:**

**Web App:**

- `KEY_VAULT_NAME`: Key Vault for secrets
- `REDIS_CONNECTION_STRING`: Entra-authenticated Redis connection
- `AZURE_CLIENT_ID`: Managed identity client ID
- `APPLICATIONINSIGHTS_CONNECTION_STRING`: Telemetry
- `AZURE_OPENAI_DEPLOYMENT_NAME`: Chat model name
- `API_URL`: Backend API GraphQL endpoint
- `API_APP_ID_URI`: API app registration URI for token requests

**API:**

- `DATABASE_CONNECTION_STRING`: SQL Database connection (Entra ID auth)
- `REDIS_CONNECTION_STRING`: Session storage
- `APPLICATIONINSIGHTS_CONNECTION_STRING`: Telemetry
- `AZURE_CLIENT_ID`: Managed identity client ID
- `CLIENT_ID`: Web app client ID
- `API_APP_ID_URI`: Full app ID URI (e.g., `api://guid`)
- `API_APP_ID`: Just the GUID portion for JWT audience validation
- `TENANT_ID`: Azure AD tenant for token issuer validation

**Scaling:**

- Min replicas: 0 (scale to zero when idle)
- Max replicas: 3
- Scale trigger: 10 concurrent HTTP requests per replica

**Security:**

- All ingress is HTTPS-only
- Uses managed identity for ACR image pull
- No secrets exposed in environment variables (uses Key Vault)

**Outputs:**

- `APP_REDIRECT_URI`: Frontend URL for Azure AD redirect
- `API_URL`: Backend GraphQL endpoint
- `APPLICATIONINSIGHTS_CONNECTION_STRING`: For local development

---

## Deployment Process

When you run `azd up` or `azd deploy`, the following happens:

1. **Pre-deployment** ([`preup.ps1`](../scripts/README.md#1-preupps1)):
   - Creates Azure AD app registrations (web app and API)
   - Creates Azure AI Services account
   - Discovers available Azure AI Foundry models and quota
   - Selects optimal chat and embedding models (prefers "mini" and "small" models)
   - Stores configuration in azd environment

2. **Infrastructure provisioning** (`azd provision` runs `main.bicep`):
   - Deploys `main.bicep` with parameters from `main.parameters.json`
   - Modules are deployed in dependency order:
     1. Identity, Key Vault, Redis
     2. Authentication, Database, ACR, Application Insights, AI Services
     3. Container Apps (using bootstrap images)

3. **Post-provisioning** ([`postprovision.ps1`](../scripts/README.md#2-postprovisionps1)):
   - Grants managed identity database roles on SQL Database
   - Creates `dbo.todo` table schema
   - Configures external user for passwordless database access

4. **Application deployment** (`azd deploy`):
   - Builds Docker images for web app and API
   - Pushes images to ACR
   - Updates container apps with new images

5. **Post-deployment** ([`postdeploy.ps1`](../scripts/README.md#3-postdeployps1)):
   - Updates Azure AD app redirect URIs with deployed container app URLs
   - Configures logout redirect URLs

6. **Post-up** ([`postup.ps1`](../scripts/README.md#4-postupps1)):
   - Displays connection information and next steps
   - Outputs application URLs

For detailed information about all deployment lifecycle scripts, see the [Scripts Documentation](../scripts/README.md).

---

## Local Development

To run the application locally, you need these environment variables (azd automatically creates `.azure/<env>/.env`):

```bash
# From main.bicep outputs
KEY_VAULT_NAME=<keyvault-name>
REDIS_CONNECTION_STRING=<redis-connection>
APPLICATIONINSIGHTS_CONNECTION_STRING=<app-insights>
API_URL=<api-graphql-url>
AZURE_CLIENT_ID=<managed-identity-client-id>

# From Key Vault (retrieved by app at runtime)
AUTHORITY=<azure-ad-authority>
CLIENTID=<web-app-client-id>
CLIENTSECRET=<web-app-client-secret>
```

Your local Azure CLI or Visual Studio login will be used for managed identity authentication during development.

---

## Security Best Practices

This infrastructure follows Azure security best practices:

✅ **Passwordless authentication** using Entra ID for all services  
✅ **Managed identities** for service-to-service authentication  
✅ **RBAC** with least-privilege role assignments  
✅ **Key Vault** for secrets management  
✅ **HTTPS-only** ingress for container apps  
✅ **TLS 1.2+** for Redis and SQL connections  
✅ **Audit logging** via Application Insights and Log Analytics  
✅ **Azure AD-only auth** for SQL Database (no SQL passwords)

⚠️ **For Production:**

- Remove the permissive SQL firewall rule (`0.0.0.0 - 255.255.255.255`)
- Use Private Endpoints for SQL, Redis, and Key Vault
- Enable Key Vault soft delete and purge protection
- Increase Container Apps max replicas based on load
- Set up availability zones for high availability
- Configure Azure Front Door or Traffic Manager for global distribution

---

## Resource Naming Convention

All resources follow this pattern: `todoapp-<service>-<resourceToken>`

Where `<resourceToken>` is a unique string generated from:

```bicep
toLower(uniqueString(resourceGroup().id, environmentName, location))
```

Example resources:

- `todoapp-kv-abc123def456` (Key Vault)
- `todoapp-redis-abc123def456` (Redis Cache)
- `todoapp-sql-abc123def456` (SQL Server)
- `todoapp-app-abc123def456` (Web App Container)
- `todoapp-api-abc123def456` (API Container)

This ensures:

- Resources are uniquely named across Azure subscriptions
- Resources from different environments don't conflict
- Resources can be identified by environment and location

---

## Troubleshooting

### OpenAI Deployment Fails

- **Issue**: Model quota not available in region
- **Solution**: Run `azd env set AZURE_LOCATION <region>` with a different region, then `azd provision`
- **Details**: See [`preup.ps1`](../scripts/README.md#model-selection-strategy) for model selection logic

### Container App Startup Probe Failing

- **Issue**: Managed identity token not available
- **Solution**: Increase `initialDelaySeconds` in startup probe configuration (default is 15 seconds)
- **Details**: See [API troubleshooting](../api/README.md#managed-identity-token-timeout) for MI token wait configuration

### Redis Authentication Fails

- **Issue**: Access policy assignment not propagated
- **Solution**: Wait 5 minutes for RBAC to propagate, or restart the container app

### API Returns 401 Unauthorized

- **Issue**: JWT token validation mismatch
- **Solution**: Verify `API_APP_ID_URI` and `API_APP_ID` environment variables match the token audience
- **Details**: See [API configuration](../api/README.md#environment-variables) for required authentication variables

### Database Connection Fails

- **Issue**: Database permissions not configured correctly
- **Solution**: Re-run post-provisioning script: `pwsh scripts/postprovision.ps1`
- **Details**: See [`postprovision.ps1`](../scripts/README.md#2-postprovisionps1) for database setup requirements

---

## Cost Estimation

Approximate monthly costs (pay-as-you-go, US West region):

| Service | SKU | Est. Monthly Cost |
|---------|-----|-------------------|
| Azure SQL Database | Serverless GP_S_Gen5_4 | $150 (with auto-pause) |
| Azure Cache for Redis | Basic C0 (250MB) | $16 |
| Azure Container Apps | 0.5 vCPU, 1GB RAM | $30 (3 replicas) |
| Azure AI Foundry | Standard, 100K tokens | $10 |
| Application Insights | 1GB/day | $2 |
| Key Vault | Standard | $1 |
| Container Registry | Basic | $5 |
| **Total** | | **~$214/month** |

**Cost optimization tips:**

- Use Azure SQL Database free tier (`useFreeLimit: true`)
- Scale container apps to zero when idle
- Use reserved capacity for OpenAI in production
- Implement Azure Front Door caching for static content

---

## Related Documentation

### Project Documentation

- **[Scripts Documentation](../scripts/README.md)**: Detailed information about all azd lifecycle scripts
  - [`preup.ps1`](../scripts/README.md#1-preupps1): Pre-deployment setup (AD apps, AI Services, model selection)
  - [`postprovision.ps1`](../scripts/README.md#2-postprovisionps1): Database configuration after provisioning
  - [`postdeploy.ps1`](../scripts/README.md#3-postdeployps1): Update redirect URIs after deployment
  - [`postup.ps1`](../scripts/README.md#4-postupps1): Display connection information
  - [`postdown.ps1`](../scripts/README.md#5-postdownps1): Clean up after deprovisioning

- **[API Documentation](../api/README.md)**: Data API Builder service configuration
  - [Dockerfile structure](../api/README.md#dockerfile)
  - [Entrypoint script logic](../api/README.md#entrypointsh)
  - [DAB configuration](../api/README.md#dab-configjson)
  - [Authentication setup](../api/README.md#authentication)
  - [Troubleshooting guide](../api/README.md#troubleshooting)

### Azure Resources

- [Azure Bicep Documentation](https://learn.microsoft.com/azure/azure-resource-manager/bicep/)
- [Azure Container Apps Documentation](https://learn.microsoft.com/azure/container-apps/)
- [Azure SQL Database with Entra ID](https://learn.microsoft.com/azure/azure-sql/database/authentication-aad-overview)
- [Azure AI Foundry Service](https://learn.microsoft.com/azure/ai-services/openai/)
- [Data API Builder](https://github.com/Azure/data-api-builder)
