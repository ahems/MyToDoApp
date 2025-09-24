import os
import json
from re import S
import identity.web
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
from urllib.parse import urlparse
import time
import secrets
import requests
from flask import Flask, render_template, request, redirect, url_for, session
from flask_session import Session
from sqlalchemy import null
from recommendation_engine import RecommendationEngine
from tab import Tab
from priority import Priority
from context_processors import inject_current_date
from dotenv import load_dotenv
from azure.identity import DefaultAzureCredential
from azure.identity import ManagedIdentityCredential
from azure.core.credentials import TokenCredential
from azure.keyvault.secrets import SecretClient
from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry import trace
from logging import INFO, getLogger
from typing import Any, Dict, cast
from datetime import datetime
from flask import send_from_directory
load_dotenv()

scope = ["User.Read"]

app = Flask(__name__)

key_vault_name = os.environ.get("KEY_VAULT_NAME")
AZURE_CLIENT_ID = os.environ.get("AZURE_CLIENT_ID")
REDIS_CONNECTION_STRING = os.environ.get("REDIS_CONNECTION_STRING")
IS_LOCALHOST = os.environ.get("IS_LOCALHOST", "false").lower() == "true"

app_insights_connection_string = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")
if not app_insights_connection_string:
    raise ValueError("APPLICATIONINSIGHTS_CONNECTION_STRING environment variable is not set.")
else:
    print("Using App Insights Connection String: ", app_insights_connection_string)

if IS_LOCALHOST:
    managed_identity_credential: TokenCredential = DefaultAzureCredential()
else:
    # Prefer User Assigned MI via client ID when provided; fallback to system-assigned
    if AZURE_CLIENT_ID:
        managed_identity_credential = ManagedIdentityCredential(client_id=AZURE_CLIENT_ID)
    else:
        managed_identity_credential = ManagedIdentityCredential()

configure_azure_monitor(logger_name="my_todoapp_logger",connection_string=app_insights_connection_string,credential=managed_identity_credential)
tracer = trace.get_tracer(__name__)
logger = getLogger("todoapp")
logger.setLevel(INFO)
logger.info("App starting; IS_LOCALHOST=%s KEY_VAULT_NAME=%s API_URL set=%s", IS_LOCALHOST, key_vault_name, bool(os.environ.get("API_URL")))

