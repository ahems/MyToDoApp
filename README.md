# Deploying the ToDo App To Azure

## Deployment from Visual Studio Code using Code Spaces

The easiest way to get started is to use GitHub CodeSpaces as all the tools are installed for you. Steps:

1. Click this button: [![Open in GitHub Codespaces](https://img.shields.io/static/v1?style=for-the-badge&label=GitHub+Codespaces&message=Open&color=brightgreen&logo=github)](https://github.com/codespaces/new?hide_repo_select=true&repo=916191305&machine=standardLinux32gb&devcontainer_path=.devcontainer%2Fdevcontainer.json&location=WestUs2). This will launch the repo is VS Code in a Browser.

2. Next, we reccommend you launch the CodeSpace in *Visual Studio Code Dev Containers* as the Login from the command line to Azure using 2-factor Credentials often fails from a CodeSpace running in a Browser. To do this, left-click the name of the Codespace in the bottom-left of the screen and then select "Open in VS Code Desktop" as shown here:

    ![VS Code Dev Containers](images/OpenInCodeSpaces.png)

   *Note:* If you don't see the name of the CodeSpace in the bottom right, *right*-Click the status bar and ensure 'Remote Host' is checked.

3. Once the project files show up in your desktop deployment of Visual Studio Code (this may take several minutes), use the terminal window to follow the steps below to deploy the infrasructure. To easily view the instructions, select README.md, right-click and select "Open Preview" which will make it easier to read.

### Configure Environment

Use the terminal in Visual Studio Code to do these steps. From the top menu, select "Terminal" and then "New Terminal" in order to create one if one doesn't already appear. Then in this, Terminal, follow these steps:

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

   ```shell
   azd env set AZURE_SUBSCRIPTION_ID <your Subscription ID>
   ```

   Lastly you can also set AZURE_LOCATION which is the Azure region you want everything deployed it, which uses 'eastus2' as the default if this value is not set.

   ```shell
   azd env set AZURE_LOCATION westus
   ```   

3. Provision Infrastructure

   This is initiated with one command like so:

   ```shell
   azd up
   ```

   You will be prompted to login to Azure the first time you run this command; select "Y" in order to so so. A web browser will pop up and you will select the account you wish to use. Please note if this fails, make sure you have followed Step at the top of the page to launch the CodeSpace in *Visual Studio Code Dev Containers*.

   You may be asked to log in a second time using https://microsoft.com/devicelogin and entering a code (provided). Do so, if asked. You may also be asked "Are you trying to sign in to Microsoft Azure PowerShell?" - select Yes if so in order to run the automated scripts of this deployment.

4. De-Provision Infrastructure

   To remove everything created in the step above, run one command like so:

   ```shell
   azd down --force --purge
   ```