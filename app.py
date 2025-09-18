import os
import json
from re import S
from httpx import get
import identity.web
import redis
from redis.connection import SSLConnection
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
from azure.keyvault.secrets import SecretClient
from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry import trace
from logging import INFO, getLogger
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

if IS_LOCALHOST:
    credential = DefaultAzureCredential()
else:
    credential = ManagedIdentityCredential(client_id=AZURE_CLIENT_ID)

if AZURE_CLIENT_ID:
    print('Using Managed Identity to access Key Vault')
    key_vault_uri = f"https://{key_vault_name}.vault.azure.net"
    client = SecretClient(vault_url=key_vault_uri, credential=credential)
    AUTHORITY=client.get_secret("AUTHORITY").value
    CLIENTID=client.get_secret("CLIENTID").value;
    CLIENTSECRET=client.get_secret("CLIENTSECRET").value;
else:
    print('Using Environment Variables');
    AUTHORITY=os.environ.get("AUTHORITY");
    CLIENTID=os.environ.get("CLIENTID");
    CLIENTSECRET=os.environ.get("CLIENTSECRET");

redirect_uri = os.environ.get("REDIRECT_URI");
if not redirect_uri:
    print('Using Key Vault for REDIRECT-URI');
    redirect_uri = client.get_secret("REDIRECT-URI").value;
    if not redirect_uri:
        raise ValueError("REDIRECT-URI variable not in KeyVault or Environment")

api_url = os.environ.get("API_URL");
if not api_url:
    raise ValueError("API_URL environment variable is not set")

app_insights_connection_string = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")
if not app_insights_connection_string:
    raise ValueError("APPLICATIONINSIGHTS_CONNECTION_STRING environment variable is not set.")

configure_azure_monitor(logger_name="my_todoapp_logger",connection_string=app_insights_connection_string,credential=credential)
logger = getLogger("my_todoapp_logger")
logger.setLevel(INFO)

# Lightweight startup probe endpoint: returns 200 only when a Managed Identity token can be acquired
@app.route("/startupz", methods=["GET"]) 
def startup_probe():
    try:
        # Use the already-configured credential. For SQL, request the default scope.
        # Any 2xx response signals success to the Container Apps startup probe.
        scope = "https://database.windows.net/.default"
        token = credential.get_token(scope)
        if token and token.token:
            return "ok", 200
        return "token not available", 503
    except Exception as ex:
        # During cold start, MI can take a few seconds to be available.
        return f"waiting for managed identity: {type(ex).__name__}", 503

def _parse_redis_url(url: str):
    parsed = urlparse(url)
    host = parsed.hostname
    port = parsed.port or 6380
    # Username is the objectIdAlias (or objectId) for Entra auth
    username = parsed.username
    # DB index from path, default 0
    try:
        db = int(parsed.path.lstrip('/') or 0)
    except Exception:
        db = 0
    ssl_required = parsed.scheme == 'rediss'
    if not host:
        raise ValueError('REDIS_CONNECTION_STRING is invalid: host missing')
    if not username:
        raise ValueError('REDIS_CONNECTION_STRING must include username (objectId or alias) for Entra auth')
    return host, port, username, db, ssl_required


class EntraRedisSSLConnection(SSLConnection):
    """An SSL-enabled redis-py connection that authenticates using a Microsoft Entra token.

    This subclass ensures TLS is used without relying on the 'ssl' kwarg, which is not
    accepted by AbstractConnection in redis-py 5.x. It refreshes tokens on (re)connect.
    """

    def __init__(self, *args, credential: object, username: str, **kwargs):
        self._credential = credential
        self._aad_scope = 'https://redis.azure.com/.default'
        self._aad_username = username
        self._cached_token = None
        self._cached_exp = 0
        # Do not pass unknown kwargs like 'ssl' to the base class
        super().__init__(*args, **kwargs)

    def _get_token(self) -> str:
        now = int(time.time())
        if not self._cached_token or now > (self._cached_exp - 300):
            token = self._credential.get_token(self._aad_scope)
            self._cached_token = token.token
            self._cached_exp = getattr(token, 'expires_on', now + 3600)
        return self._cached_token

    def on_connect(self):
        self.username = self._aad_username
        self.password = self._get_token()
        return super().on_connect()


# Configure Session Storage
if REDIS_CONNECTION_STRING:
    print('Using Redis Cache to Store Session Data (Entra auth)')
    host, port, username, db, ssl_required = _parse_redis_url(REDIS_CONNECTION_STRING)
    # Enforce TLS-only usage
    if not ssl_required:
        raise ValueError('REDIS_CONNECTION_STRING must use rediss:// (TLS)')
    conn_cls = EntraRedisSSLConnection
    # Build a connection pool without passing unsupported kwargs like 'ssl' to the connection
    pool = redis.ConnectionPool(
        connection_class=conn_cls,
        host=host,
        port=port,
        db=db,
        credential=credential,
        username=username,
    )
    app.config['SESSION_TYPE'] = 'redis'
    # Pass health/retry options to the client instead of the pool to avoid invalid kwargs
    app.config['SESSION_REDIS'] = redis.Redis(
        connection_pool=pool,
        health_check_interval=30,
        retry_on_timeout=True,
        socket_keepalive=True,
    )
