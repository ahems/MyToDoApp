curl https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add -
sudo add-apt-repository "$(curl https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/prod.list)"
sudo apt-get update
sudo apt-get install mssql-tools unixodbc-dev -y
echo 'export PATH="$PATH:/opt/mssql-tools/bin"' >> ~/.bashrc
source ~/.bashrc

sqlcmd -S <YourSqlServer> -d <YourDatabaseName> -G ^
-Q "CREATE USER [todoapp-identity-xyjya2a3yrfuw] FROM EXTERNAL PROVIDER;
    ALTER ROLE db_datareader ADD MEMBER [todoapp-identity-xyjya2a3yrfuw];
    ALTER ROLE db_datawriter ADD MEMBER [todoapp-identity-xyjya2a3yrfuw];
    ALTER ROLE db_ddladmin ADD MEMBER [todoapp-identity-xyjya2a3yrfuw];"