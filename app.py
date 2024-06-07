import os
import json
import identity.web
import requests
from flask import Flask, render_template, request, redirect, url_for, g, session, url_for
from flask_session import Session
from database import db, Todo
from recommendation_engine import RecommendationEngine
from tab import Tab
from priority import Priority
from context_processors import inject_current_date
from dotenv import load_dotenv
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
import pyodbc
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
Session(app, session_type="filesystem")

# mssql+pyodbc://<sql user name>:<password>@<azure sql server>.database.windows.net:1433/todo?driver=ODBC+Driver+17+for+SQL+Server
# logger.info(pyodbc.drivers())
driver="{ODBC Driver 18 for SQL Server}"

key_vault_name = os.environ.get("KEY_VAULT_NAME")
AZURE_CLIENT_ID = os.environ.get("AZURE_CLIENT_ID")

if AZURE_CLIENT_ID:
    logger.info('Using Managed Identity to access Key Vault')
    credential = DefaultAzureCredential()
    key_vault_uri = f"https://{key_vault_name}.vault.azure.net"
    client = SecretClient(vault_url=key_vault_uri, credential=credential)
    sql_user_name = client.get_secret("AZURESQLUSER").value;
    sql_password = client.get_secret("AZURESQLPASSWORD").value;
    azure_sql_server= client.get_secret("AZURESQLSERVER").value;
    azure_sql_port = client.get_secret("AZURESQLPORT").value;
    AUTHORITY=client.get_secret("AUTHORITY").value;
    CLIENTID=client.get_secret("CLIENTID").value;
    CLIENTSECRET=client.get_secret("CLIENTSECRET").value;
else:
    sql_user_name = os.environ.get("AZURE_SQL_USER");
    sql_password = os.environ.get("AZURE_SQL_PASSWORD");
    azure_sql_server= os.environ.get("AZURE_SQL_SERVER");
    azure_sql_port = os.environ.get("AZURE_SQL_PORT");
    AUTHORITY=os.environ.get("AUTHORITY");
    CLIENTID=os.environ.get("CLIENTID");
    CLIENTSECRET=os.environ.get("CLIENTSECRET");

# This section is needed for url_for("foo", _external=True) to automatically
# generate http scheme when this sample is running on localhost,
# and to generate https scheme when it is deployed behind reversed proxy.
# See also https://flask.palletsprojects.com/en/2.2.x/deploying/proxy_fix/
from werkzeug.middleware.proxy_fix import ProxyFix
app.wsgi_app = ProxyFix(app.wsgi_app, x_proto=1, x_host=1)

auth = identity.web.Auth(
    session=session,
    authority=AUTHORITY,
    client_id=CLIENTID,
    client_credential=CLIENTSECRET,
)

connection_string = f"mssql+pyodbc://{sql_user_name}:{sql_password}@{azure_sql_server}:{azure_sql_port}/todo?driver=ODBC+Driver+18+for+SQL+Server"

# TODO: Use a Managed Identity to access Database e.g. connection_string = f"Driver=" + driver + ";Server=" + azure_sql_server + ";PORT=" + azure_sql_port + ";Database=todo;Authentication=ActiveDirectoryMsi"

# Use local database if Azure SQL server is not configured
if not azure_sql_server:
    print('Azure SQL not configured, Using local SQLLite database')
    basedir = os.path.abspath(os.path.dirname(__file__))   # Get the directory of the this file
    print('Base directory:', basedir)
    todo_file = os.path.join(basedir, 'todo_list.txt')     # Create the path to the to-do list file using the directory
    app.config["SQLALCHEMY_DATABASE_URI"] = 'sqlite:///' + os.path.join(basedir, 'todos.db')
else:
    print('Using Azure SQL Server - ' + azure_sql_server)
    app.config["SQLALCHEMY_DATABASE_URI"] = connection_string

logger.info('Initializing App')
db.init_app(app)
logger.info('App Initialized')

@app.context_processor
def inject_common_variables():
    return inject_current_date()

logger.info('Initializing Database')
with app.app_context():
    db.create_all()
logger.info('Database Initialized')

