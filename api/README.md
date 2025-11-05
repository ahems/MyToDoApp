# API Service - Data API Builder

This directory contains the API service for the MyToDoApp application, implemented using [Microsoft Data API Builder (DAB)](https://github.com/Azure/data-api-builder). The API service provides REST and GraphQL endpoints to access the Azure SQL Database using Azure AD authentication and Managed Identity.

## Overview

The API service is automatically deployed by Azure Developer CLI (`azd`) as a separate container app alongside the main web application. It provides secure, authenticated access to the todo database through modern API standards.

### Key Features

- **REST API**: RESTful endpoints at `/api` for CRUD operations
- **GraphQL API**: GraphQL endpoint at `/graphql` for flexible queries
- **Azure AD Authentication**: JWT-based authentication using Azure AD
- **Managed Identity**: Passwordless database access using Azure Managed Identity
- **Application Insights**: Telemetry and monitoring integration
- **CORS Support**: Configurable cross-origin resource sharing

## How It's Deployed by azd

The API service is defined in `azure.yaml` as a separate service:

```yaml
services:
  api:
    project: ./api
    host: containerapp
    language: python
    docker:
      path: dockerfile
      remoteBuild: true
```

### Deployment Flow

1. **Build Phase**: `azd deploy` builds the Docker image using the `dockerfile` in this directory
2. **Remote Build**: The container is built in Azure Container Registry (ACR) with `remoteBuild: true`
3. **Container Deployment**: The built image is deployed to Azure Container Apps
4. **Environment Variables**: `azd` injects required environment variables from the azd environment
5. **Startup**: The `entrypoint.sh` script waits for Managed Identity token availability before starting DAB

## File Structure

```text
api/
├── README.md              # This file
├── dockerfile             # Multi-stage Docker build for Data API Builder
├── entrypoint.sh          # Startup script with MI token wait logic
└── dab-config.json        # Data API Builder configuration
```

## Configuration Files

### dockerfile

**Purpose**: Multi-stage Docker build that installs Data API Builder and configures the runtime environment.

**Build Stages:**

1. **Build Stage** (`mcr.microsoft.com/dotnet/sdk:8.0`):
   - Creates a dotnet tool manifest
   - Installs `Microsoft.DataApiBuilder` as a dotnet tool
   - Copies the pre-configured `dab-config.json`

2. **Runtime Stage** (`mcr.microsoft.com/azure-databases/data-api-builder`):
   - Copies the DAB installation and config from build stage
   - Adds the `entrypoint.sh` wrapper script
   - Sets environment variables for Managed Identity wait behavior

**Environment Variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `MI_RESOURCE` | `https://database.windows.net` | Azure resource URL for token acquisition |
| `MI_INITIAL_DELAY_SECONDS` | `0` | Initial delay before checking MI token availability |
| `MI_PERIOD_SECONDS` | `1` | Wait period between token availability checks |
| `MI_FAILURE_THRESHOLD` | `60` | Maximum number of retry attempts before failing |

### entrypoint.sh

**Purpose**: Wrapper script that ensures Managed Identity tokens are available before starting Data API Builder.

**Functionality:**

1. **Environment Detection**: Checks if running in Azure Container Apps by detecting `IDENTITY_ENDPOINT`
2. **Managed Identity Wait Loop**:
   - Polls the Managed Identity endpoint until HTTP 200 is received
   - Uses configurable retry logic with exponential backoff capabilities
   - Supports user-assigned managed identity via `MI_CLIENT_ID` or `AZURE_CLIENT_ID`
3. **Startup**: Launches Data API Builder with the configuration file once MI is ready
4. **Logging**: Provides timestamped logs for troubleshooting startup issues

**Why This Is Needed:**

Azure Container Apps may start containers before the Managed Identity system is fully initialized. Without this wait logic, DAB might fail to acquire database tokens on first startup, causing authentication errors.

**Configuration Parameters:**

- **MI_RESOURCE**: The Azure resource for which to acquire tokens (default: SQL Database)
- **MI_INITIAL_DELAY_SECONDS**: Grace period before first check (useful for cold starts)
- **MI_PERIOD_SECONDS**: How often to retry token acquisition
- **MI_FAILURE_THRESHOLD**: Maximum retries before giving up (prevents infinite loops)
- **MI_CLIENT_ID**: Optional user-assigned managed identity client ID

**Skip Behavior:**

If `IDENTITY_ENDPOINT` is not set (e.g., running locally), the wait logic is skipped and DAB starts immediately.

### dab-config.json

**Purpose**: Configuration file for Data API Builder that defines database connection, authentication, and entity mappings.

**Configuration Sections:**

#### 1. Data Source

```json
"data-source": {
  "database-type": "mssql",
  "connection-string": "@env('DATABASE_CONNECTION_STRING')"
}
```

- **Database Type**: Microsoft SQL Server (`mssql`)
- **Connection String**: Loaded from `DATABASE_CONNECTION_STRING` environment variable
- **Authentication**: Connection string includes Managed Identity authentication

#### 2. Runtime Configuration

**REST API:**

- Enabled at path `/api`
- Provides RESTful endpoints for CRUD operations
- Automatic HTTP verb mapping (GET, POST, PUT, PATCH, DELETE)

**GraphQL API:**

- Enabled at path `/graphql`
- Supports flexible query and mutation capabilities
- Supports nested queries and filtering

**CORS:**

- Currently configured with empty origins array (no CORS restrictions)
- `allow-credentials` set to `false`
- Can be customized for specific frontend domains

**Authentication:**

- **Provider**: Azure AD (`AzureAD`)
- **Audience**: API application ID URI from `API_APP_ID_URI` environment variable
- **Issuer**: Azure AD tenant-specific issuer URL using `TENANT_ID`
- **JWT Validation**: Automatic token validation for all requests

#### 3. Telemetry

```json
"telemetry": {
  "application-insights": {
    "enabled": true,
    "connection-string": "@env('APPLICATIONINSIGHTS_CONNECTION_STRING')"
  }
}
```

Integrates with Azure Application Insights for:

- Request/response logging
- Performance metrics
- Exception tracking
- Custom telemetry

#### 4. Entities

```json
"entities": {
  "todo": {
    "source": "dbo.ToDo",
    "permissions": [
      {
        "role": "authenticated",
        "actions": ["*"]
      }
    ]
  }
}
```

**Entity Mapping:**

- **Entity Name**: `todo` (API endpoint name)
- **Database Source**: `dbo.ToDo` table
- **Permissions**: Authenticated users can perform all actions (Create, Read, Update, Delete)

**Generated Endpoints:**

REST:

- `GET /api/todo` - List all todos
- `GET /api/todo/{id}` - Get todo by ID
- `POST /api/todo` - Create new todo
- `PUT /api/todo/{id}` - Update todo
- `PATCH /api/todo/{id}` - Partial update
- `DELETE /api/todo/{id}` - Delete todo

GraphQL:

- `POST /graphql` - GraphQL queries and mutations

## Environment Variables Required

The API service requires the following environment variables to be set by `azd` during deployment:

| Variable | Description | Set By |
|----------|-------------|--------|
| `DATABASE_CONNECTION_STRING` | SQL connection string with Managed Identity auth | azd (from [infra outputs](../infra/README.md)) |
| `API_APP_ID_URI` | Azure AD API identifier URI (e.g., `api://guid`) | [`preup.ps1`](../scripts/README.md#1-preupps1) script |
| `TENANT_ID` | Azure AD tenant ID | [`preup.ps1`](../scripts/README.md#1-preupps1) script |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Application Insights connection string | azd (from [infra outputs](../infra/README.md)) |
| `AZURE_CLIENT_ID` | User-assigned managed identity client ID | azd (from [infra outputs](../infra/README.md)) |

## Database Permissions

The API service connects to Azure SQL Database using the user-assigned managed identity. The required permissions are configured by the [`postprovision.ps1`](../scripts/README.md#2-postprovisionps1) script:

- **db_datareader**: Read access to all tables
- **db_datawriter**: Write access to all tables
- **db_ddladmin**: Schema modification permissions (if needed)

These permissions allow DAB to perform all CRUD operations on the `dbo.ToDo` table on behalf of authenticated users.

For more details on the provisioning process, see the [Scripts Documentation](../scripts/README.md).

## Security Model

### Authentication Flow

1. **Client Request**: Frontend sends request with Azure AD JWT token in `Authorization` header
2. **Token Validation**: DAB validates the JWT token against Azure AD
3. **Role Check**: Verifies user has `authenticated` role (any valid Azure AD user)
4. **Database Access**: DAB uses Managed Identity to query database
5. **Response**: Returns data to authenticated client

### No Password Storage

- The API service uses **passwordless authentication** via Managed Identity
- No SQL credentials stored in code, configuration, or environment variables
- Connection string specifies `Authentication=Active Directory Default`

## Local Development

To run the API service locally:

1. **Prerequisites**:
   - Docker installed
   - Azure CLI logged in (`az login`)
   - Environment variables configured

2. **Build the container**:

   ```bash
   docker build -t todo-api ./api
   ```

3. **Run with environment variables**:

   ```bash
   docker run -p 5000:5000 \
     -e DATABASE_CONNECTION_STRING="Server=..." \
     -e API_APP_ID_URI="api://your-guid" \
     -e TENANT_ID="your-tenant-id" \
     -e APPLICATIONINSIGHTS_CONNECTION_STRING="InstrumentationKey=..." \
     todo-api
   ```

4. **Test the API**:
   - REST: `curl http://localhost:5000/api/todo`
   - GraphQL: Access GraphQL playground at `http://localhost:5000/graphql`

## Troubleshooting

### Container Fails to Start

**Symptom**: Container exits shortly after starting

**Possible Causes**:

1. Managed Identity token not available (check `MI_FAILURE_THRESHOLD`)
2. Missing environment variables (check container logs)
3. Invalid `dab-config.json` (validate JSON syntax)

**Solution**:

Check container logs in Azure Portal for detailed error messages

### Authentication Errors

**Symptom**: API returns 401 Unauthorized

**Possible Causes**:

1. JWT token missing or expired
2. Incorrect `API_APP_ID_URI` or `TENANT_ID`
3. Token audience doesn't match configuration

**Solution**:

Verify Azure AD app registration and environment variables

### Database Connection Errors

**Symptom**: API returns 500 errors or database timeout

**Possible Causes**:

1. Managed identity not granted database permissions
2. SQL firewall blocking Container Apps IP range
3. Connection string incorrect

**Solution**:

- Run [`postprovision.ps1`](../scripts/README.md#2-postprovisionps1) to ensure permissions are set
- Verify SQL firewall allows Azure services (configured in [infrastructure](../infra/README.md))
- Check `DATABASE_CONNECTION_STRING` format

### MI Token Wait Timeout

**Symptom**: Container logs show "Timed out waiting for Managed Identity token"

**Solution**: Increase `MI_FAILURE_THRESHOLD` environment variable in dockerfile or deployment configuration

## Monitoring

The API service sends telemetry to Application Insights. Monitor these metrics:

- **Request Rate**: Number of API calls per minute
- **Response Time**: Average latency of API requests
- **Error Rate**: Percentage of failed requests (4xx/5xx)
- **Database Query Time**: Time spent in SQL queries
- **Authentication Failures**: Failed JWT validation attempts

Access metrics in Azure Portal → Application Insights → Application Map/Performance/Failures

## Related Documentation

### Project Documentation

- [Scripts Documentation](../scripts/README.md) - azd lifecycle scripts including `preup.ps1` and `postprovision.ps1`
- [Infrastructure Documentation](../infra/README.md) - Bicep modules and Azure resource configuration

### Microsoft Documentation

- [Data API Builder Documentation](https://learn.microsoft.com/azure/data-api-builder/)
- [Azure Managed Identity](https://learn.microsoft.com/azure/active-directory/managed-identities-azure-resources/)
- [Azure Container Apps](https://learn.microsoft.com/azure/container-apps/)
