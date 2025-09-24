import os
import time
import secrets
from urllib.parse import urlparse
from typing import Optional

from flask import Flask, session
from flask_session import Session

from redis import Redis
# Try to import the enum for id_type; fall back to string literals if unavailable
try:
    from redis_entraid.cred_provider import ManagedIdentityIdType as MIIdType
except Exception:
    MIIdType = None
from redis_entraid.cred_provider import (
    create_from_managed_identity,
    ManagedIdentityType,
    TokenManagerConfig,
    DEFAULT_LOWER_REFRESH_BOUND_MILLIS,
    DEFAULT_TOKEN_REQUEST_EXECUTION_TIMEOUT_IN_MS,
    RetryPolicy,
)

from azure.identity import ManagedIdentityCredential, DefaultAzureCredential
from azure.core.credentials import TokenCredential
from azure.monitor.opentelemetry import configure_azure_monitor


# --------------------------
# Config / Environment
# --------------------------
APPINSIGHTS_CS = os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING", "")
REDIS_URL = os.getenv("REDIS_CONNECTION_STRING", "")
AZURE_CLIENT_ID = os.getenv("AZURE_CLIENT_ID")  # optional (UAMI client ID)
# Optional alternatives if you prefer resource/object id instead of client id
AZURE_MI_RESOURCE_ID = os.getenv("AZURE_MANAGED_IDENTITY_RESOURCE_ID")
AZURE_MI_OBJECT_ID = os.getenv("AZURE_MANAGED_IDENTITY_OBJECT_ID")
IS_LOCALHOST = os.getenv("IS_LOCALHOST", "false").lower() == "true"

# Build args for redis-entraid managed identity provider
identity_kind = (
    ManagedIdentityType.USER_ASSIGNED
    if (AZURE_CLIENT_ID or AZURE_MI_RESOURCE_ID or AZURE_MI_OBJECT_ID)
    else ManagedIdentityType.SYSTEM_ASSIGNED
)

mi_kwargs = {
    "resource": "https://redis.azure.com",
    "identity_type": identity_kind,
    "token_manager_config": TokenManagerConfig(
        expiration_refresh_ratio=0.9,
        lower_refresh_bound_millis=DEFAULT_LOWER_REFRESH_BOUND_MILLIS,
        token_request_execution_timeout_in_ms=DEFAULT_TOKEN_REQUEST_EXECUTION_TIMEOUT_IN_MS,
        retry_policy=RetryPolicy(max_attempts=5, delay_in_ms=50),
    ),
}

if identity_kind == ManagedIdentityType.USER_ASSIGNED:
    if AZURE_CLIENT_ID:
        mi_kwargs["id_type"] = MIIdType.CLIENT_ID if MIIdType else "client_id"
        mi_kwargs["id_value"] = AZURE_CLIENT_ID
    elif AZURE_MI_RESOURCE_ID:
        mi_kwargs["id_type"] = MIIdType.RESOURCE_ID if MIIdType else "resource_id"
        mi_kwargs["id_value"] = AZURE_MI_RESOURCE_ID
    elif AZURE_MI_OBJECT_ID:
        mi_kwargs["id_type"] = MIIdType.OBJECT_ID if MIIdType else "object_id"
        mi_kwargs["id_value"] = AZURE_MI_OBJECT_ID
    else:
        raise ValueError(
            "User-assigned managed identity selected, but no id provided. "
            "Set AZURE_CLIENT_ID (recommended) or AZURE_MANAGED_IDENTITY_RESOURCE_ID or AZURE_MANAGED_IDENTITY_OBJECT_ID."
        )

credential_provider = create_from_managed_identity(**mi_kwargs)

# --------------------------
# Azure Identity for Azure Monitor (Entra ID)
# --------------------------
if IS_LOCALHOST:
    az_monitor_credential: TokenCredential = DefaultAzureCredential()
else:
    # Prefer User Assigned MI via client ID when provided; fallback to system-assigned
    if AZURE_CLIENT_ID:
        az_monitor_credential = ManagedIdentityCredential(client_id=AZURE_CLIENT_ID)
    else:
        az_monitor_credential = ManagedIdentityCredential()

# App Insights logging (optional but recommended)
if APPINSIGHTS_CS:
    # Use Entra ID auth with the Managed Identity for Azure Monitor exporters
    configure_azure_monitor(
        logger_name="todoapp-minimal",
        connection_string=APPINSIGHTS_CS,
        credential=az_monitor_credential,
    )

# --------------------------
# Flask app
# --------------------------
app = Flask(__name__)
app.secret_key = (
    os.getenv("SECRET_KEY")
    or os.getenv("FLASK_SECRET_KEY")
    or secrets.token_hex(16)
)

# --------------------------
# Redis (Entra ID) support
# --------------------------
def _parse_redis_url(url: str):
    parsed = urlparse(url)
    if parsed.scheme not in ("rediss",):
        raise ValueError("REDIS_CONNECTION_STRING must start with rediss://")
    if not parsed.hostname:
        raise ValueError("REDIS_CONNECTION_STRING missing host")
    if not parsed.username:
        raise ValueError("REDIS_CONNECTION_STRING must include username (objectId or alias)")

    host = parsed.hostname
    port = parsed.port or 6380
    db = int((parsed.path or "/0").lstrip("/") or 0)
    username = parsed.username  # objectId or alias configured on the Redis access policy
    return host, port, db, username


host, port, db, username = _parse_redis_url(REDIS_URL)

r = Redis(
    host=host,
    port=port,
    db=db,
    ssl=True,
    credential_provider=credential_provider,
    # Optionally keepalive/health check (safe defaults)
    health_check_interval=30,
    socket_keepalive=True,
    decode_responses=True,
)

app.config["SESSION_TYPE"] = "redis"
app.config["SESSION_REDIS"] = r
app.config["SESSION_PERMANENT"] = False
# Disable signer to avoid bytes vs str mismatch in some envs (itsdangerous signer returns bytes)
app.config["SESSION_USE_SIGNER"] = False
app.config["SESSION_KEY_PREFIX"] = "flask_session:"
app.config["SESSION_COOKIE_NAME"] = "my_flask_session"
app.config["SESSION_COOKIE_SECURE"] = True
app.config["SESSION_COOKIE_HTTPONLY"] = True
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"

Session(app)


# --------------------------
# Routes
# --------------------------
@app.route("/")
def hello():
    visits = int(session.get("visits", 0)) + 1
    session["visits"] = visits
    return f"Hello, world! Session visits={visits}\n"

@app.route("/startupz", methods=["GET"]) 
def startupz():
    return f"Hello, world!"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "80")), debug=False)