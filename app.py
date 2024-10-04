import os
import json
from re import S
import identity.web
import redis
import secrets
import requests
from flask import Flask, render_template, request, redirect, url_for, session, url_for
from flask_session import Session
from sqlalchemy import null
from database import db, Todo
from recommendation_engine import RecommendationEngine
from tab import Tab
from priority import Priority
from context_processors import inject_current_date
from dotenv import load_dotenv
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry import trace
from logging import INFO, getLogger
load_dotenv()

# Configure OpenTelemetry to use Azure Monitor with the 
# APPLICATIONINSIGHTS_CONNECTION_STRING environment variable.
configure_azure_monitor(logger_name="my_todoapp_logger",)
logger = getLogger("my_todoapp_logger")
logger.setLevel(INFO)

app = Flask(__name__)

# No Entra ID auth - connection_string = f"mssql+pyodbc://{sql_user_name}:{sql_password}@{azure_sql_server}:{azure_sql_port}/todo?driver=ODBC+Driver+18+for+SQL+Server"
# Entra ID auth - connection_string = f"mssql+pyodbc://@{azure_sql_server}:{azure_sql_port}/todo?driver=ODBC+Driver+18+for+SQL+Server;Authentication=ActiveDirectoryMsi;"
driver="{ODBC Driver 18 for SQL Server}"

key_vault_name = os.environ.get("KEY_VAULT_NAME")
AZURE_CLIENT_ID = os.environ.get("AZURE_CLIENT_ID")
IS_LOCALHOST=os.environ.get("IS_LOCALHOST");

if AZURE_CLIENT_ID:
    print('Using Managed Identity to access Key Vault')
    credential = DefaultAzureCredential()
    key_vault_uri = f"https://{key_vault_name}.vault.azure.net"
    client = SecretClient(vault_url=key_vault_uri, credential=credential)
    AUTHORITY=client.get_secret("AUTHORITY").value;
    CLIENTID=client.get_secret("CLIENTID").value;
    CLIENTSECRET=client.get_secret("CLIENTSECRET").value;
    REDIS_CONNECTION_STRING=client.get_secret("REDIS-CONNECTION-STRING").value;
    redirect_uri = client.get_secret("REDIRECT-URI").value;
    api_url = client.get_secret("API-URL").value;
else:
    AUTHORITY=os.environ.get("AUTHORITY");
    CLIENTID=os.environ.get("CLIENTID");
    CLIENTSECRET=os.environ.get("CLIENTSECRET");
    REDIS_CONNECTION_STRING=os.environ.get("REDIS_CONNECTION_STRING");
    api_url = os.environ.get("API_URL");

# Configure Session Storage
if REDIS_CONNECTION_STRING:
    print('Using Redis Cache to Store Session Data')
    app.config['SESSION_TYPE'] = 'redis'
    app.config['SESSION_REDIS'] = redis.from_url(REDIS_CONNECTION_STRING)
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

# Use local database if Azure SQL server is not configured
connection_string = os.environ.get("DATABASE_CONNECTION_STRING")

if not connection_string:
    print('DATABASE_CONNECTION_STRING environment variable missing, Using local SQLLite database')
    basedir = os.path.abspath(os.path.dirname(__file__))   # Get the directory of the this file
    print('Base directory:', basedir)
    todo_file = os.path.join(basedir, 'todo_list.txt')     # Create the path to the to-do list file using the directory
    app.config["SQLALCHEMY_DATABASE_URI"] = 'sqlite:///' + os.path.join(basedir, 'todos.db')
else:
    app.config["SQLALCHEMY_DATABASE_URI"] = connection_string

print('Initializing App')
db.init_app(app)
print('App Initialized')

@app.context_processor
def inject_common_variables():
    return inject_current_date()

print('Initializing Database')
with app.app_context():
    db.create_all()
print('Database Initialized')

