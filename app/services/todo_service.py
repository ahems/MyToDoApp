"""Service layer for todo business logic."""
from typing import Optional, List, Dict, Any
from services.api_client import GraphQLClient
from utils import (
    validate_todo_name,
    validate_priority,
    validate_due_date,
    validate_notes,
    validate_todo_id,
    sanitize_string,
)
from logging import getLogger

logger = getLogger(__name__)


class TodoService:
    """Service for managing todo operations."""
    
    def __init__(self, api_client: GraphQLClient):
        """Initialize the todo service.
        
        Args:
            api_client: GraphQL client instance
        """
        self.api_client = api_client
    
    def get_all_todos(self, oid: str) -> List[Dict[str, Any]]:
        """Get all todos for a user.
        
        Args:
            oid: User's object ID
            
        Returns:
            List of todo dictionaries
        """
        return self.api_client.get_todos_by_oid(oid)
    
    def get_todo(self, todo_id: int) -> Optional[Dict[str, Any]]:
        """Get a single todo by ID.
        
        Args:
            todo_id: The todo item ID
            
        Returns:
            Todo dictionary or None if not found
        """
        # Validate ID
        is_valid, validated_id, error_msg = validate_todo_id(todo_id)
        if not is_valid:
            logger.warning("[TodoService] Invalid todo ID: %s", error_msg)
            return None
        
        try:
            return self.api_client.get_todo_by_id(validated_id)
        except RuntimeError as e:
            logger.error("[TodoService] Failed to fetch todo %d: %s", validated_id, e)
            return None
    
    def create_todo(self, name: str, oid: str) -> Optional[Dict[str, Any]]:
        """Create a new todo item.
        
        Args:
            name: Todo name
            oid: User's object ID
            
        Returns:
            Created todo dictionary or None if creation fails
        """
        # Validate input
        is_valid, error_msg = validate_todo_name(name)
        if not is_valid:
            logger.warning("[TodoService] Validation failed: %s", error_msg)
            return None
        
        # Sanitize input
        sanitized_name = sanitize_string(name, max_length=200)
        
        return self.api_client.create_todo(sanitized_name, oid)
    
    def update_todo(
        self,
        todo_id: int,
        name: Optional[str] = None,
        due_date: Optional[str] = None,
        notes: Optional[str] = None,
        priority: Optional[str] = None,
        completed: Optional[bool] = None,
        recommendations_json: Optional[str] = None
    ) -> Optional[Dict[str, Any]]:
        """Update an existing todo item.
        
        Args:
            todo_id: The todo item ID
            name: Optional new name
            due_date: Optional new due date
            notes: Optional new notes
            priority: Optional new priority (as string)
            completed: Optional completion status
            recommendations_json: Optional recommendations JSON string
            
        Returns:
            Updated todo dictionary or None if update fails
        """
        # Validate todo ID
        is_valid, validated_id, error_msg = validate_todo_id(todo_id)
        if not is_valid:
            logger.warning("[TodoService] Invalid todo ID: %s", error_msg)
            return None
        
        # Validate and sanitize inputs
        validated_name = None
        if name is not None:
            is_valid, error_msg = validate_todo_name(name)
            if not is_valid:
                logger.warning("[TodoService] Name validation failed: %s", error_msg)
                return None
            validated_name = sanitize_string(name, max_length=200)
        
        validated_due_date = None
        if due_date is not None:
            is_valid, normalized_date, error_msg = validate_due_date(due_date)
            if not is_valid:
                logger.warning("[TodoService] Due date validation failed: %s", error_msg)
                return None
            validated_due_date = normalized_date
        
        validated_notes = None
        if notes is not None:
            is_valid, sanitized_notes, error_msg = validate_notes(notes)
            if not is_valid:
                logger.warning("[TodoService] Notes validation failed: %s", error_msg)
                return None
            validated_notes = sanitized_notes
        
        validated_priority = None
        if priority is not None:
            is_valid, priority_int, error_msg = validate_priority(priority)
            if not is_valid:
                logger.warning("[TodoService] Priority validation failed: %s", error_msg)
                return None
            validated_priority = priority_int
        
        return self.api_client.update_todo(
            todo_id=validated_id,
            name=validated_name,
            due_date=validated_due_date,
            notes=validated_notes,
            priority=validated_priority,
            completed=completed,
            recommendations_json=recommendations_json
        )
    
    def delete_todo(self, todo_id: int) -> bool:
        """Delete a todo item.
        
        Args:
            todo_id: The todo item ID
            
        Returns:
            True if deletion succeeded, False otherwise
        """
        # Validate ID
        is_valid, validated_id, error_msg = validate_todo_id(todo_id)
        if not is_valid:
            logger.warning("[TodoService] Invalid todo ID: %s", error_msg)
            return False
        
        return self.api_client.delete_todo(validated_id)
    
    def toggle_completion(self, todo_id: int, completed: bool) -> Optional[Dict[str, Any]]:
        """Toggle the completion status of a todo.
        
        Args:
            todo_id: The todo item ID
            completed: New completion status
            
        Returns:
            Updated todo dictionary or None if update fails
        """
        return self.update_todo(todo_id, completed=completed)
