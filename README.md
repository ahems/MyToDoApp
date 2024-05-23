# MyToDoApp

Deploy image:

az container create --resource-group myResourceGroup --name aci-tutorial-app --image todoappacrrxtwbls4xlfno//mytodoapp:latest --cpu 1 --memory 1 --registry-login-server todoappacrrxtwbls4xlfno.azurecr.io --registry-username todoappacrrxtwbls4xlfno
--registry-password $REGISTRY_PASSWORD --ip-address Public --dns-name-label myaitodoapp --ports 80