@app.before_request
def load_data_to_session():

    global api_url
    print("Loading data from API for OID: ", session.get("oid"))

    headers = {
        "Content-Type": "application/json",
        'Authorization': f'Bearer {session.get("token")}'
    }

    query = f"""
    {{
        todos(filter: {{ oid: {{ eq: "{session.get("oid")}" }} }}) {{
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

    session["todos"] =todos 
    session["todo"] =None
    session["TabEnum"] = Tab
    session["PriorityEnum"] = Priority
    session["selectedTab"] =Tab.NONE

@app.route("/")
def index():

    scope = ["User.Read"]

    if not auth.get_user():
        return redirect(url_for("login"))
    else:
        session["oid"] = auth.get_user().get("oid")
        session["name"] = auth.get_user().get("name")
        session["token"] = auth.get_token_for_user(scope)['access_token']
        return render_template("index.html")  

@app.route("/add", methods=["POST"])
def add_todo():

    global api_url

    #todo = Todo(
    #    name=request.form["todo"]
    #)
    #todo.oid = session.get("oid")
    #db.session.add(todo)
    #db.session.commit()
    print("Adding TODO: User OID: ", session.get("oid"))

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
        "oid": session.get("oid")
    }

    headers = {
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {session.get("token")}'
    }

    # Send the request
    response = requests.post(api_url, json={'query': mutation, 'variables': variables}, headers=headers)

    # Check for errors or handle the response as needed
    if response.status_code == 200:
        # Success handling, redirect to index
        return redirect(url_for('index'))
    else:
        return "An error occurred", 500

# Details of ToDo Item
@app.route('/details/<int:id>', methods=['GET'])
def details(id):

    if not auth.get_user():
        return redirect(url_for("login"))
    
    # todo = Todo.query.filter_by(id=id,oid=session.get("oid")).first()

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
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {session.get("token")}'
    }

    response = requests.post(api_url, json={'query': query, 'variables': variables}, headers=headers)
    
    # Check if the request was successful
    if response.status_code == 200:
        # Extract the data from the response
        todo = response.json().get("data", {}).get("todo_by_pk", None)
    else:
        print("Failed to load data from API -" + response.text)

    if todo is None:
        return redirect(url_for('index'))
    
    session["selectedTab"] =Tab.DETAILS
    session["todos"] =Todo.query.filter_by(oid=session.get("oid")).all()
    session["todo"] =todo
    
    return render_template('index.html')

# Edit a new ToDo
@app.route('/edit/<int:id>', methods=['GET'])
def edit(id):

    if not auth.get_user():
        return redirect(url_for("login"))
    
    todo = Todo.query.filter_by(id=id,oid=session.get("oid")).first()
    if todo is None:
        return redirect(url_for('index'))

    session["selectedTab"] =Tab.EDIT
    session["todos"] =Todo.query.filter_by(oid=session.get("oid")).all()
    session["todo"] =todo

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

    todo = db.session.query(Todo).filter_by(id=id,oid=session.get("oid")).first()
    if todo != None:
        todo.name = name

        if due_date != "None":
            todo.due_date = due_date

        if notes != None:
            todo.notes = notes

        if priority != None:
            todo.priority = int(priority) 

        if completed == None:
            todo.completed = False
        elif completed == "on":
            todo.completed = True
    #
    db.session.add(todo)
    db.session.commit()
    #
    return redirect(url_for('index'))


# Delete a ToDo
@app.route('/remove/<int:id>', methods=["POST", "GET"])
def remove_todo(id):

    if not auth.get_user():
        return redirect(url_for("login"))
    
    todo = Todo.query.filter_by(id=id,oid=session.get("oid")).first()
    if todo is None:
        return redirect(url_for('index'))

    session["selectedTab"] =Tab.NONE
    db.session.delete(todo)
    db.session.commit()

    return redirect(url_for('index'))

# Show AI recommendations
@app.route('/recommend/<int:id>', methods=['GET'])
@app.route('/recommend/<int:id>/<refresh>', methods=['GET'])
async def recommend(id, refresh=False):

    if not auth.get_user():
        return redirect(url_for("login"))

    session["selectedTab"] =Tab.RECOMMENDATIONS
    recommendation_engine = RecommendationEngine()
    session["todo"] =db.session.query(Todo).filter_by(id=id,oid=session.get("oid")).first()

    if session["todo"] and not refresh:
        try:
            #attempt to load any saved recommendation from the DB
            if session["todo"].recommendations_json is not None:
                session["todo"].recommendations = json.loads(session["todo"].recommendations_json)
                return render_template('index.html')
        except ValueError as e:
            print("Error:", e)

    previous_links_str = None
    if refresh:
        session["todo"].recommendations = json.loads(session["todo"].recommendations_json)
        # Extract links
        links = [item["link"] for item in session["todo"].recommendations]
        # Convert list of links to a single string
        previous_links_str = ", ".join(links)

    session["todo"].recommendations = await recommendation_engine.get_recommendations(session["todo"].name, previous_links_str)
    
    # Save the recommendations to the database
    try:
        session["todo"].recommendations_json = json.dumps(session["todo"].recommendations)
        db.session.add(session["todo"])
        db.session.commit()
    except Exception as e:
        print(f"Error adding and committing todo: {e}")
        return

    return render_template('index.html')

@app.route('/completed/<int:id>/<complete>', methods=['GET'])
def completed(id, complete):

    if not auth.get_user():
        return redirect(url_for("login"))

    session["selectedTab"] =Tab.NONE
    session["todo"] =Todo.query.filter_by(id=id,oid=session.get("oid")).first()

    if (session["todo"] != None and complete == "true"):
        session["todo"].completed = True
    elif (session["todo"] != None and complete == "false"):
        session["todo"].completed = False
    #
    db.session.add(session["todo"])
    db.session.commit()
    #
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

if __name__ == "__main__":
    app.secret_key = secrets.token_hex(8)
    if IS_LOCALHOST:
        app.run(host="localhost",port=5000,debug=True)
    else:
        app.run(host="0.0.0.0",port=80,debug=False)