else:
    print('Using File System to Store Session Data')
    app.config['SESSION_TYPE'] = 'filesystem'

Session(app)

# This section is needed for url_for("foo", _external=True) to automatically
# generate http scheme when this sample is running on localhost,
# and to generate https scheme when it is deployed behind reversed proxy.
# See also https://flask.palletsprojects.com/en/2.2.x/deploying/proxy_fix/
if IS_LOCALHOST:
    from werkzeug.middleware.proxy_fix import ProxyFix
    app.wsgi_app = ProxyFix(app.wsgi_app, x_proto=1, x_host=1)

auth = identity.web.Auth(
    session=session,
    authority=AUTHORITY,
    client_id=CLIENTID,
    client_credential=CLIENTSECRET,
)

@app.context_processor
def inject_common_variables():
    return inject_current_date()

@app.before_request
def load_data_to_session():

    if auth.get_user() is None:
        session["todos"] = null
        return
    
    oid = auth.get_user().get("oid")
       
    global api_url
    print("Loading existing ToDo's from API for OID: ", oid)

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

    if response.status_code == 200:
        todos = response.json().get("data").get("todos").get("items")
        session["todos"] = todos
    else:
        print("Failed to load data from API -" + response.text)
        session["todos"] = null

    session["todo"] =None
    session["TabEnum"] = Tab
    session["PriorityEnum"] = Priority
    session["selectedTab"] =Tab.NONE

@app.route("/")
def index():

    if not auth.get_user():
        return redirect(url_for("login"))
    else:
        load_data_to_session()
        session["name"] = auth.get_user().get("name")
        session["token"] = auth.get_token_for_user(scope)['access_token']
        session["TabEnum"] = Tab
        session["selectedTab"] =Tab.NONE
        return render_template("index.html")

@app.route("/add", methods=["POST"])
def add_todo():

    global api_url

    print("Adding TODO: User OID: ", auth.get_user().get("oid"))

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
        "oid": auth.get_user().get("oid")
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
        logger.error(f'An error occurred: {error_message}')
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

    # Check for errors or handle the response as needed
    if response.status_code == 200:
        return redirect(url_for('index'))
    else:
        error_message = response.json().get('errors', [{'message': 'Unknown error'}])[0]['message']
        logger.error(f'An error occurred: {error_message}')
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

    # Check for errors or handle the response as needed
    if response.status_code == 200:
        session["selectedTab"] = Tab.NONE
        return redirect(url_for('index'))
    else:
        error_message = response.json().get('errors', [{'message': 'Unknown error'}])[0]['message']
        logger.error(f'An error occurred: {error_message}')
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
            print("Error:", e)

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

    if response.status_code != 200:
        error_message = response.json().get('errors', [{'message': 'Unknown error'}])[0]['message']
        logger.error(f'An error occurred: {error_message}')
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

    if response.status_code != 200:
        error_message = response.json().get('errors', [{'message': 'Unknown error'}])[0]['message']
        logger.error(f'An error occurred: {error_message}')
        return f'An error occurred: {error_message}', 500

    return redirect(url_for('index'))

@app.route("/login")
def login():

    global redirect_uri

    if IS_LOCALHOST:
        redirect_uri=url_for("auth_response", _external=True)
    else:
        print(f"Redirect URI: {redirect_uri}")

    return render_template("login.html", **auth.log_in(
        scopes=["User.Read"], # Have user consent to scopes during log-in
        redirect_uri=redirect_uri, # Optional. If present, this absolute URL must match your app's redirect_uri registered in Azure Portal
        prompt="select_account",  # Optional. More values defined in  https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
        ))

@app.route("/getAToken")
def auth_response():
    result = auth.complete_log_in(request.args)
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

    if response.status_code == 200:
        todo = response.json().get('data', {}).get('todo_by_pk')
        if todo:
            return todo
        else:
            return "Todo item not found", 404
    else:
        error_message = response.json().get('errors', [{'message': 'Unknown error'}])[0]['message']
        logger.error(f'An error occurred: {error_message}')
        return f'An error occurred: {error_message}', 500

if __name__ == "__main__":
    app.secret_key = secrets.token_hex(8)
    if IS_LOCALHOST:
        app.run(host="localhost",port=5000,debug=True)
    else:
        app.run(host="0.0.0.0",port=80,debug=False)