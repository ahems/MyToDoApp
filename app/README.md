# Frontend Web Application Documentation

This directory contains the Flask-based frontend web application for the MyToDoApp project. The application provides a user-friendly interface for managing to-do items with AI-powered recommendations, Azure AD authentication, and integration with the backend Data API Builder service.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [File Structure](#file-structure)
- [Core Application Files](#core-application-files)
- [Supporting Modules](#supporting-modules)
- [Templates](#templates)
- [Static Assets](#static-assets)
- [Configuration](#configuration)
- [Authentication Flow](#authentication-flow)
- [API Integration](#api-integration)
- [Local Development](#local-development)
- [Related Documentation](#related-documentation)

---

## Overview

The frontend web application is a Python Flask application that:

- **Authenticates users** via Azure Active Directory (Entra ID)
- **Manages to-do items** through GraphQL queries/mutations to the backend API
- **Generates AI recommendations** using Azure AI Foundry for task completion assistance
- **Stores session data** in Azure Redis Cache using Entra ID authentication
- **Monitors telemetry** through Azure Application Insights
- **Runs in Azure Container Apps** with managed identity for secure, passwordless authentication

### Key Features

- ✅ **Zero-trust security**: Managed identity authentication for all Azure services
- ✅ **AI-powered recommendations**: Integrated Azure AI Foundry for task suggestions
- ✅ **Responsive UI**: Bootstrap 5-based interface with dynamic content
- ✅ **Session management**: Redis-backed sessions with automatic token refresh
- ✅ **Comprehensive logging**: OpenTelemetry integration with Application Insights
- ✅ **GraphQL integration**: Full CRUD operations via Data API Builder backend

---

## Architecture

```text
┌─────────────┐      ┌──────────────┐      ┌─────────────┐
│   Browser   │─────▶│  Flask App   │─────▶│  Data API   │
│  (User UI)  │      │ (Container)  │      │  Builder    │
└─────────────┘      └──────────────┘      └─────────────┘
                            │                      │
                            ├──────────────────────┤
                            ▼                      ▼
                     ┌─────────────┐       ┌──────────┐
                     │   Redis     │       │ Azure    │
                     │   Cache     │       │ SQL DB   │
                     └─────────────┘       └──────────┘
                            │
                            ▼
                     ┌─────────────┐
                     │ Azure AD    │
                     │ (Auth)      │
                     └─────────────┘
                            │
                            ▼
                     ┌─────────────┐
                     │ Azure       │
                     │ OpenAI      │
                     └─────────────┘
```

The frontend communicates with:

- **Azure AD**: For user authentication and authorization
- **Data API Builder**: For CRUD operations on to-do items (see [API Documentation](../api/README.md))
- **Azure Redis Cache**: For session storage with Entra ID authentication
- **Azure Key Vault**: For secure credential storage (client secrets, connection strings)
- **Azure AI Foundry**: For generating task recommendations
- **Application Insights**: For telemetry and monitoring

Infrastructure details: [Infrastructure Documentation](../infra/README.md)

---

## File Structure

```text
app/
├── app.py                      # Main Flask application with routes and business logic
├── dockerfile                  # Multi-stage container build configuration
├── requirements.txt            # Python dependencies
├── context_processors.py       # Flask template context injection (current date)
├── priority.py                 # Priority enumeration (HIGH, MEDIUM, LOW)
├── recommendation_engine.py    # Azure AI Foundry integration for AI recommendations
├── services.py                 # Service enumeration (OpenAI, AzureOpenAI)
├── tab.py                      # Tab state enumeration (DETAILS, EDIT, RECOMMENDATIONS)
├── README.md                   # This documentation
├── static/                     # Static assets (CSS, JS, images)
│   ├── css/
│   │   └── style.css          # Custom application styles
│   ├── images/                # Image assets (favicon, etc.)
│   └── js/
│       └── app.js             # Client-side JavaScript for UI interactions
└── templates/                  # Jinja2 HTML templates
    ├── index.html             # Main application interface
    ├── login.html             # Login landing page
    └── auth_error.html        # Authentication error display
```

---

## Core Application Files

### `app.py`

**Purpose**: Main Flask application containing all routes, business logic, authentication, and service integrations.

**Key Components**:

1. **Configuration & Initialization** (Lines 1-200)
   - Environment variable loading (with optional `.env` for local development)
   - Managed identity credential setup (User-assigned MI when `AZURE_CLIENT_ID` provided, system-assigned otherwise)
   - Azure service client initialization:
     - Key Vault for secrets retrieval
     - Application Insights for telemetry
     - Redis for session storage with Entra ID authentication
   - MSAL confidential client for API access tokens

2. **Authentication Setup** (Lines 200-250)
   - `identity.web.Auth` configuration for user authentication
   - MSAL `ConfidentialClientApplication` for app-to-API token acquisition
   - Token caching mechanism for API access tokens (`_get_api_access_token()`)

3. **Health & Diagnostics** (Lines 265-290)
   - `/startupz`: Startup probe endpoint for Container Apps health checks
     - Validates managed identity token acquisition for Redis
     - Returns 200 when MI is ready, 503 during initialization

4. **Session Management** (Lines 290-400)
   - Redis connection with Entra ID authentication using `redis-entraid`
   - Flask-Session configuration for server-side session storage
   - Automatic token refresh for Redis connections

5. **Application Routes**:

   - **`/` (index)**: Main application page
     - Loads user's to-do items from API
     - Requires authentication (redirects to login if not authenticated)

   - **`/login`**: Azure AD login initiation
     - Triggers OAuth2 authorization code flow

   - **`/getAToken`**: OAuth2 callback endpoint
     - Receives authorization code from Azure AD
     - Exchanges code for access token
     - Establishes user session

   - **`/logout`**: Sign-out endpoint
     - Clears session
     - Redirects to Azure AD logout

   - **`/add` (POST)**: Create new to-do item
     - GraphQL mutation: `createtodo`
     - Includes user OID (object ID) for data isolation

   - **`/details/<id>`**: View to-do item details
     - GraphQL query: fetch single item by ID
     - Displays in details panel

   - **`/edit/<id>`**: Edit to-do item form
     - Loads item data into edit panel

   - **`/update/<id>` (POST)**: Update existing to-do item
     - GraphQL mutation: `updatetodo`
     - Supports name, notes, priority, due date, completed status

   - **`/remove/<id>`**: Delete to-do item
     - GraphQL mutation: `deletetodo`

   - **`/completed/<id>/<complete>`**: Toggle completion status
     - Quick toggle endpoint for checkbox interactions

   - **`/recommend/<id>`**: Generate AI recommendations
     - Calls `RecommendationEngine.get_recommendations()`
     - Caches results in `recommendations_json` field
     - Supports refresh parameter to regenerate recommendations

6. **Helper Functions**:
   - `get_todo_by_id()`: GraphQL query to fetch single to-do item
   - `load_data_to_session()`: Pre-request hook to load user's to-do list
   - `inject_common_variables()`: Context processor for template variables

**Environment Variables**:

- `KEY_VAULT_NAME`: Azure Key Vault name for secret retrieval
- `AZURE_CLIENT_ID`: User-assigned managed identity client ID
- `REDIS_CONNECTION_STRING`: Redis connection string (Entra ID format: `rediss://identity@hostname:6380`)
- `IS_LOCALHOST`: Set to `"true"` for local development mode
- `API_APP_ID_URI`: API application ID URI for token audience validation
- `API_URL`: Backend API endpoint (GraphQL endpoint)
- `APPLICATIONINSIGHTS_CONNECTION_STRING`: Application Insights telemetry
- `REDIRECT_URI`: OAuth2 redirect URI (optional, can be in Key Vault)

**Authentication Flow**:

1. User accesses `/` → redirected to `/login`
2. `/login` redirects to Azure AD authorization endpoint
3. User authenticates with Azure AD
4. Azure AD redirects to `/getAToken` with authorization code
5. App exchanges code for access token
6. Session established, user redirected to `/`

**API Communication**:

- Uses GraphQL POST requests to `API_URL`
- Authorization header: `Bearer <user-access-token>`
- Custom header: `X-MS-API-ROLE: MyToDoApp`
- Content-Type: `application/json`

---

### `dockerfile`

**Purpose**: Multi-stage container build configuration for the Flask application.

**Build Strategy**:

1. **Base Image**: `python:3.13-slim-bookworm` (parameterized)
   - Slim variant minimizes image size
   - Debian Bookworm for stability

2. **Build Arguments**:
   - `PYTHON_VERSION=3.13`: Python version (overridable)
   - `BASE_VARIANT=slim-bookworm`: Base image variant

3. **Optimization Techniques**:
   - **Layer caching**: `requirements.txt` copied first, installed separately
   - **No bytecode**: `PYTHONDONTWRITEBYTECODE=1` prevents `.pyc` files
   - **Unbuffered output**: `PYTHONUNBUFFERED=1` for real-time logs
   - **No cache**: `--no-cache-dir` reduces image size

4. **Exposed Port**: 80
   - Matches Container App ingress configuration (see [Infrastructure Docs](../infra/README.md#modulesacabicep))

5. **Entrypoint**: `python app.py`
   - Starts Flask app directly
   - App listens on port 80 in production, port 5000 in local mode

**Container Runtime Behavior**:

- When `IS_LOCALHOST=false` (production): Listens on `0.0.0.0:80`
- When `IS_LOCALHOST=true` (development): Listens on `localhost:5000`

---

### `requirements.txt`

**Purpose**: Python package dependencies for the Flask application.

**Dependencies**:

| Package | Version | Purpose |
|---------|---------|---------|
| `openai` | Latest | Azure AI Foundry SDK for AI recommendations |
| `flask` | Latest | Web framework core |
| `flask[async]` | Latest | Async route support for `/recommend` |
| `azure-keyvault-secrets` | Latest | Key Vault secret retrieval |
| `azure-identity` | Latest | Managed identity authentication |
| `azure-monitor-opentelemetry` | Latest | Application Insights telemetry |
| `Flask-Session2` | Latest | Server-side session management |
| `werkzeug` | >=2 | Flask HTTP utilities |
| `requests` | >=2,<3 | HTTP client for API calls |
| `identity` | >=0.5.1,<0.6 | Azure AD authentication wrapper |
| `msal` | >=1.26.0 | Microsoft Authentication Library (confidential client) |
| `redis` | Latest | Redis client for session storage |
| `redis-entraid` | >=0.2.0 | Entra ID authentication for Redis |
| `python-dotenv` | Latest | `.env` file support for local development |

**Installation**:

```bash
pip install --no-cache-dir -r requirements.txt
```

---

## Supporting Modules

### `recommendation_engine.py`

**Purpose**: Azure AI Foundry integration for generating AI-powered task recommendations.

**Class**: `RecommendationEngine`

**Authentication Strategy**:

- **Local mode** (`IS_LOCALHOST=true`): Uses `DefaultAzureCredential` (excluding MI)
- **Container mode**: Uses `ManagedIdentityCredential` (user-assigned when `AZURE_CLIENT_ID` set)

**Token Management**:

- Acquires Entra ID tokens for Azure AI Foundry scope: `https://cognitiveservices.azure.com/.default`
- Automatic token refresh when expiry approaches (120-second buffer)
- Token caching to minimize authentication requests

**Configuration**:

1. **Deployment name**: Retrieved from Key Vault secret `AZUREOPENAIDEPLOYMENTNAME` or env var `AZURE_OPENAI_DEPLOYMENT_NAME`
2. **Endpoint**: Retrieved from Key Vault secret `AZUREOPENAIENDPOINT` or env var `AZURE_OPENAI_ENDPOINT`

**Method**: `async get_recommendations(keyword_phrase, previous_links_str=None)`

**Parameters**:

- `keyword_phrase` (str): The to-do item name/description
- `previous_links_str` (str, optional): Comma-separated list of URLs to exclude from recommendations

**Returns**: List of recommendation dictionaries with `title` and `link` keys

**Example**:

```python
engine = RecommendationEngine()
recommendations = await engine.get_recommendations("Buy a birthday gift for mom")
# Returns: [{"title": "...", "link": "..."}, ...]
```

**AI Prompt Strategy**:

- **System prompt**: Defines bot as administrative assistant providing task completion resources
- **User prompt**: Requests 5 recommendations with title and hyperlink in JSON format
- **Exclusion logic**: Prevents duplicate recommendations when refreshing

**API Configuration**:

- Model: Deployment name from configuration (e.g., `gpt-4o-mini`, `gpt-35-turbo`)
- API Version: `2024-02-15-preview`
- Temperature: `0.14` (low randomness for consistent results)
- Max tokens: `800`
- Top P: `0.17` (nucleus sampling)

**Error Handling**:

- JSON parsing failures return fallback message: `"Sorry, unable to recommendation at this time"`
- Token acquisition failures raise `RuntimeError`

---

### `context_processors.py`

**Purpose**: Flask context processor to inject current date into all templates.

**Function**: `inject_current_date()`

**Returns**: Dictionary with `current_date` key containing today's date in `YYYY-MM-DD` format

**Usage in Templates**:

```html
{% if todo.due_date < current_date %}
    <small class="badge bg-danger">Past Due: {{ todo.due_date }}</small>
{% endif %}
```

**Registration**: Automatically applied via `@app.context_processor` decorator in `app.py`

---

### `priority.py`

**Purpose**: Enumeration for to-do item priority levels.

**Enum**: `Priority`

**Values**:

- `NONE = 0`: No priority assigned
- `HIGH = 1`: High priority (urgent/important)
- `MEDIUM = 2`: Medium priority
- `LOW = 3`: Low priority

**Usage**:

```python
from priority import Priority
session["PriorityEnum"] = Priority
```

**Template Access**:

```html
{% if todo.priority == session.PriorityEnum.HIGH.value %}
    <span class="badge bg-danger">High Priority</span>
{% endif %}
```

---

### `tab.py`

**Purpose**: Enumeration for UI tab/panel states in the single-page application.

**Enum**: `Tab`

**Values**:

- `NONE = 0`: No detail panel active (default list view)
- `DETAILS = 1`: Viewing to-do item details
- `EDIT = 2`: Editing to-do item
- `RECOMMENDATIONS = 3`: Viewing AI recommendations

**Usage in Routes**:

```python
from tab import Tab
session["selectedTab"] = Tab.RECOMMENDATIONS
```

**Template Logic**:

```html
{% if session["selectedTab"] == session.TabEnum.DETAILS %}
    <!-- Display details panel -->
{% endif %}
```

---

### `services.py`

**Purpose**: Enumeration for AI service types (currently unused but reserved for future multi-provider support).

**Enum**: `Service`

**Values**:

- `OpenAI = "openai"`: Direct OpenAI API
- `AzureOpenAI = "azureopenai"`: Azure AI Foundry Service

**Note**: Current implementation uses only `AzureOpenAI`. This enum provides extensibility for future OpenAI API support.

---

## Templates

### `templates/index.html`

**Purpose**: Main single-page application interface for authenticated users.

**Structure**:

1. **Header Section**:
   - Page title: `<name>'s To-Do List`
   - Sign Out link

2. **Left Column** (7/12 grid):
   - **To-Do List**: Ordered list of all user's to-do items
     - Checkbox for completion toggle
     - Task name (clickable to show details)
     - Due date badge (color-coded: past due = red, upcoming = blue, completed = green)
     - Delete button (trash icon)
   - **Add Task Form**: Input field + Add button at bottom

3. **Right Column** (5/12 grid):
   - **Dynamic Detail Panel**: Shows based on `session["selectedTab"]`
     - **DETAILS**: Read-only view of selected to-do item
       - Name, notes, priority, due date, completed status
       - Edit and AI Recommend buttons
     - **EDIT**: Edit form for selected to-do item
       - Editable fields: name, notes, priority (dropdown), due date (date picker)
       - Save and Cancel buttons
     - **RECOMMENDATIONS**: AI-generated task suggestions
       - List of clickable links with titles
       - Refresh button to regenerate recommendations
       - Stores recommendations in `recommendations_json` field

**JavaScript Dependencies**:

- `app.js`: Client-side interaction handlers
  - `handleClick(event, checkbox)`: Checkbox click handler with event propagation control
  - `showDetails(element)`: Navigate to details view for clicked item

**Bootstrap Integration**:

- Bootstrap 5.3.3 for responsive layout and components
- Custom styles from `static/css/style.css`

**Dynamic Content**:

- Jinja2 templating with session data
- Color-coded badges based on due date comparison with `current_date`
- Conditional rendering based on `selectedTab` state

---

### `templates/login.html`

**Purpose**: Unauthenticated landing page with Azure AD sign-in link.

**Content**:

- Page title: "To-Do List"
- Sign In link: Redirects to `{{ auth_uri }}` (Azure AD authorization endpoint)

**Flow**:

1. User visits application root `/`
2. `@app.before_request` decorator checks `auth.get_user()`
3. If not authenticated, redirects to `/login`
4. User clicks "Sign In" → redirected to Azure AD
5. After authentication, redirected to `/getAToken` callback
6. Successfully authenticated users redirected to `/` (index)

---

### `templates/auth_error.html`

**Purpose**: Display authentication errors when Azure AD login fails.

**Features**:

- **Password Reset Detection**: Checks for error code `AADB2C90118` (Azure AD B2C password reset)
  - Auto-redirects to password reset flow if configured
- **Error Details**: Displays error code and description from Azure AD response
- **Homepage Link**: Allows user to return to main page and retry

**Variables**:

- `result`: Dictionary containing `error` and `error_description` from Azure AD
- `config`: Flask configuration object (checks for `B2C_RESET_PASSWORD_AUTHORITY`)

**Security**: Flask automatically escapes unsafe input to prevent XSS

---

## Static Assets

### `static/css/style.css`

**Purpose**: Custom CSS styles for application-specific UI elements.

**Styling Areas**:

- Task list item styles
- Detail panel layouts
- Badge colors and spacing
- Button hover effects
- Form input styling

---

### `static/js/app.js`

**Purpose**: Client-side JavaScript for interactive UI behaviors.

**Key Functions**:

1. **`handleClick(event, checkbox)`**:
   - Handles to-do item completion checkbox clicks
   - Prevents event bubbling to parent `<li>` click handler
   - Sends AJAX request to `/completed/<id>/<complete>` endpoint
   - Updates UI without full page reload

2. **`showDetails(element)`**:
   - Handles click on to-do item to show details panel
   - Extracts `data-id` attribute from clicked element
   - Redirects to `/details/<id>` route

**AJAX Patterns**:

- Uses `fetch()` API for asynchronous requests
- Updates DOM elements dynamically
- Provides responsive user experience without page reloads

---

### `static/images/`

**Purpose**: Image assets for the application.

**Contents**:

- `favicon.ico`: Browser tab icon
- Additional images as needed (logo, icons, etc.)

---

## Configuration

### Environment Variables

The application requires the following environment variables:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `KEY_VAULT_NAME` | Yes | - | Azure Key Vault name for secret retrieval |
| `AZURE_CLIENT_ID` | Recommended | - | User-assigned managed identity client ID |
| `REDIS_CONNECTION_STRING` | Yes | - | Redis connection string (Entra ID format) |
| `IS_LOCALHOST` | No | `"false"` | Set to `"true"` for local development |
| `API_APP_ID_URI` | Yes | - | API application ID URI (e.g., `api://guid`) |
| `API_URL` | Yes | - | Backend API endpoint (e.g., `https://api.../graphql/`) |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Yes | - | Application Insights connection string |
| `REDIRECT_URI` | No* | - | OAuth2 redirect URI (*can be in Key Vault as `REDIRECT-URI` secret) |
| `AUTHORITY` | No* | - | Azure AD authority URL (*can be in Key Vault) |
| `CLIENTID` | No* | - | Azure AD app registration client ID (*can be in Key Vault) |
| `CLIENTSECRET` | No* | - | Azure AD app registration client secret (*can be in Key Vault) |

**Priority**: Environment variables take precedence over Key Vault secrets.

### Key Vault Secrets

When `KEY_VAULT_NAME` is configured, the application retrieves:

- `AUTHORITY`: Azure AD authority URL (e.g., `https://login.microsoftonline.com/<tenant-id>`)
- `CLIENTID`: Web app Azure AD application client ID
- `CLIENTSECRET`: Web app Azure AD application client secret
- `REDIRECT-URI`: OAuth2 redirect URI (e.g., `https://.../getAToken`)
- `AZUREOPENAIDEPLOYMENTNAME`: Azure AI Foundry deployment name (e.g., `gpt-4o-mini`)
- `AZUREOPENAIENDPOINT`: Azure AI Foundry endpoint URL

**Access**: Requires managed identity with Key Vault Secrets User role.

### Redis Connection String Format

**Entra ID Authentication**:

```text
rediss://identity-name@hostname:6380/0
```

**Example**:

```text
rediss://todoapp-identity-abc123@todoapp-redis-abc123.redis.cache.windows.net:6380/0
```

**Components**:

- `rediss://`: TLS-encrypted connection
- `identity-name`: Managed identity name (from `identityName` parameter in infrastructure)
- `hostname`: Redis Cache hostname
- `6380`: Default port for TLS
- `/0`: Database number

---

## Authentication Flow

### User Authentication (OAuth2 Authorization Code Flow)

```text
┌─────────┐                ┌──────────┐                ┌──────────┐
│ Browser │                │ Flask App│                │ Azure AD │
└────┬────┘                └─────┬────┘                └─────┬────┘
     │                           │                           │
     │  1. GET /                 │                           │
     ├──────────────────────────▶│                           │
     │                           │                           │
     │  2. 302 Redirect /login   │                           │
     │◀──────────────────────────┤                           │
     │                           │                           │
     │  3. GET /login            │                           │
     ├──────────────────────────▶│                           │
     │                           │                           │
     │  4. 302 Redirect to AD    │                           │
     │◀──────────────────────────┤                           │
     │                           │                           │
     │  5. GET /authorize        │                           │
     ├───────────────────────────┼──────────────────────────▶│
     │                           │                           │
     │  6. Show login form       │                           │
     │◀──────────────────────────┼───────────────────────────┤
     │                           │                           │
     │  7. POST credentials      │                           │
     ├───────────────────────────┼──────────────────────────▶│
     │                           │                           │
     │  8. 302 with auth code    │                           │
     │◀──────────────────────────┼───────────────────────────┤
     │                           │                           │
     │  9. GET /getAToken?code=..│                           │
     ├──────────────────────────▶│                           │
     │                           │                           │
     │                           │  10. Exchange code for token
     │                           ├──────────────────────────▶│
     │                           │                           │
     │                           │  11. Return access token  │
     │                           │◀──────────────────────────┤
     │                           │                           │
     │  12. 302 Redirect to /    │                           │
     │◀──────────────────────────┤                           │
     │                           │                           │
     │  13. GET / (authenticated)│                           │
     ├──────────────────────────▶│                           │
     │                           │                           │
     │  14. Return index.html    │                           │
     │◀──────────────────────────┤                           │
```

### API Access Token (Client Credentials Flow)

```text
┌──────────┐                ┌──────────┐                ┌──────────┐
│Flask App │                │ Azure AD │                │ Data API │
└─────┬────┘                └─────┬────┘                └─────┬────┘
      │                           │                           │
      │  1. Request app token     │                           │
      │   (client_id + secret)    │                           │
      ├──────────────────────────▶│                           │
      │                           │                           │
      │  2. Return access token   │                           │
      │◀──────────────────────────┤                           │
      │                           │                           │
      │  3. GraphQL query         │                           │
      │   + Bearer token          │                           │
      ├───────────────────────────┼──────────────────────────▶│
      │                           │                           │
      │  4. Validate token        │                           │
      │                           │◀──────────────────────────┤
      │                           │                           │
      │  5. Return data           │                           │
      │◀──────────────────────────┼───────────────────────────┤
```

**Token Caching**: App-to-API tokens cached for duration of `expires_in` (minus 60-second buffer).

---

## API Integration

### GraphQL Communication

**Endpoint**: Value of `API_URL` environment variable (e.g., `https://todoapp-api-abc123.azurecontainerapps.io/graphql/`)

**Authentication**:

- **Authorization Header**: `Bearer <app-access-token>` (from MSAL confidential client)
- **Custom Header**: `X-MS-API-ROLE: MyToDoApp`

**Request Format**:

```json
{
  "query": "mutation { ... }",
  "variables": { "name": "...", "oid": "..." }
}
```

### GraphQL Operations

**1. Query All User's To-Dos**:

```graphql
{
  todos(filter: { oid: { eq: "<user-oid>" } }) {
    items {
      id
      name
      recommendations_json
      notes
      priority
      completed
      due_date
      oid
    }
  }
}
```

**2. Query Single To-Do by ID**:

```graphql
{
  todo_by_pk(id: <id>) {
    id
    name
    recommendations_json
    notes
    priority
    completed
    due_date
    oid
  }
}
```

**3. Create To-Do**:

```graphql
mutation Createtodo($name: String!, $oid: String!) {
  createtodo(item: {name: $name, oid: $oid}) {
    id
    name
    recommendations_json
    notes
    priority
    completed
    due_date
    oid
  }
}
```

**4. Update To-Do**:

```graphql
mutation Updatetodo($id: Int!, $name: String, $notes: String, $priority: Int, $due_date: String, $completed: Boolean, $recommendations_json: String) {
  updatetodo(id: $id, item: {
    name: $name
    notes: $notes
    priority: $priority
    due_date: $due_date
    completed: $completed
    recommendations_json: $recommendations_json
  }) {
    id
    name
    recommendations_json
    notes
    priority
    completed
    due_date
    oid
  }
}
```

**5. Delete To-Do**:

```graphql
mutation Deletetodo($id: Int!) {
  deletetodo(id: $id) {
    id
  }
}
```

### Data Isolation

All queries filter by user's `oid` (Azure AD object ID) to ensure users only access their own data:

```python
oid = auth.get_user().get("oid")
query = f'{{ todos(filter: {{ oid: {{ eq: "{oid}" }} }}) {{ items {{ ... }} }} }}'
```

**Backend Enforcement**: Data API Builder validates JWT tokens and enforces role-based access control (see [API Documentation](../api/README.md#authentication)).

---

## Local Development

### Prerequisites

1. **Python 3.13+**: Install from [python.org](https://python.org)
2. **Azure CLI**: Install from [docs.microsoft.com/cli/azure/install-azure-cli](https://docs.microsoft.com/cli/azure/install-azure-cli)
3. **Azure Subscription**: With deployed infrastructure (see [Infrastructure Setup](../infra/README.md))
4. **Environment Variables**: Configured in `.env` file (see below)

### Setup Steps

1. **Clone repository**:

   ```bash
   git clone <repo-url>
   cd MyToDoApp/app
   ```

2. **Create virtual environment**:

   ```bash
   python -m venv venv
   source venv/bin/activate  # On Windows: venv\Scripts\activate
   ```

3. **Install dependencies**:

   ```bash
   pip install -r requirements.txt
   ```

4. **Login to Azure**:

   ```bash
   az login
   ```

5. **Create `.env` file** in `app/` directory:

   ```env
   IS_LOCALHOST=true
   KEY_VAULT_NAME=todoapp-kv-abc123def456
   API_URL=https://todoapp-api-abc123.azurecontainerapps.io/graphql/
   API_APP_ID_URI=api://12345678-1234-1234-1234-123456789abc
   APPLICATIONINSIGHTS_CONNECTION_STRING=InstrumentationKey=...
   REDIS_CONNECTION_STRING=rediss://todoapp-identity-abc123@todoapp-redis-abc123.redis.cache.windows.net:6380/0
   ```

   **Note**: Omit `AUTHORITY`, `CLIENTID`, `CLIENTSECRET`, `REDIRECT_URI` — they will be retrieved from Key Vault.

6. **Run application**:

   ```bash
   python app.py
   ```

7. **Access application**:

   - Open browser: `http://localhost:5000`
   - Click "Sign In" to authenticate with Azure AD

### Local Development Mode

When `IS_LOCALHOST=true`:

- Uses `DefaultAzureCredential` (authenticated Azure CLI user)
- Listens on `localhost:5000` (not `0.0.0.0:80`)
- Enables Flask debug mode (`debug=True`)
- Optionally loads `.env` file via `python-dotenv`

### Troubleshooting

#### 1. "REDIRECT-URI variable not in KeyVault or Environment"

- Ensure Key Vault has `REDIRECT-URI` secret set to `http://localhost:5000/getAToken`
- Or set `REDIRECT_URI=http://localhost:5000/getAToken` in `.env`

#### 2. "Failed to acquire API access token"

- Verify `CLIENTID` and `CLIENTSECRET` in Key Vault
- Check Azure AD app registration has API permission for `API_APP_ID_URI`

#### 3. Redis connection fails

- Ensure Azure CLI user has "Redis Cache Contributor" role on Redis Cache
- Verify `REDIS_CONNECTION_STRING` format is correct (Entra ID format)

#### 4. Azure AI Foundry authentication fails

- Ensure Azure CLI user has "Cognitive Services User" role on AI Services resource
- Verify `AZUREOPENAIDEPLOYMENTNAME` and `AZUREOPENAIENDPOINT` in Key Vault

#### 5. "API_URL environment variable is not set"

- Add `API_URL` to `.env` file
- Ensure API is deployed and accessible (see [API Documentation](../api/README.md))

---

## Related Documentation

### Project Documentation

- **[Infrastructure Documentation](../infra/README.md)**: Bicep modules, resource configuration, deployment process
  - [Container Apps Module](../infra/README.md#modulesacabicep): Frontend and API container configuration
  - [Authentication Module](../infra/README.md#modulesauthenticationbicep): Azure AD app registrations
  - [Redis Module](../infra/README.md#modulesredisbicep): Redis Cache with Entra ID authentication
  - [Key Vault Module](../infra/README.md#moduleskeyvaultbicep): Secret storage configuration

- **[API Documentation](../api/README.md)**: Data API Builder configuration, GraphQL schema, authentication
  - [Dockerfile](../api/README.md#dockerfile): API container build process
  - [Entrypoint Script](../api/README.md#entrypointsh): Managed identity token wait logic
  - [DAB Configuration](../api/README.md#dab-configjson): GraphQL/REST API settings
  - [Troubleshooting](../api/README.md#troubleshooting): Common API issues and solutions

- **[Scripts Documentation](../scripts/README.md)**: azd lifecycle scripts
  - [preup.ps1](../scripts/README.md#1-preupps1): Pre-deployment setup (AD apps, AI Services, model selection)
  - [postprovision.ps1](../scripts/README.md#2-postprovisionps1): Database configuration
  - [postdeploy.ps1](../scripts/README.md#3-postdeployps1): Redirect URI updates
  - [postup.ps1](../scripts/README.md#4-postupps1): Display connection information

### Azure Resources

- [Flask Documentation](https://flask.palletsprojects.com/)
- [Azure Identity SDK for Python](https://learn.microsoft.com/python/api/overview/azure/identity-readme)
- [Azure AI Foundry Service](https://learn.microsoft.com/azure/ai-services/openai/)
- [Azure Redis Cache with Entra ID](https://learn.microsoft.com/azure/azure-cache-for-redis/cache-azure-active-directory-for-authentication)
- [Azure Container Apps](https://learn.microsoft.com/azure/container-apps/)
- [Microsoft Authentication Library (MSAL) for Python](https://learn.microsoft.com/azure/active-directory/develop/msal-overview)

---

## Deployment

The frontend application is deployed to Azure Container Apps via `azd deploy`. See the [Infrastructure Documentation](../infra/README.md#deployment-process) for deployment details.

**Container Configuration**:

- **Image**: Built from `dockerfile` in this directory
- **Port**: 80 (matches Container App ingress `targetPort`)
- **Environment Variables**: Injected by Container App configuration (see [infra/modules/aca.bicep](../infra/README.md#modulesacabicep))
- **Health Probe**: `/startupz` endpoint (validates managed identity readiness)
- **Scaling**: 0-3 replicas based on HTTP request concurrency

**Deployment Command**:

```bash
cd /workspaces/MyToDoApp
azd deploy app
```

**Post-Deployment**:

- Frontend URL: `https://todoapp-app-<resourceToken>.azurecontainerapps.io`
- Redirect URI automatically updated by [postdeploy.ps1](../scripts/README.md#3-postdeployps1)

---

## Security Considerations

### Zero-Trust Architecture

1. **Managed Identity**: All Azure service authentication uses managed identity (no passwords/keys)
2. **Key Vault**: Sensitive credentials stored securely, accessed via MI
3. **Redis Entra ID**: Session storage uses Entra ID authentication (no Redis password)
4. **Application Insights**: Telemetry uses Entra ID authentication via managed identity credential
5. **Azure AD**: User authentication with OAuth2/OpenID Connect
6. **API Token Validation**: Backend validates JWT tokens for every request

### Managed Identity Authentication

The application uses **User-Assigned Managed Identity** (specified via `AZURE_CLIENT_ID`) to authenticate to all Azure services, eliminating the need for passwords, connection strings with secrets, or API keys. This provides a passwordless, zero-trust security model.

**Services Accessed via Managed Identity**:

| Service | Authentication Method | Implementation | Purpose |
|---------|----------------------|----------------|---------|
| **Azure Key Vault** | Managed Identity | `DefaultAzureCredential` | Retrieves secrets (OAuth client secret, redirect URI) |
| **Azure Redis Cache** | Entra ID (via MI) | `redis-entraid` library with `IdentityProvider` | Session storage with token-based authentication |
| **Azure AI Foundry** | Entra ID Token (via MI) | `DefaultAzureCredential` → `get_token()` for scope `https://cognitiveservices.azure.com/.default` | AI recommendations with bearer token auth |
| **Application Insights** | Entra ID (via MI) | `configure_azure_monitor(credential=managed_identity_credential)` | Telemetry and monitoring with managed identity |

**Implementation Details**:

```python
# Single credential instance used across all services
managed_identity_credential = ManagedIdentityCredential(client_id=azure_client_id)

# Key Vault access
secret_client = SecretClient(vault_url=key_vault_url, credential=managed_identity_credential)

# Redis with Entra ID authentication
redis_client = redis.Redis.from_url(
    redis_connection_string,
    credential_provider=IdentityProvider(credential=managed_identity_credential)
)

# Azure AI Foundry token acquisition
openai_token = managed_identity_credential.get_token("https://cognitiveservices.azure.com/.default")

# Application Insights telemetry
configure_azure_monitor(
    connection_string=app_insights_connection_string,
    credential=managed_identity_credential
)
```

**Benefits**:

- ✅ No secrets stored in code or environment variables (except connection string endpoints)
- ✅ Automatic token rotation and expiry handling
- ✅ Centralized access control via Azure RBAC
- ✅ Audit trail through Azure AD sign-in logs
- ✅ Works seamlessly in both local development (Azure CLI auth) and production (Container App MI)

**Required Azure RBAC Roles** (assigned to managed identity):

- `Key Vault Secrets User` on Key Vault
- `Redis Cache Contributor` or custom role with `Microsoft.Cache/redis/accessKeys/read` on Redis
- `Cognitive Services OpenAI User` on Azure AI Foundry service
- `Monitoring Metrics Publisher` on Application Insights (automatically granted)

### User Data Isolation

- User data filtered by Azure AD `oid` (object ID)
- Backend enforces role-based access control
- Session data stored server-side (not in cookies)

### HTTPS Only

- All ingress is HTTPS (enforced by Container Apps)
- Redis connections use TLS (`rediss://`)
- API calls use HTTPS

### Token Management

- User tokens stored in server-side session (Redis)
- API access tokens cached with expiry tracking
- Automatic token refresh for long-running operations

---

## Contributing

When modifying the frontend application:

1. **Update this README** if adding new routes, features, or configuration
2. **Test locally** with `IS_LOCALHOST=true` before deploying
3. **Verify GraphQL queries** match Data API Builder entity definitions (see [API Documentation](../api/README.md#dab-configjson))
4. **Check Container App logs** in Azure Portal after deployment
5. **Update infrastructure** if new environment variables or secrets required (see [Infrastructure Documentation](../infra/README.md))

---

## Support

For issues or questions:

1. Check [Troubleshooting](#troubleshooting) section
2. Review [API Documentation](../api/README.md#troubleshooting) for backend issues
3. Consult [Infrastructure Documentation](../infra/README.md#troubleshooting) for deployment problems
4. Check Azure Portal logs for Container App, Redis, Key Vault, Application Insights

---

**Last Updated**: November 5, 2025  
**Version**: 1.0  
**Maintainer**: MyToDoApp Team
