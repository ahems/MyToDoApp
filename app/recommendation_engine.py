import os
import json
import time
import asyncio
from services import Service
from openai import AzureOpenAI
from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.keyvault.secrets import SecretClient
from typing import Optional

class RecommendationEngine:
    """Recommendation engine that uses Entra ID (Azure AD) auth for Azure AI Foundry.

    Local debugging (IS_LOCALHOST=true):
        - Uses DefaultAzureCredential excluding managed identity, obtaining a user token.
    In Container App (managed identity present):
        - Uses ManagedIdentityCredential (user-assigned when AZURE_CLIENT_ID set, else system-assigned).
    """

    _AOAI_SCOPE = "https://cognitiveservices.azure.com/.default"

    def __init__(self):
        self._is_local = os.environ.get("IS_LOCALHOST", "false").lower() == "true"
        self._key_vault_name = os.environ.get("KEY_VAULT_NAME")
        self._user_mi_client_id = os.environ.get("AZURE_CLIENT_ID")  # user-assigned MI client id (in container)

        # Resolve deployment & endpoint (may come from Key Vault or environment)
        self.deployment: str = ""
        self._endpoint: str = ""
        self._token_value: Optional[str] = None
        self._token_expires: float = 0.0

        # Choose credential strategy
        if self._is_local:
            print("[RecommendationEngine] Local debug mode: using DefaultAzureCredential (exclude managed identity)")
            self._credential = DefaultAzureCredential(exclude_managed_identity_credential=True)
        else:
            if self._user_mi_client_id:
                print("[RecommendationEngine] Container mode: using User Assigned Managed Identity")
                self._credential = ManagedIdentityCredential(client_id=self._user_mi_client_id)
            else:
                print("[RecommendationEngine] Container mode: using System Assigned Managed Identity")
                self._credential = ManagedIdentityCredential()

        # Attempt to pull secrets from Key Vault when managed identity (user-assigned or system) is available
        # or when local user has access to the vault.
        if self._key_vault_name:
            try:
                kv_uri = f"https://{self._key_vault_name}.vault.azure.net"
                kv_client = SecretClient(vault_url=kv_uri, credential=self._credential)
                # These secrets should exist if bootstrap script populated them.
                if not self.deployment:
                    try:
                        self.deployment = kv_client.get_secret("AZUREOPENAIDEPLOYMENTNAME").value or ""
                    except Exception:
                        self.deployment = self.deployment or ""
                if not self._endpoint:
                    try:
                        self._endpoint = kv_client.get_secret("AZUREOPENAIENDPOINT").value or ""
                    except Exception:
                        self._endpoint = self._endpoint or ""
            except Exception as e:
                print(f"[RecommendationEngine] Warning: Key Vault access failed ({type(e).__name__}: {e}); will rely on environment vars.")

        # Environment fallback values
        if not self.deployment:
            self.deployment = os.environ.get("AZURE_OPENAI_DEPLOYMENT_NAME", "") or ""
        if not self._endpoint:
            self._endpoint = os.environ.get("AZURE_OPENAI_ENDPOINT", "") or ""

        if not self.deployment or not self._endpoint:
            raise ValueError("Azure AI Foundry deployment name or endpoint is missing. Ensure environment variables are set.")

        # Try to obtain Azure AD token
        token_ok = self._refresh_token_if_needed(force=True)
        if token_ok:
            print("[RecommendationEngine] Using Entra ID token authentication for Azure AI Foundry.")
            self.client = AzureOpenAI(
                azure_endpoint=self._endpoint,
                api_version="2024-02-15-preview",
                azure_ad_token=self._token_value,
            )
        else:
            raise RuntimeError("Failed to obtain Azure AD token for OpenAI authentication.")


    # ------------------ Internal helpers ------------------
    def _refresh_token_if_needed(self, force: bool = False) -> bool:
        """Acquire or refresh the Entra ID token if close to expiry.
        Returns True if a valid token is present after call, else False.
        """
        if force or (not self._token_value) or (time.time() > self._token_expires - 120):
            try:
                token = self._credential.get_token(self._AOAI_SCOPE)
                self._token_value = token.token
                # expires_on exposed on azure.identity tokens
                self._token_expires = float(getattr(token, "expires_on", (time.time() + 600)))
                return True
            except Exception as e:
                print(f"[RecommendationEngine] Token acquisition failed: {type(e).__name__}: {e}")
                self._token_value = None
                return False
        return True

    def _ensure_token_client(self):
        """If we are in token mode and token refreshed, update client (library lacks auto-refresh)."""
        if self._token_value and hasattr(self.client, "azure_ad_token"):
            # Recreate client if token nearing expiry to ensure new requests use fresh token.
            if time.time() > self._token_expires - 120:
                if self._refresh_token_if_needed(force=True):
                    self.client = AzureOpenAI(
                        azure_endpoint=self._endpoint,
                        api_version="2024-02-15-preview",
                        azure_ad_token=self._token_value,
                    )

    async def get_recommendations(self, keyword_phrase: str, previous_links_str: Optional[str] = None) -> list:
        """Get AI recommendations for a keyword phrase.
        
        Args:
            keyword_phrase: The keyword or phrase to get recommendations for
            previous_links_str: Optional string of previous links to exclude
            
        Returns:
            List of recommendation dictionaries with 'title' and 'link' keys
        """
        # Validate input
        if not keyword_phrase or not isinstance(keyword_phrase, str):
            print("[RecommendationEngine] Invalid keyword_phrase provided")
            return [{"title": "Invalid input provided", "link": ""}]
        
        # Sanitize keyword phrase
        keyword_phrase = keyword_phrase.strip()[:500]  # Limit length
        
        max_retries = 3
        retry_delay = 1.0
        
        for attempt in range(max_retries):
            try:
                # Refresh token if in token auth mode
                if self._token_value:
                    self._ensure_token_client()
                
                prompt = f"""Please return 5 recommendations based on the input string: '{keyword_phrase}' using correct JSON syntax that contains a title and a hyperlink back to the supporting website. RETURN ONLY JSON AND NOTHING ELSE"""
                system_prompt = """You are an administrative assistant bot who is good at giving 
                recommendations for tasks that need to be done by referencing website links that can provide 
                assistance to helping complete the task. 

                If there are not any recommendations simply return an empty collection. 

                EXPECTED OUTPUT:
                Provide your response as a JSON object with the following schema:
                [{"title": "...", "link": "..."},
                {"title": "...", "link": "..."},
                {"title": "...", "link": "..."}]
                """
                
                if previous_links_str is not None:
                    prompt = prompt + f". EXCLUDE the following links from your recommendations: {previous_links_str}"  

                message_text = [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": prompt},
                ]

                # Make API call with timeout
                try:
                    response = self.client.chat.completions.create(
                        model=self.deployment,
                        messages=message_text,
                        temperature=0.14,
                        max_tokens=800,
                        top_p=0.17,
                        frequency_penalty=0,
                        presence_penalty=0,
                        stop=None,
                        timeout=30.0,  # 30 second timeout
                    )
                except Exception as api_error:
                    print(f"[RecommendationEngine] API call failed (attempt {attempt + 1}/{max_retries}): {type(api_error).__name__}: {api_error}")
                    if attempt < max_retries - 1:
                        await asyncio.sleep(retry_delay * (attempt + 1))  # Exponential backoff
                        continue
                    else:
                        return [{"title": "Sorry, unable to generate recommendations at this time. Please try again later.", "link": ""}]

                if not response or not response.choices:
                    print("[RecommendationEngine] Empty response from API")
                    return [{"title": "No recommendations available", "link": ""}]

                result = response.choices[0].message.content if response.choices[0].message else None
                
                if not result:
                    print("[RecommendationEngine] No content in API response")
                    return [{"title": "No recommendations available", "link": ""}]

                # Parse JSON response with better error handling
                try:
                    # Try to extract JSON from response if it's wrapped in text
                    result_str = result.strip()
                    # Remove markdown code blocks if present
                    if result_str.startswith("```"):
                        # Extract JSON from code block
                        lines = result_str.split("\n")
                        result_str = "\n".join([line for line in lines if not line.strip().startswith("```")])
                    
                    recommendation = json.loads(result_str) if isinstance(result_str, str) else []
                    
                    # Validate recommendation structure
                    if not isinstance(recommendation, list):
                        print(f"[RecommendationEngine] Invalid recommendation format: expected list, got {type(recommendation)}")
                        return [{"title": "Invalid response format", "link": ""}]
                    
                    # Validate each recommendation has required fields
                    validated_recommendations = []
                    for rec in recommendation:
                        if isinstance(rec, dict) and "title" in rec and "link" in rec:
                            validated_recommendations.append({
                                "title": str(rec["title"])[:200],  # Limit title length
                                "link": str(rec["link"])[:500]     # Limit link length
                            })
                    
                    if not validated_recommendations:
                        return [{"title": "No valid recommendations found", "link": ""}]
                    
                    return validated_recommendations
                    
                except json.JSONDecodeError as json_error:
                    print(f"[RecommendationEngine] JSON decode error: {json_error}")
                    print(f"[RecommendationEngine] Raw response: {result[:500]}")
                    # Try to extract JSON-like content
                    if attempt < max_retries - 1:
                        await asyncio.sleep(retry_delay * (attempt + 1))
                        continue
                    return [{"title": "Sorry, unable to parse recommendations at this time", "link": ""}]
                except Exception as parse_error:
                    print(f"[RecommendationEngine] Parse error: {type(parse_error).__name__}: {parse_error}")
                    if attempt < max_retries - 1:
                        await asyncio.sleep(retry_delay * (attempt + 1))
                        continue
                    return [{"title": "Sorry, unable to process recommendations at this time", "link": ""}]
                    
            except Exception as e:
                print(f"[RecommendationEngine] Unexpected error (attempt {attempt + 1}/{max_retries}): {type(e).__name__}: {e}")
                if attempt < max_retries - 1:
                    await asyncio.sleep(retry_delay * (attempt + 1))
                    continue
                else:
                    return [{"title": "Sorry, unable to generate recommendations at this time. Please try again later.", "link": ""}]
        
        # Should not reach here, but return error message just in case
        return [{"title": "Sorry, unable to generate recommendations at this time", "link": ""}]

async def test_recommendation_engine():
    engine = RecommendationEngine()
    recommendations = await engine.get_recommendations("Buy a birthday gift for mom")
    count = 1
    for recommendation in recommendations:
        print(f"{count} - {recommendation['title']}: {recommendation['link']}")
        count += 1

if __name__ == "__main__":
    asyncio.run(test_recommendation_engine())