"""Simple caching layer for todos."""
import time
from typing import Optional, Dict, Any, List
from threading import Lock
from logging import getLogger

logger = getLogger(__name__)


class TodoCache:
    """Simple in-memory cache for todos with TTL."""
    
    def __init__(self, ttl_seconds: int = 60):
        """Initialize the cache.
        
        Args:
            ttl_seconds: Time to live for cache entries in seconds
        """
        self._cache: Dict[str, tuple[List[Dict[str, Any]], float]] = {}
        self._lock = Lock()
        self.ttl = ttl_seconds
    
    def get(self, key: str) -> Optional[List[Dict[str, Any]]]:
        """Get cached todos for a key.
        
        Args:
            key: Cache key (typically user OID)
            
        Returns:
            List of todos or None if not cached or expired
        """
        with self._lock:
            if key not in self._cache:
                return None
            
            todos, timestamp = self._cache[key]
            
            # Check if expired
            if time.time() > timestamp + self.ttl:
                del self._cache[key]
                logger.debug("[TodoCache] Cache expired for key: %s", key)
                return None
            
            logger.debug("[TodoCache] Cache hit for key: %s", key)
            return todos
    
    def set(self, key: str, todos: List[Dict[str, Any]]) -> None:
        """Set cached todos for a key.
        
        Args:
            key: Cache key (typically user OID)
            todos: List of todos to cache
        """
        with self._lock:
            self._cache[key] = (todos, time.time())
            logger.debug("[TodoCache] Cache set for key: %s (count: %d)", key, len(todos))
    
    def invalidate(self, key: str) -> None:
        """Invalidate cache for a key.
        
        Args:
            key: Cache key to invalidate
        """
        with self._lock:
            if key in self._cache:
                del self._cache[key]
                logger.debug("[TodoCache] Cache invalidated for key: %s", key)
    
    def clear(self) -> None:
        """Clear all cache entries."""
        with self._lock:
            self._cache.clear()
            logger.debug("[TodoCache] Cache cleared")


# Global cache instance
_todo_cache: Optional[TodoCache] = None


def get_cache(ttl_seconds: int = 60) -> TodoCache:
    """Get or create the global todo cache instance.
    
    Args:
        ttl_seconds: Time to live for cache entries
        
    Returns:
        TodoCache instance
    """
    global _todo_cache
    if _todo_cache is None:
        _todo_cache = TodoCache(ttl_seconds=ttl_seconds)
    return _todo_cache
