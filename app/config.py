"""Configuration management for the ToDo application."""
import os
from typing import Optional
from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.core.credentials import TokenCredential


class Config:
    """Application configuration loaded from environment variables and Azure Key Vault."""
    
    # Azure Configuration
    KEY_VAULT_NAME: Optional[str] = os.environ.get("KEY_VAULT_NAME")
    AZURE_CLIENT_ID: Optional[str] = os.environ.get("AZURE_CLIENT_ID")
    IS_LOCALHOST: bool = os.environ.get("IS_LOCALHOST", "false").lower() == "true"
    
    # API Configuration
    API_URL: str = os.environ.get("API_URL", "")
    API_APP_ID_URI: str = os.environ.get("API_APP_ID_URI", "")
    API_APP_SCOPE: str = ""
    
    # Redis Configuration
    REDIS_CONNECTION_STRING: Optional[str] = os.environ.get("REDIS_CONNECTION_STRING")
    REDIS_LOCAL_PRINCIPAL_ID: Optional[str] = os.environ.get("REDIS_LOCAL_PRINCIPAL_ID")
    
    # Application Insights
    APPLICATIONINSIGHTS_CONNECTION_STRING: str = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING", "")
    
    # Redirect URI
    REDIRECT_URI: Optional[str] = os.environ.get("REDIRECT_URI")
    
    # Flask Configuration
    SECRET_KEY: Optional[str] = os.environ.get("SECRET_KEY") or os.environ.get("FLASK_SECRET_KEY")
    DEBUG: bool = False
    
    # API Request Configuration
    API_REQUEST_TIMEOUT: int = 30
    API_MAX_RETRIES: int = 3
    
    # Recommendation Engine Configuration
    RECOMMENDATION_MAX_RETRIES: int = 3
    RECOMMENDATION_RETRY_DELAY: float = 1.0
    RECOMMENDATION_TIMEOUT: float = 30.0
    
    # Input Validation Limits
    TODO_NAME_MAX_LENGTH: int = 200
    NOTES_MAX_LENGTH: int = 2000
    KEYWORD_PHRASE_MAX_LENGTH: int = 500
    
    def __init__(self):
        """Initialize configuration and validate required settings."""
        # Validate required environment variables
        if not self.API_APP_ID_URI:
            raise ValueError("API_APP_ID_URI environment variable is not set.")
        
        if not self.APPLICATIONINSIGHTS_CONNECTION_STRING:
            raise ValueError("APPLICATIONINSIGHTS_CONNECTION_STRING environment variable is not set.")
        
        if not self.API_URL:
            raise ValueError("API_URL environment variable is not set.")
        
        # Set API scope
        self.API_APP_SCOPE = f"{self.API_APP_ID_URI.rstrip('/')}/.default"
        
        # Set debug mode based on environment
        self.DEBUG = self.IS_LOCALHOST
    
    @property
    def managed_identity_credential(self) -> TokenCredential:
        """Get the appropriate Azure credential based on environment.
        
        Returns:
            TokenCredential instance (DefaultAzureCredential for local, ManagedIdentityCredential for cloud)
        """
        if self.IS_LOCALHOST:
            return DefaultAzureCredential()
        else:
            if self.AZURE_CLIENT_ID:
                return ManagedIdentityCredential(client_id=self.AZURE_CLIENT_ID)
            else:
                return ManagedIdentityCredential()
    
    def get_key_vault_secret(self, secret_name: str, credential: Optional[TokenCredential] = None) -> Optional[str]:
        """Get a secret from Azure Key Vault.
        
        Args:
            secret_name: Name of the secret to retrieve
            credential: Optional credential to use (defaults to managed_identity_credential)
            
        Returns:
            Secret value or None if not found
        """
        if not self.KEY_VAULT_NAME:
            return None
        
        try:
            from azure.keyvault.secrets import SecretClient
            
            if credential is None:
                credential = self.managed_identity_credential
            
            key_vault_uri = f"https://{self.KEY_VAULT_NAME}.vault.azure.net"
            client = SecretClient(vault_url=key_vault_uri, credential=credential)
            secret = client.get_secret(secret_name)
            return secret.value
        except Exception as e:
            print(f"[Config] Failed to get secret '{secret_name}' from Key Vault: {e}")
            return None
