#!/bin/bash

# API Testing Script for Azure AD Authentication

echo "🔧 Loading environment variables from azd..."

# Load environment variables from azd
if command -v azd &> /dev/null; then
    eval "$(azd env get-values)"
    echo "✅ Environment variables loaded from azd"
else
    echo "❌ azd not found. Please install Azure Developer CLI."
    exit 1
fi

# Configuration from environment variables
API_URL="https://todoapp-api-gnr77wqlqmrgm.victoriousisland-e8a25bae.westus.azurecontainerapps.io"

echo ""
echo "🔐 Testing API Authentication"
echo "API URL: $API_URL"
echo "API App ID URI: $API_APP_ID_URI"
echo "Subscription ID: $AZURE_SUBSCRIPTION_ID"
echo "Tenant ID: $TENANT_ID"
echo ""

# Check if user is already logged in and in the correct tenant/subscription
echo "🔍 Checking current Azure login status..."
CURRENT_ACCOUNT=$(az account show --query "{tenantId:tenantId, subscriptionId:id}" -o json 2>/dev/null)

if [ $? -eq 0 ]; then
    CURRENT_TENANT=$(echo "$CURRENT_ACCOUNT" | jq -r '.tenantId')
    CURRENT_SUBSCRIPTION=$(echo "$CURRENT_ACCOUNT" | jq -r '.subscriptionId')
    
    echo "✅ Already logged into Azure"
    echo "Current tenant: $CURRENT_TENANT"
    echo "Current subscription: $CURRENT_SUBSCRIPTION"
    
    if [ "$CURRENT_TENANT" != "$TENANT_ID" ]; then
        echo "⚠️  Wrong tenant! Expected: $TENANT_ID"
        echo "Please login to the correct tenant:"
        echo "   az login --tenant '$TENANT_ID'"
        exit 1
    fi
    
    if [ "$CURRENT_SUBSCRIPTION" != "$AZURE_SUBSCRIPTION_ID" ]; then
        echo "⚠️  Wrong subscription! Expected: $AZURE_SUBSCRIPTION_ID"
        echo "Setting correct subscription..."
        az account set --subscription "$AZURE_SUBSCRIPTION_ID" || {
            echo "❌ Failed to set subscription"
            exit 1
        }
        echo "✅ Subscription set successfully"
    fi
else
    echo "❌ Not logged into Azure. Please login first:"
    echo "   az login --tenant '$TENANT_ID'"
    echo "   az account set --subscription '$AZURE_SUBSCRIPTION_ID'"
    exit 1
fi

echo ""
echo "🎫 Checking if Azure CLI has consent for API access..."

# The Azure CLI may not have permission to access custom API registrations
# Let's try the CLIENT_ID instead of the API_APP_ID_URI
echo "⚠️  Note: Azure CLI may not have permission to access custom API registrations."
echo "This is a common limitation. Let's try alternative approaches..."
echo ""

# Try using the CLIENT_ID directly instead of the API_APP_ID_URI
echo "🔄 Attempting to get token using CLIENT_ID instead..."
TOKEN_RESULT=$(az account get-access-token --resource "$CLIENT_ID" --query accessToken -o tsv 2>&1)
TOKEN_EXIT_CODE=$?

if [ $TOKEN_EXIT_CODE -eq 0 ] && [ -n "$TOKEN_RESULT" ] && [ "$TOKEN_RESULT" != "null" ]; then
    TOKEN="$TOKEN_RESULT"
    echo "✅ Token acquired successfully using CLIENT_ID"
    echo "Token (first 20 chars): ${TOKEN:0:20}..."
    echo ""
else
    echo "❌ Failed to get token using CLIENT_ID as well"
    echo "Error: $TOKEN_RESULT"
    echo ""
    echo "🔧 The issue is that Azure CLI doesn't have permission to access your custom API."
    echo "This requires admin consent or a different authentication approach."
    echo ""
    echo "📋 Solutions:"
    echo "1. Use a different tool like Postman with OAuth 2.0 flow"
    echo "2. Create a simple client app that can authenticate"
    echo "3. Grant Azure CLI permission in the API app registration (requires admin)"
    echo ""
    echo "🌐 For testing with Postman:"
    echo "- Auth URL: https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/authorize"
    echo "- Token URL: https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token"
    echo "- Client ID: $CLIENT_ID"
    echo "- Scope: $API_APP_ID_URI/.default"
    echo ""
    echo "📱 Alternative - Test without authentication (should return 403 Forbidden):"
    curl -s -w "HTTP Status: %{http_code}\n" "$API_URL/api/todo" -o /dev/null
    echo ""
    exit 1