@app.before_request
def load_data_to_g():
    todos = Todo.query.all()
    g.todos = todos 
    g.todo = None
    g.TabEnum = Tab
    g.PriorityEnum = Priority
    g.selectedTab = Tab.NONE

@app.route("/")
def index():
    if not auth.get_user():
        return redirect(url_for("login"))
    return render_template("index.html", user=auth.get_user())  

@app.route("/add", methods=["POST"])
def add_todo():

    # Get the data from the form
    todo = Todo(
        name=request.form["todo"]
    )

    # Add the new ToDo to the list
    db.session.add(todo)
    db.session.commit()

    # Add the new ToDo to the list
    return redirect(url_for('index'))

# Details of ToDo Item
@app.route('/details/<int:id>', methods=['GET'])
def details(id):
    g.selectedTab = Tab.DETAILS
    g.todos = Todo.query.all()
    g.todo = Todo.query.filter_by(id=id).first()
    
    return render_template('index.html')

# Edit a new ToDo
@app.route('/edit/<int:id>', methods=['GET'])
def edit(id):
    g.selectedTab = Tab.EDIT
    g.todos = Todo.query.all()
    g.todo = Todo.query.filter_by(id=id).first()

    return render_template('index.html')

# Save existing To Do Item
@app.route('/update/<int:id>', methods=['POST'])
def update_todo(id):
    g.selectedTab = Tab.DETAILS

    if request.form.get('cancel') != None:
        return redirect(url_for('index'))

    # Get the data from the form
    name = request.form['name']
    due_date = request.form.get('duedate')
    notes=request.form.get('notes')
    priority=request.form.get('priority')
    completed=request.form.get('completed')

    todo = db.session.query(Todo).filter_by(id=id).first()
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
    g.selectedTab = Tab.NONE
    db.session.delete(Todo.query.filter_by(id=id).first())
    db.session.commit()
    return redirect(url_for('index'))

# Show AI recommendations
@app.route('/recommend/<int:id>', methods=['GET'])
@app.route('/recommend/<int:id>/<refresh>', methods=['GET'])
async def recommend(id, refresh=False):
    g.selectedTab = Tab.RECOMMENDATIONS
    recommendation_engine = RecommendationEngine()
    g.todo = db.session.query(Todo).filter_by(id=id).first()

    if g.todo and not refresh:
        try:
            #attempt to load any saved recommendation from the DB
            if g.todo.recommendations_json is not None:
                g.todo.recommendations = json.loads(g.todo.recommendations_json)
                return render_template('index.html')
        except ValueError as e:
            print("Error:", e)

    previous_links_str = None
    if refresh:
        g.todo.recommendations = json.loads(g.todo.recommendations_json)
        # Extract links
        links = [item["link"] for item in g.todo.recommendations]
        # Convert list of links to a single string
        previous_links_str = ", ".join(links)

    g.todo.recommendations = await recommendation_engine.get_recommendations(g.todo.name, previous_links_str)
    
    # Save the recommendations to the database
    try:
        g.todo.recommendations_json = json.dumps(g.todo.recommendations)
        db.session.add(g.todo)
        db.session.commit()
    except Exception as e:
        print(f"Error adding and committing todo: {e}")
        return

    return render_template('index.html')

@app.route('/completed/<int:id>/<complete>', methods=['GET'])
def completed(id, complete):
    g.selectedTab = Tab.NONE
    g.todo = Todo.query.filter_by(id=id).first()
    if (g.todo != None and complete == "true"):
        g.todo.completed = True
    elif (g.todo != None and complete == "false"):
        g.todo.completed = False
    #
    db.session.add(g.todo)
    db.session.commit()
    #
    return redirect(url_for('index'))

@app.route("/login")
def login():
    return render_template("login.html", **auth.log_in(
        scopes=["User.Read"], # Have user consent to scopes during log-in
        redirect_uri=url_for("auth_response", _external=True), # Optional. If present, this absolute URL must match your app's redirect_uri registered in Azure Portal
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
    return redirect(auth.log_out(url_for("index", _external=True)))

if __name__ == "__main__":
    #app.run(host="0.0.0.0",port=80,debug=False)
    app.run(host="localhost",port=5000,debug=True)