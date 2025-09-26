# Deploying the ToDo App To Azure

## Deployment from Visual Studio Code using Code Spaces

The easiest way to get started is to use GitHub CodeSpaces as all the tools are installed for you. Steps:

1. Click this button: [![Open in GitHub Codespaces](https://img.shields.io/static/v1?style=for-the-badge&label=GitHub+Codespaces&message=Open&color=brightgreen&logo=github)](https://github.com/codespaces/new?hide_repo_select=true&repo=916191305&machine=standardLinux32gb&devcontainer_path=.devcontainer%2Fdevcontainer.json&location=WestUs2). This will launch the repo is VS Code in a Browser.

2. Next, we reccommend you launch the CodeSpace in *Visual Studio Code Dev Containers* as the Login from the command line to Azure using 2-factor Credentials often fails from a CodeSpace running in a Browser. To do this, click the name of the Codespace in the bottom-left of the screen and select "Open in VS Code Desktop" as shown here:

    ![VS Code Dev Containers](images/OpenInCodeSpaces.png)

3. Once the project files show up in your desktop deployment of Visual Studio Code (this may take several minutes), use the terminal window to follow the steps below to deploy the infrasructure.

### Configure Environment

Use the terminal in Visual Studio Code to do these steps.

1. Create a new environment:

   ```shell
   azd env new
   ```
   
   You will be asked for the name of the environment, which will also be used as the resource group name created by default in eastus2. "rg-" will automatically be prepended to the name so enter something like "adamhems-todoapp" for example.

2. (Optional) Set Environment Variables:

   There are a number of local variables you can optionally set depending on your preferences. The first of these is the TENANT_ID of your Azure environment, if you have a specific one you wish to use; in which case enter it like so:

   ```shell
   azd env set TENANT_ID <your tenant ID>
   ```

   Another is AZURE_SUBSCRIPTION_ID, which you can set in the same way as above if you wish to use a particular Azure Subscription. Otherwise you'll be given the option of selecting one in the next step.

   Lastly you can also set AZURE_LOCATION which is the Azure region you want everything deployed it, which uses 'eastus2' as the default if this value is not set.

3. Provision Infrastructure

   This is initiated with one command like so:

   ```shell
   azd up
   ```

# Deployment Steps

This is the sequence of events that happen after this command has been initiated:




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