# Build args for redis-entraid managed identity provider
identity_kind = (
    ManagedIdentityType.USER_ASSIGNED
    if (AZURE_CLIENT_ID)
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
    else:
        raise ValueError(
            "User-assigned managed identity selected, but no id provided. "
            "Set AZURE_CLIENT_ID."
        )

credential_provider = create_from_managed_identity(**mi_kwargs)

# --------------------------------------------------
# Local Development (non-managed-identity) Redis AAD support
# If running locally (IS_LOCALHOST=True) and you set REDIS_LOCAL_PRINCIPAL_ID
# to the Redis Access Policy principal/alias (username) that grants data plane
# access, we will obtain AAD tokens via DefaultAzureCredential and supply them
# to Redis using a lightweight credential provider. This lets you debug locally
# without a managed identity while Redis remains configured for Entra ID only.
#
# Required env vars for local debug:
#   REDIS_CONNECTION_STRING=rediss://<host>:6380/0
#   REDIS_LOCAL_PRINCIPAL_ID=<access policy principal id or alias>
# Optional:
#   AZURE_TENANT_ID / AZURE_CLIENT_ID / AZURE_CLIENT_SECRET (if you want to
#   authenticate with a specific app registration instead of dev CLI/login)
#
# NOTE: We do NOT enable this path in production; managed identity remains the
#       default for non-local environments.
# --------------------------------------------------
if IS_LOCALHOST and os.environ.get("REDIS_LOCAL_PRINCIPAL_ID"):
    try:
        from azure.identity import DefaultAzureCredential as _DevDefaultAzureCredential

        class _LocalDevRedisAADCredentialProvider:  # minimal shim
            def __init__(self, username: str, scope: str = "https://redis.azure.com/.default", skew_seconds: int = 60):
                self._username = username
                self._scope = scope
                self._skew = skew_seconds
                self._cred = _DevDefaultAzureCredential(exclude_managed_identity_credential=True)
                self._token_value = None
                self._expires = 0

            def get_credentials(self):  # redis-entraid style interface (username, bearer_token)
                import time as _time
                now = _time.time()
                if (not self._token_value) or (now > self._expires - self._skew):
                    token = self._cred.get_token(self._scope)
                    self._token_value = token.token
                    # expires_on may be int epoch; fallback to +600s if missing
                    self._expires = getattr(token, 'expires_on', int(now + 600))
                return self._username, self._token_value

        credential_provider = _LocalDevRedisAADCredentialProvider(
            os.environ["REDIS_LOCAL_PRINCIPAL_ID"].strip()
        )
        logger.info("[redis-local-dev] Using local AAD credential provider with principal=%s", os.environ.get("REDIS_LOCAL_PRINCIPAL_ID"))
    except Exception as _e:
        logger.warning("[redis-local-dev] Failed to initialize local AAD provider: %s", _e)
        # Fall back to managed identity provider (may fail if MI unavailable), but we continue.

app.secret_key = (
    os.environ.get("SECRET_KEY")
    or os.environ.get("FLASK_SECRET_KEY")
    or secrets.token_hex(16)
)
logger.info("[init] Flask secret key set; length=%s", len(app.secret_key))
try:
    import hashlib as _hashlib
    _sk_fingerprint = _hashlib.sha256(app.secret_key.encode()).hexdigest()[:12]
    logger.debug("[init] secret key fingerprint=%s (use to detect reload changes)", _sk_fingerprint)
except Exception:
    pass

client = None
if AZURE_CLIENT_ID:
    logger.info('Using Managed Identity to access Key Vault')
    key_vault_uri = f"https://{key_vault_name}.vault.azure.net"
    client = SecretClient(vault_url=key_vault_uri, credential=managed_identity_credential)
    AUTHORITY=client.get_secret("AUTHORITY").value
    CLIENTID=client.get_secret("CLIENTID").value;
    CLIENTSECRET=client.get_secret("CLIENTSECRET").value;
else:
    logger.info('Using Environment Variables');
    AUTHORITY=os.environ.get("AUTHORITY");
    CLIENTID=os.environ.get("CLIENTID");
    CLIENTSECRET=os.environ.get("CLIENTSECRET");

redirect_uri = os.environ.get("REDIRECT_URI")
if not redirect_uri:
    if AZURE_CLIENT_ID and client is not None:
        logger.info('Using Key Vault for REDIRECT-URI')
        redirect_uri = client.get_secret("REDIRECT-URI").value
    if not redirect_uri:
        raise ValueError("REDIRECT-URI variable not in KeyVault or Environment")

api_url = cast(str, os.environ.get("API_URL"))
if not api_url:
    raise ValueError("API_URL environment variable is not set")
else:
    logger.info("Using API URL: %s", api_url)

# Lightweight startup probe endpoint: returns 200 only when a Managed Identity token can be acquired
@app.route("/startupz", methods=["GET"]) 
def startup_probe():

    logger.debug("/startupz: Beginning MI token acquisition attempt")
    try:
        redis_scope = "https://redis.azure.com/.default"
        logger.debug("/startupz: attempting MI token acquisition for redis scope=%s", redis_scope)
        token = managed_identity_credential.get_token(redis_scope)
        logger.debug("/startupz: MI token acquisition attempt complete")
        if token and token.token:
            logger.info("/startupz: token acquired; expires_on=%s", getattr(token, 'expires_on', None))
            return "ok", 200
        return "token not available", 503
    except Exception as ex:
        logger.warning("/startupz: MI token acquisition failed: %s: %s", type(ex).__name__, ex)
        return f"waiting for managed identity: {type(ex).__name__}", 503
    finally:
        logger.debug("/startupz: Finished MI token acquisition attempt")


# --------------------------
# Redis (Entra ID) support
# --------------------------
def _parse_redis_url(url: str):
    parsed = urlparse(url)
    if parsed.scheme not in ("rediss",):
        raise ValueError("REDIS_CONNECTION_STRING must start with rediss://")
    if not parsed.hostname:
        raise ValueError("REDIS_CONNECTION_STRING missing host")

    host = parsed.hostname
    port = parsed.port or 6380
    db = int((parsed.path or "/0").lstrip("/") or 0)
    return host, port, db

# Configure Session Storage
if REDIS_CONNECTION_STRING:
    logger.info('Using Redis Cache to Store Session Data (Entra auth)')
    logger.debug("[redis-setup] REDIS_CONNECTION_STRING present; raw='%s'", REDIS_CONNECTION_STRING)
    host, port, db = _parse_redis_url(REDIS_CONNECTION_STRING)
    # IMPORTANT: Do not set decode_responses=True for the session Redis client.
    # Flask-Session stores pickled (binary) session data; forcing unicode decode
    # can corrupt or fail to deserialize the stored session, leading to MSAL
    # 'no prior log_in() info' issues even when the cookie is present.
    r = Redis(
        host=host,
        port=port,
        db=db,
        ssl=True,
        # Duck-typed credential provider (managed identity or local dev shim)
        credential_provider=credential_provider,  # type: ignore[arg-type]
        # Optionally keepalive/health check (safe defaults)
        health_check_interval=30,
        socket_keepalive=True,
    )
    if IS_LOCALHOST:
        logger.debug("[redis-setup] Pinging Redis to verify connectivity (local dev)")
        try:
            r.ping()
            logger.debug("[redis-setup] Redis ping successful")
        except Exception as e:
            logger.warning("[redis-setup] Redis ping failed: %s", e)

    app.config["SESSION_TYPE"] = "redis"
    app.config["SESSION_REDIS"] = r
    app.config["SESSION_PERMANENT"] = False
    # Disable signer to avoid bytes vs str mismatch in some envs (itsdangerous signer returns bytes)
    app.config["SESSION_USE_SIGNER"] = False
    app.config["SESSION_KEY_PREFIX"] = "flask_session:"
    app.config["SESSION_COOKIE_NAME"] = "my_todo_app_session"
    # Only mark cookie secure when served over HTTPS (i.e., not local http dev)
    if IS_LOCALHOST:
        app.config["SESSION_COOKIE_SECURE"] = False
        app.config["SESSION_COOKIE_SAMESITE"] = "Lax"  # local dev: allow normal nav redirects
    else:
        app.config["SESSION_COOKIE_SECURE"] = True
        # Azure AD redirect back to us is a top-level navigation (GET), Lax usually works.
        # If you later embed the app in an iframe or need POST binding, switch to "None".
        app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
    app.config["SESSION_COOKIE_HTTPONLY"] = True
    logger.info("[redis-setup] Redis configured successfully")
else:
    logger.info('Using File System to Store Session Data')
    app.config['SESSION_TYPE'] = 'filesystem'

logger.info("[init] finalizing session setup")
Session(app)
logger.info("[init] session setup complete")

#! Custom Redis session backend is always enabled when REDIS_CONNECTION_STRING is present
if REDIS_CONNECTION_STRING:
    logger.info("[custom-session] Activating custom Redis session interface override")
    from flask.sessions import SessionInterface, SessionMixin
    import pickle as _pickle
    import secrets as _secrets
    from datetime import timedelta

    class _RedisStoreSession(SessionMixin):
        def __init__(self, initial=None, sid=None, new=False):
            self._data = dict(initial or {})
            self.sid = sid
            self.new = new
            self.modified = False
            self.permanent = False  # honor Flask expectation
        # Mapping interface
        def __getitem__(self, key):
            return self._data[key]
        def __setitem__(self, key, value):
            self._data[key] = value
            self.modified = True
        def __delitem__(self, key):
            del self._data[key]
            self.modified = True
        def get(self, key, default=None):
            return self._data.get(key, default)
        def keys(self):
            return self._data.keys()
        def values(self):
            return self._data.values()
        def items(self):
            return self._data.items()
        def __iter__(self):
            return iter(self._data)
        def __len__(self):
            return len(self._data)
        def clear(self):
            self._data.clear(); self.modified = True
        def pop(self, key, default=None):
            self.modified = True
            return self._data.pop(key, default)
        def update(self, *args, **kwargs):
            self._data.update(*args, **kwargs); self.modified = True
        def to_dict(self):
            return dict(self._data)

    class _CustomRedisSessionInterface(SessionInterface):
        serializer = _pickle
        session_class = _RedisStoreSession

        def __init__(self, redis_client, prefix: str = "flask_session:", default_ttl: int = 3600):
            self.redis = redis_client
            self.key_prefix = prefix
            self.default_ttl = default_ttl

        def generate_sid(self):
            return _secrets.token_hex(16)

        def get_redis_key(self, sid):
            return f"{self.key_prefix}{sid}"

        def open_session(self, app_ref, request):  # type: ignore[override]
            cookie_name = app_ref.config.get("SESSION_COOKIE_NAME", "session")
            sid = request.cookies.get(cookie_name)
            if not sid:
                sid = self.generate_sid()
                sess = self.session_class(sid=sid, new=True)
                # New session created
                return sess
            try:
                stored = self.redis.get(self.get_redis_key(sid))
            except Exception as e:
                logger.warning(f"[custom-session][open] redis get error {type(e).__name__}: {e}")
                stored = None
            if stored:
                try:
                    data = self.serializer.loads(stored)
                except Exception as e:
                    logger.warning(f"[custom-session][open] deserialize error {type(e).__name__}: {e}")
                    data = {}
                sess = self.session_class(initial=data, sid=sid, new=False)
                # Existing session loaded
                return sess
            # No stored session -> new
            sess = self.session_class(sid=sid, new=True)
            # No existing session found
            return sess

        def save_session(self, app_ref, sess, response):  # type: ignore[override]
            cookie_name = app_ref.config.get("SESSION_COOKIE_NAME", "session")
            if not sess:
                # Empty session -> delete
                if getattr(sess, 'sid', None):
                    try:
                        self.redis.delete(self.get_redis_key(sess.sid))
                    except Exception:
                        pass
                response.delete_cookie(cookie_name)
                return
            # Ensure SID
            if not getattr(sess, 'sid', None):
                sess.sid = self.generate_sid()
            ttl_seconds = int(app_ref.permanent_session_lifetime.total_seconds()) if sess.permanent else self.default_ttl
            try:
                # Support both our custom wrapper (with to_dict) and plain dict-like
                raw_dict = sess.to_dict() if hasattr(sess, 'to_dict') else dict(sess)
                payload = self.serializer.dumps(raw_dict)
                self.redis.setex(self.get_redis_key(sess.sid), ttl_seconds, payload)
                # Session persisted
            except Exception as e:
                logger.error(f"[custom-session][save] error {type(e).__name__}: {e}")
            domain = self.get_cookie_domain(app_ref)
            path = self.get_cookie_path(app_ref)
            secure = app_ref.config.get("SESSION_COOKIE_SECURE", False)
            samesite = app_ref.config.get("SESSION_COOKIE_SAMESITE", "Lax")
            httponly = app_ref.config.get("SESSION_COOKIE_HTTPONLY", True)
            response.set_cookie(
                cookie_name,
                sess.sid,
                max_age=ttl_seconds,
                path=path,
                secure=secure,
                httponly=httponly,
                samesite=samesite,
                domain=domain,
            )

    try:
        prefix = app.config.get("SESSION_KEY_PREFIX", "flask_session:")
        app.session_interface = _CustomRedisSessionInterface(app.config.get("SESSION_REDIS"), prefix=prefix)  # type: ignore
        logger.info("[custom-session] Custom Redis session interface installed (prefix=%s)", prefix)
    except Exception as _e_csi:
        logger.error("[custom-session] Failed to install custom session interface: %s", _e_csi)

## Debug session instrumentation removed for production hardening

# This section is needed for url_for("foo", _external=True) to automatically
# generate http scheme when this sample is running on localhost,
# and to generate https scheme when it is deployed behind reversed proxy.
# See also https://flask.palletsprojects.com/en/2.2.x/deploying/proxy_fix/
if IS_LOCALHOST:
    try:
        from werkzeug.middleware.proxy_fix import ProxyFix  # type: ignore[import]
        app.wsgi_app = ProxyFix(app.wsgi_app, x_proto=1, x_host=1)
    except Exception as e:
        logger.warning("ProxyFix not available: %s", e)

logger.info("[init] setting up MSAL authentication")
auth = identity.web.Auth(
    session=session,
    authority=AUTHORITY,
    client_id=CLIENTID,
    client_credential=CLIENTSECRET,
)
logger.info("[init] MSAL authentication setup complete")

@app.context_processor
def inject_common_variables():
    return inject_current_date()

@app.before_request
def load_data_to_session():
    logger.debug("[before_request] loading data into session")

    # Avoid touching the session for health/debug/static requests to prevent Redis writes
    if (
        request.endpoint in {"startup_probe", "debug_probe"}
        or request.path in {"/startupz", "/debugz", "/favicon.ico", "/login", "/getAToken"}
        or request.path.startswith("/static/")
    ):
        logger.debug("[before_request] skipping session load for endpoint=%s", request.endpoint)
        return

    user = auth.get_user()
    if user is None:
        logger.debug("[before_request] no authenticated user; clearing session todos")
        session["todos"] = None
        return
    
    logger.debug("[before_request] authenticated user found; loading todos")
    oid = user.get("oid") if isinstance(user, dict) else None
    if not oid:
        logger.debug("[before_request] authenticated user has no OID; clearing session todos")
        session["todos"] = None
        return
    logger.debug("[before_request] authenticated user OID: %s", oid)
       
    global api_url
    logger.debug("[before_request] Loading existing ToDo's from API for OID: %s", oid)

    headers = {
        "Content-Type" : "application/json",
        "Authorization" : f"Bearer {auth.get_token_for_user(scope)['access_token']}",
        "X-MS-API-ROLE" : "MyToDoApp"
    }

    query = f"""
    {{
        todos(filter: {{ oid: {{ eq: "{oid}" }} }}) {{
                items {{
                    id
                    name
                    recommendations_json
                    notes
                    priority
                    completed
                    due_date
                    oid
                }}
            }}
        }}
    """

    # The payload for the POST request
    payload = {"query": query}

    # Make the POST request
    response = requests.post(api_url, json=payload, headers=headers)
    logger.debug("[load_data] GraphQL todos response status=%s", response.status_code)

    if response.status_code == 200:
        todos = response.json().get("data").get("todos").get("items")
        session["todos"] = todos
    else:
        logger.warning("Failed to load data from API - %s", response.text)
        session["todos"] = None

    session["todo"] =None
    session["TabEnum"] = Tab
    session["PriorityEnum"] = Priority
    session["selectedTab"] =Tab.NONE

@app.route("/")
def index():

    user = auth.get_user()
    if not user:
        return redirect(url_for("login"))
    else:
        load_data_to_session()
        session["name"] = user.get("name") if isinstance(user, dict) else None
        session["token"] = auth.get_token_for_user(scope)['access_token']
        session["TabEnum"] = Tab
        session["selectedTab"] =Tab.NONE
        return render_template("index.html")
@app.route("/add", methods=["POST"])
def add_todo():

    global api_url

    user = auth.get_user()
    if not user:
        return redirect(url_for("login"))

    logger.info("Adding TODO: User OID: %s", user.get("oid") if isinstance(user, dict) else None)

    mutation = """
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
    """
    # Prepare the variables
    variables = {
        "name": request.form["todo"],
        "oid": user.get("oid") if isinstance(user, dict) else None
    }

    headers = {
        'Content-Type' : 'application/json',
        'Authorization' : f"Bearer {auth.get_token_for_user(scope)['access_token']}",
        'X-MS-API-ROLE' : 'MyToDoApp'
    }

    # Send the request
    response = requests.post(api_url, json={'query': mutation, 'variables': variables}, headers=headers)

    # Check for errors or handle the response as needed
    if response.status_code == 200:
        return redirect(url_for('index'))
    else:
        error_message = response.json().get('errors', [{'message': 'Unknown error'}])[0]['message']
        logger.error('Add TODO error: %s', error_message)
        return f'An error occurred: {error_message}', 500

# Details of ToDo Item
@app.route('/details/<int:id>', methods=['GET'])
def details(id):

    if not auth.get_user():
        return redirect(url_for("login"))
    
    global api_url
    
    todo = get_todo_by_id(id, auth.get_token_for_user(scope)['access_token'], api_url)

    if todo is None:
        return redirect(url_for('index'))
    
    session["selectedTab"] =Tab.DETAILS
    session["todo"] = todo
    
    return render_template('index.html')

# Edit a new ToDo
@app.route('/edit/<int:id>', methods=['GET'])
def edit(id):

    if not auth.get_user():
        return redirect(url_for("login"))
    
    global api_url
    
    todo = get_todo_by_id(id, auth.get_token_for_user(scope)['access_token'], api_url)

    if todo is None:
        return redirect(url_for('index'))
    
    session["todo"] =todo
    session["selectedTab"] =Tab.EDIT
    
    return render_template('index.html')

# Save existing To Do Item
@app.route('/update/<int:id>', methods=['POST'])
def update_todo(id):

    if not auth.get_user():
        return redirect(url_for("login"))

    session["selectedTab"] =Tab.DETAILS

    if request.form.get('cancel') != None:
        return redirect(url_for('index'))

    # Get the data from the form
    name = request.form['name']
    due_date = request.form.get('duedate')
    notes=request.form.get('notes')
    priority=request.form.get('priority')
    completed=request.form.get('completed')

    # Prepare the GraphQL mutation
    mutation = """
    mutation UpdateTodo($id: Int!, $name: String!, $due_date: String, $notes: String, $priority: Int, $completed: Boolean) {
        updatetodo(id: $id, item: {
            name: $name,
            due_date: $due_date,
            notes: $notes,
            priority: $priority,
            completed: $completed
        }) {
            id
            name
            due_date
            notes
            priority
            completed
        }
    }
    """

    # Prepare the variables
    variables = {
        "id": id,
        "name": name,
        "due_date": due_date if due_date != "None" else None,
        "notes": notes,
        "priority": int(priority) if priority is not None else None,
        "completed": completed == "on"
    }

    headers = {
        'Content-Type' : 'application/json',
        'Authorization' : f"Bearer {auth.get_token_for_user(scope)['access_token']}",
        'X-MS-API-ROLE' : 'MyToDoApp'
    }

    # Send the request
    response = requests.post(api_url, json={'query': mutation, 'variables': variables}, headers=headers)
    logger.debug("[update_todo] GraphQL update response status=%s", response.status_code)

    # Check for errors or handle the response as needed
    if response.status_code == 200:
        return redirect(url_for('index'))
    else:
        error_message = response.json().get('errors', [{'message': 'Unknown error'}])[0]['message']
        logger.error('Update TODO error: %s', error_message)
        return f'An error occurred: {error_message}', 500


# Delete a ToDo
@app.route('/remove/<int:id>', methods=["POST", "GET"])
def remove_todo(id):

    if not auth.get_user():
        return redirect(url_for("login"))

    # Prepare the GraphQL mutation
    mutation = """
    mutation RemoveTodo($id: Int!) {
        deletetodo(id: $id) {
            id
        }
    }
    """

    # Prepare the variables
    variables = {
        "id": id
    }

    headers = {
        'Content-Type' : 'application/json',
        'Authorization' : f"Bearer {auth.get_token_for_user(scope)['access_token']}",
        'X-MS-API-ROLE' : 'MyToDoApp'
    }

    # Send the request
    response = requests.post(api_url, json={'query': mutation, 'variables': variables}, headers=headers)
    logger.debug("[remove_todo] GraphQL delete response status=%s", response.status_code)

    # Check for errors or handle the response as needed
    if response.status_code == 200:
        session["selectedTab"] = Tab.NONE
        return redirect(url_for('index'))
    else:
        error_message = response.json().get('errors', [{'message': 'Unknown error'}])[0]['message']
        logger.error('Remove TODO error: %s', error_message)
        return f'An error occurred: {error_message}', 500

# Show AI recommendations
@app.route('/recommend/<int:id>', methods=['GET'])
@app.route('/recommend/<int:id>/<refresh>', methods=['GET'])
async def recommend(id, refresh=False):

    if not auth.get_user():
        return redirect(url_for("login"))

    global api_url
    session["selectedTab"] = Tab.RECOMMENDATIONS
    recommendation_engine = RecommendationEngine()
    
    todo = get_todo_by_id(id, auth.get_token_for_user(scope)['access_token'], api_url)

    if todo is None:
        return redirect(url_for('index'))

    session["todo"] = todo

    if session["todo"] and not refresh:
        try:
            # Attempt to load any saved recommendation from the API response
            if session["todo"].get('recommendations_json') is not None:
                session["todo"]['recommendations'] = json.loads(session["todo"]['recommendations_json'])
                return render_template('index.html', appinsights_connection_string=app_insights_connection_string)
        except ValueError as e:
            with tracer.start_as_current_span("app_initialization_span"):print("Error: %s", e)

    previous_links_str = None
    if refresh:
        session["todo"]['recommendations'] = json.loads(session["todo"]['recommendations_json'])
        # Extract links
        links = [item["link"] for item in session["todo"]['recommendations']]
        # Convert list of links to a single string
        previous_links_str = ", ".join(links)

    session["todo"]['recommendations'] = await recommendation_engine.get_recommendations(session["todo"]['name'], previous_links_str)

    # Prepare the GraphQL mutation to save the recommendations
    mutation = """
    mutation UpdateTodoRecommendations($id: Int!, $recommendations_json: String!) {
        updatetodo(id: $id, item: { recommendations_json: $recommendations_json}) {
            id
            recommendations_json
        }
    }
    """

    # Prepare the variables for the mutation
    variables = {
        "id": id,
        "recommendations_json": json.dumps(session["todo"]['recommendations'])
    }

    headers = {
        'Content-Type' : 'application/json',
        'Authorization' : f"Bearer {auth.get_token_for_user(scope)['access_token']}",
        'X-MS-API-ROLE' : 'MyToDoApp'
    }

    # Send the request to save the recommendations
    response = requests.post(api_url, json={'query': mutation, 'variables': variables}, headers=headers)
    logger.debug("[recommend] GraphQL update recommendations response status=%s", response.status_code)

    if response.status_code != 200:
        error_message = response.json().get('errors', [{'message': 'Unknown error'}])[0]['message']
        logger.error('Recommend error: %s', error_message)
        return f'An error occurred: {error_message}', 500

    return render_template('index.html', appinsights_connection_string=app_insights_connection_string)

@app.route('/completed/<int:id>/<complete>', methods=['GET'])
def completed(id, complete):

    if not auth.get_user():
        return redirect(url_for("login"))

    session["selectedTab"] = Tab.NONE

    global api_url
    
    todo = get_todo_by_id(id, auth.get_token_for_user(scope)['access_token'], api_url)

    if todo is None:
        return redirect(url_for('index'))
    
    session["todo"] = todo

    # Update the completion status based on the 'complete' parameter
    if complete == "true":
        session["todo"]['completed'] = True
    elif complete == "false":
        session["todo"]['completed'] = False

    # Prepare the GraphQL mutation to update the completion status
    mutation = """
    mutation UpdateTodoCompletion($id: Int!, $completed: Boolean!) {
        updatetodo(id: $id, item: { completed: $completed }) {
            id
            completed
        }
    }
    """

    headers = {
        'Content-Type' : 'application/json',
        'Authorization' : f"Bearer {auth.get_token_for_user(scope)['access_token']}",
        'X-MS-API-ROLE' : 'MyToDoApp'
    }

    # Prepare the variables for the mutation
    variables = {
        "id": id,
        "completed": session["todo"]['completed']
    }

    # Send the request to update the completion status
    response = requests.post(api_url, json={'query': mutation, 'variables': variables}, headers=headers)
    logger.debug("[completed] GraphQL update completion response status=%s", response.status_code)

    if response.status_code != 200:
        error_message = response.json().get('errors', [{'message': 'Unknown error'}])[0]['message']
        logger.error('Completion update error: %s', error_message)
        return f'An error occurred: {error_message}', 500

    return redirect(url_for('index'))

@app.route("/login")
def login():

    global redirect_uri

    if IS_LOCALHOST:
        redirect_uri=url_for("auth_response", _external=True)
        session["__login_probe"] = True # mark session for login flow
    else:
        logger.debug("Redirect URI: %s", redirect_uri)

    _login_ctx = auth.log_in(
        scopes=["User.Read"],
        redirect_uri=redirect_uri,
        prompt="select_account",
    )
    logger.info("[login] session established; sid=%s key_count=%d", getattr(session, 'sid', None), len(session.keys()))
    logger.debug("[login] context keys returned: %s", list(_login_ctx.keys()))
    return render_template("login.html", **_login_ctx)

@app.route("/getAToken")
def auth_response():
    result = auth.complete_log_in(request.args)
    logger.debug("[auth_response] session keys now=%d sid=%s", len(session.keys()), getattr(session, 'sid', None))
    if "error" in result:
        return render_template("auth_error.html", result=result)
   
    return redirect(url_for("index"))

@app.route("/logout")
def logout():

    # Clear session variables
    session.pop('oid', None)
    session.pop('name', None)
    session.pop('todos', None)
    session.pop('todo', None)

    return redirect(auth.log_out(url_for("index", _external=True)))


def get_todo_by_id(id, token, api_url):

    # Prepare the GraphQL query to fetch the todo item
    query = """
        query Todo_by_pk($id: Int!) {
            todo_by_pk(id: $id) {
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
    """
    variables = {"id": id}

    headers = {
        'Content-Type' : 'application/json',
        'Authorization' : f"Bearer {auth.get_token_for_user(scope)['access_token']}"
    }

    # Send the request to fetch the todo item
    response = requests.post(api_url, json={'query': query, 'variables': variables}, headers=headers)
    logger.debug("[get_todo_by_id] status=%s for id=%s", response.status_code, id)

    if response.status_code == 200:
        todo = response.json().get('data', {}).get('todo_by_pk')
        if todo:
            return todo
        else:
            return "Todo item not found", 404
    else:
        error_message = response.json().get('errors', [{'message': 'Unknown error'}])[0]['message']
        logger.error('Get TODO by id error: %s', error_message)
        return f'An error occurred: {error_message}', 500

if __name__ == "__main__":
    # Do NOT reassign secret_key here; earlier initialization already set it from env or generated one.
    # Re-randomizing here would invalidate any session cookies issued before a live reload.
    if IS_LOCALHOST:
        app.run(host="localhost", port=5000, debug=True)
    else:
        app.run(host="0.0.0.0", port=80, debug=False)

# Serve a favicon without engaging session/Redis
@app.route('/favicon.ico')
def favicon():
    try:
        return send_from_directory(
            os.path.join(app.root_path, 'static', 'images'),
            'favicon.ico',
            mimetype='image/vnd.microsoft.icon'
        )
    except Exception:
        # Return a tiny empty response if file missing
        return ("", 204)