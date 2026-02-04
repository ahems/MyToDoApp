"""Utility functions for validation and sanitization."""
import re
from typing import Optional
from datetime import datetime


def sanitize_string(value: str, max_length: int = 500) -> str:
    """Sanitize a string input by stripping whitespace and limiting length.
    
    Args:
        value: The string to sanitize
        max_length: Maximum allowed length
        
    Returns:
        Sanitized string
    """
    if not isinstance(value, str):
        return ""
    # Strip whitespace and limit length
    sanitized = value.strip()[:max_length]
    # Remove any null bytes
    sanitized = sanitized.replace('\x00', '')
    return sanitized


def validate_todo_name(name: str) -> tuple[bool, Optional[str]]:
    """Validate a todo name.
    
    Args:
        name: The todo name to validate
        
    Returns:
        Tuple of (is_valid, error_message)
    """
    if not name or not isinstance(name, str):
        return False, "Todo name is required"
    
    sanitized = sanitize_string(name, max_length=200)
    if not sanitized:
        return False, "Todo name cannot be empty"
    
    if len(sanitized) < 1:
        return False, "Todo name must be at least 1 character"
    
    if len(sanitized) > 200:
        return False, "Todo name must be less than 200 characters"
    
    return True, None


def validate_priority(priority: Optional[str]) -> tuple[bool, Optional[int], Optional[str]]:
    """Validate and convert priority value.
    
    Args:
        priority: Priority string value
        
    Returns:
        Tuple of (is_valid, priority_int, error_message)
    """
    if priority is None or priority == "":
        return True, None, None
    
    try:
        priority_int = int(priority)
        if priority_int in [0, 1, 2, 3]:
            return True, priority_int, None
        else:
            return False, None, "Priority must be 0, 1, 2, or 3"
    except (ValueError, TypeError):
        return False, None, "Priority must be a valid integer"


def validate_due_date(due_date: Optional[str]) -> tuple[bool, Optional[str], Optional[str]]:
    """Validate a due date string.
    
    Args:
        due_date: Due date string in YYYY-MM-DD format
        
    Returns:
        Tuple of (is_valid, normalized_date, error_message)
    """
    if not due_date or due_date == "" or due_date == "None":
        return True, None, None
    
    try:
        # Try to parse the date
        parsed_date = datetime.strptime(due_date, "%Y-%m-%d")
        # Return in the same format
        return True, parsed_date.strftime("%Y-%m-%d"), None
    except ValueError:
        return False, None, "Due date must be in YYYY-MM-DD format"


def validate_notes(notes: Optional[str]) -> tuple[bool, Optional[str], Optional[str]]:
    """Validate and sanitize notes.
    
    Args:
        notes: Notes string
        
    Returns:
        Tuple of (is_valid, sanitized_notes, error_message)
    """
    if not notes or notes == "":
        return True, None, None
    
    sanitized = sanitize_string(notes, max_length=2000)
    if len(sanitized) > 2000:
        return False, None, "Notes must be less than 2000 characters"
    
    return True, sanitized, None


def validate_todo_id(todo_id: any) -> tuple[bool, Optional[int], Optional[str]]:
    """Validate a todo ID.
    
    Args:
        todo_id: Todo ID (can be int or string)
        
    Returns:
        Tuple of (is_valid, todo_id_int, error_message)
    """
    if todo_id is None:
        return False, None, "Todo ID is required"
    
    try:
        todo_id_int = int(todo_id)
        if todo_id_int <= 0:
            return False, None, "Todo ID must be a positive integer"
        return True, todo_id_int, None
    except (ValueError, TypeError):
        return False, None, "Todo ID must be a valid integer"
