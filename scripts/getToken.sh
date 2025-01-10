curl -X POST https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token \
-H "Content-Type: application/x-www-form-urlencoded" \
-d "client_id={application_client_id}" \
-d "scope=api://{api_application_client_id}/.default" \
-d "grant_type=client_credentials" \
-d "client_secret={client_secret}" | jq -r '.access_token' > access_token.txt