fi
    
    # Test authenticated requests
    echo "📊 Test 1: Authenticated GET request to /api/todo"
    curl -s -H "Authorization: Bearer $TOKEN" \
         -H "Accept: application/json" \
         -w "HTTP Status: %{http_code}\n" \
         "$API_URL/api/todo"
    echo ""
    
    echo "📊 Test 2: GraphQL introspection query"
    curl -s -H "Authorization: Bearer $TOKEN" \
         -H "Content-Type: application/json" \
         -H "Accept: application/json" \
         -w "HTTP Status: %{http_code}\n" \
         -d '{"query": "{ __schema { types { name } } }"}' \
         "$API_URL/graphql"
    echo ""
    
    echo "📊 Test 3: GraphQL todo query"
    curl -s -H "Authorization: Bearer $TOKEN" \
         -H "Content-Type: application/json" \
         -H "Accept: application/json" \
         -d '{"query": "{ todos { id title completed } }"}' \
         "$API_URL/graphql" | jq . 2>/dev/null || cat
    echo ""
    
else
    echo "❌ Failed to get access token"
    echo "Exit code: $TOKEN_EXIT_CODE"
    echo "Error output: $TOKEN_RESULT"
    echo ""
    echo "This might be because:"
    echo "1. The API app registration doesn't exist or isn't accessible"
    echo "2. Your account doesn't have permission to access this resource"
    echo "3. The App ID URI format is incorrect"
    echo ""
    echo "Let's try some diagnostic steps:"
    echo ""
    
    # Try to get a token for a standard resource to verify basic token acquisition works
    echo "🔍 Testing token acquisition for Azure Resource Manager (standard test)..."
    ARM_TOKEN=$(az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv 2>/dev/null)
    if [ -n "$ARM_TOKEN" ] && [ "$ARM_TOKEN" != "null" ]; then
        echo "✅ Can get ARM token - Azure CLI authentication is working"
    else
        echo "❌ Can't get ARM token - Azure CLI authentication problem"
    fi
    echo ""
    
    echo "Manual steps to debug:"
    echo "1. Verify you're logged in: az account show"
    echo "2. Check app registration exists: az ad app list --filter \"appId eq '$CLIENT_ID'\" --query '[].{appId:appId, displayName:displayName}'"
    echo "3. Try different token scope: az account get-access-token --scope '$API_APP_ID_URI/.default'"
    echo "4. Manual token command: TOKEN=\$(az account get-access-token --resource '$API_APP_ID_URI' --query accessToken -o tsv)"
fi

echo ""
echo "🔧 Manual Testing Commands:"
echo ""
echo "Since Azure CLI cannot directly access custom API registrations without additional setup,"
echo "here are alternative approaches:"
echo ""
echo "🌐 Option 1: Use Postman or similar OAuth 2.0 client:"
echo "- Auth URL: https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/authorize"
echo "- Token URL: https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token"
echo "- Client ID: $CLIENT_ID"
echo "- Scope: $API_APP_ID_URI/.default"
echo "- Redirect URI: https://oauth.pstmn.io/v1/callback (for Postman)"
echo ""
echo "🔧 Option 2: Grant Azure CLI permission to your API (requires Azure admin):"
echo "1. Go to Azure Portal > App Registrations > [Your API App]"
echo "2. Go to 'Expose an API' > 'Authorized client applications'"
echo "3. Add client application ID: 04b07795-8ddb-461a-bbee-02f9e1bf7b46"
echo "4. Select the scope you want to authorize"
echo "5. Then retry: az account get-access-token --resource '$API_APP_ID_URI'"
echo ""
echo "📱 Option 3: Test API availability (should return 403 Forbidden):"
echo "curl -v '$API_URL/api/todo'"
echo ""
echo "🔍 Option 4: Use a custom client application or msal-based script"