"""GraphQL API client for interacting with the Data API Builder backend."""
import json
import requests
from typing import Dict, Any, Optional, List
from logging import getLogger

logger = getLogger(__name__)


class GraphQLClient:
    """Client for making GraphQL requests to the Data API Builder API."""
    
    def __init__(self, api_url: str, get_token_func, timeout: int = 30):
        """Initialize the GraphQL client.
        
        Args:
            api_url: The GraphQL API endpoint URL
            get_token_func: Function that returns an access token
            timeout: Request timeout in seconds
        """
        self.api_url = api_url
        self.get_token = get_token_func
        self.timeout = timeout
    
    def _get_headers(self) -> Dict[str, str]:
        """Get request headers with authentication.
        
        Returns:
            Dictionary of HTTP headers
        """
        return {
            'Content-Type': 'application/json',
            'Authorization': f"Bearer {self.get_token()}"
        }
    
    def execute_query(self, query: str, variables: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Execute a GraphQL query.
        
        Args:
            query: GraphQL query string
            variables: Optional query variables
            
        Returns:
            Response data dictionary
            
        Raises:
            RuntimeError: If the request fails
        """
        payload = {"query": query}
        if variables:
            payload["variables"] = variables
        
        try:
            response = requests.post(
                self.api_url,
                json=payload,
                headers=self._get_headers(),
                timeout=self.timeout
            )
            
            if response.status_code != 200:
                try:
                    error_data = response.json()
                    error_message = error_data.get('errors', [{'message': 'Unknown error'}])[0]['message']
                except (ValueError, KeyError, IndexError):
                    error_message = f"API error (status {response.status_code}): {response.text[:200]}"
                logger.error("[GraphQLClient] Query failed: %s", error_message)
                raise RuntimeError(f"GraphQL query failed: {error_message}")
            
            try:
                return response.json()
            except ValueError:
                logger.error("[GraphQLClient] Invalid JSON response")
                raise RuntimeError("Invalid JSON response from API")
                
        except requests.RequestException as e:
            logger.error("[GraphQLClient] Request exception: %s", e)
            raise RuntimeError(f"API request failed: {str(e)}")
    
    def get_todos_by_oid(self, oid: str) -> List[Dict[str, Any]]:
        """Get all todos for a user by OID.
        
        Args:
            oid: User's object ID
            
        Returns:
            List of todo dictionaries
        """
        query = """
        {
            todos(filter: { oid: { eq: "%s" } }) {
                items {
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
        }
        """ % oid
        
        try:
            response = self.execute_query(query)
            data = response.get("data", {})
            todos_root = data.get("todos", {})
            items = todos_root.get("items", [])
            return items if items is not None else []
        except Exception as e:
            logger.error("[GraphQLClient] Failed to get todos for OID %s: %s", oid, e)
            return []
    
    def get_todo_by_id(self, todo_id: int) -> Optional[Dict[str, Any]]:
        """Get a single todo by ID.
        
        Args:
            todo_id: The todo item ID
            
        Returns:
            Todo dictionary or None if not found
            
        Raises:
            RuntimeError: If the request fails
        """
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
        variables = {"id": todo_id}
        
        response = self.execute_query(query, variables)
        todo = response.get('data', {}).get('todo_by_pk')
        return todo
    
    def create_todo(self, name: str, oid: str) -> Optional[Dict[str, Any]]:
        """Create a new todo item.
        
        Args:
            name: Todo name
            oid: User's object ID
            
        Returns:
            Created todo dictionary or None if creation fails
        """
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
        variables = {
            "name": name,
            "oid": oid
        }
        
        try:
            response = self.execute_query(mutation, variables)
            return response.get("data", {}).get("createtodo")
        except Exception as e:
            logger.error("[GraphQLClient] Failed to create todo: %s", e)
            return None
    
    def update_todo(
        self,
        todo_id: int,
        name: Optional[str] = None,
        due_date: Optional[str] = None,
        notes: Optional[str] = None,
        priority: Optional[int] = None,
        completed: Optional[bool] = None,
        recommendations_json: Optional[str] = None
    ) -> Optional[Dict[str, Any]]:
        """Update an existing todo item.
        
        Args:
            todo_id: The todo item ID
            name: Optional new name
            due_date: Optional new due date
            notes: Optional new notes
            priority: Optional new priority
            completed: Optional completion status
            recommendations_json: Optional recommendations JSON string
            
        Returns:
            Updated todo dictionary or None if update fails
        """
        # Build the item object with only provided fields
        item_fields = []
        if name is not None:
            item_fields.append(f'name: $name')
        if due_date is not None:
            item_fields.append(f'due_date: $due_date')
        if notes is not None:
            item_fields.append(f'notes: $notes')
        if priority is not None:
            item_fields.append(f'priority: $priority')
        if completed is not None:
            item_fields.append(f'completed: $completed')
        if recommendations_json is not None:
            item_fields.append(f'recommendations_json: $recommendations_json')
        
        item_str = ", ".join(item_fields)
        
        mutation = f"""
        mutation UpdateTodo($id: Int!, $name: String, $due_date: String, $notes: String, $priority: Int, $completed: Boolean, $recommendations_json: String) {{
            updatetodo(id: $id, item: {{
                {item_str}
            }}) {{
                id
                name
                due_date
                notes
                priority
                completed
                recommendations_json
            }}
        }}
        """
        
        variables = {"id": todo_id}
        if name is not None:
            variables["name"] = name
        if due_date is not None:
            variables["due_date"] = due_date
        if notes is not None:
            variables["notes"] = notes
        if priority is not None:
            variables["priority"] = priority
        if completed is not None:
            variables["completed"] = completed
        if recommendations_json is not None:
            variables["recommendations_json"] = recommendations_json
        
        try:
            response = self.execute_query(mutation, variables)
            return response.get("data", {}).get("updatetodo")
        except Exception as e:
            logger.error("[GraphQLClient] Failed to update todo %d: %s", todo_id, e)
            return None
    
    def delete_todo(self, todo_id: int) -> bool:
        """Delete a todo item.
        
        Args:
            todo_id: The todo item ID
            
        Returns:
            True if deletion succeeded, False otherwise
        """
        mutation = """
        mutation RemoveTodo($id: Int!) {
            deletetodo(id: $id) {
                id
            }
        }
        """
        variables = {"id": todo_id}
        
        try:
            response = self.execute_query(mutation, variables)
            return response.get("data", {}).get("deletetodo") is not None
        except Exception as e:
            logger.error("[GraphQLClient] Failed to delete todo %d: %s", todo_id, e)
            return False
