# Redis Integration Examples

Complete code examples for integrating Redis with Navidrome services.

---

## 1. Session Caching (Navidrome)

### Python Session Manager

```python
# services/session_manager.py
import json
import time
from datetime import datetime, timedelta
from redis import Redis
from typing import Optional, Dict

class SessionManager:
    def __init__(self, redis_host: str = 'redis', redis_port: int = 6379, redis_db: int = 0):
        self.redis = Redis(
            host=redis_host,
            port=redis_port,
            db=redis_db,
            decode_responses=True,
            socket_keepalive=True,
            socket_keepalive_options={1: 1, 2: 3, 3: 3}
        )
    
    def create_session(self, user_id: str, device: str, ttl_hours: int = 24) -> str:
        """Create new user session"""
        session_id = f"{user_id}:{datetime.utcnow().timestamp()}"
        session_data = {
            'user_id': user_id,
            'device': device,
            'created_at': datetime.utcnow().isoformat(),
            'last_activity': datetime.utcnow().isoformat()
        }
        
        # Store in Redis with TTL
        ttl_seconds = ttl_hours * 3600
        self.redis.setex(
            f"session:{session_id}",
            ttl_seconds,
            json.dumps(session_data)
        )
        return session_id
    
    def get_session(self, session_id: str) -> Optional[Dict]:
        """Retrieve session data"""
        session_json = self.redis.get(f"session:{session_id}")
        if not session_json:
            return None
        return json.loads(session_json)
    
    def update_activity(self, session_id: str) -> bool:
        """Update last activity timestamp"""
        session_data = self.get_session(session_id)
        if not session_data:
            return False
        
        session_data['last_activity'] = datetime.utcnow().isoformat()
        ttl = self.redis.ttl(f"session:{session_id}")
        self.redis.setex(
            f"session:{session_id}",
            ttl,
            json.dumps(session_data)
        )
        return True
    
    def invalidate_session(self, session_id: str) -> bool:
        """Logout user"""
        return self.redis.delete(f"session:{session_id}") > 0
    
    def get_user_sessions(self, user_id: str) -> list:
        """Get all active sessions for user"""
        pattern = f"session:{user_id}:*"
        keys = self.redis.keys(pattern)
        sessions = []
        for key in keys:
            session_data = json.loads(self.redis.get(key))
            sessions.append({
                'session_id': key.replace('session:', ''),
                **session_data
            })
        return sessions

# Usage in Flask app
from flask import Flask, request, session as flask_session

app = Flask(__name__)
session_mgr = SessionManager()

@app.route('/login', methods=['POST'])
def login():
    user_id = request.json['user_id']
    device = request.json.get('device', 'web')
    
    session_id = session_mgr.create_session(user_id, device, ttl_hours=24)
    return {'session_id': session_id}

@app.route('/verify', methods=['GET'])
def verify_session():
    session_id = request.headers.get('X-Session-ID')
    session_data = session_mgr.get_session(session_id)
    
    if not session_data:
        return {'error': 'Invalid session'}, 401
    
    # Update activity
    session_mgr.update_activity(session_id)
    return session_data

@app.route('/logout', methods=['POST'])
def logout():
    session_id = request.headers.get('X-Session-ID')
    if session_mgr.invalidate_session(session_id):
        return {'status': 'logged out'}
    return {'error': 'Session not found'}, 404
```

---

## 2. User Embeddings Cache (Recommendation Engine)

### Embedding Cache Manager

```python
# services/embedding_cache.py
import pickle
import numpy as np
from redis import Redis
from typing import Optional, Tuple

class EmbeddingCache:
    def __init__(self, redis_host: str = 'redis', redis_port: int = 6379):
        self.redis = Redis(
            host=redis_host,
            port=redis_port,
            db=1,  # DB 1 for embeddings
            decode_responses=False  # Binary mode for numpy arrays
        )
    
    def get_user_embedding(self, user_id: str, ttl_hours: int = 24) -> Optional[np.ndarray]:
        """Retrieve cached user embedding"""
        key = f"embedding:user:{user_id}"
        cached = self.redis.get(key)
        if cached:
            return np.frombuffer(pickle.loads(cached), dtype=np.float32)
        return None
    
    def set_user_embedding(self, user_id: str, embedding: np.ndarray, ttl_hours: int = 24):
        """Cache user embedding"""
        key = f"embedding:user:{user_id}"
        ttl_seconds = ttl_hours * 3600
        
        # Convert numpy array to bytes
        embedding_bytes = embedding.astype(np.float32).tobytes()
        self.redis.setex(key, ttl_seconds, pickle.dumps(embedding_bytes))
    
    def get_item_embedding(self, item_id: str) -> Optional[np.ndarray]:
        """Retrieve cached item (song) embedding"""
        key = f"embedding:item:{item_id}"
        cached = self.redis.get(key)
        if cached:
            return np.frombuffer(pickle.loads(cached), dtype=np.float32)
        return None
    
    def set_item_embedding(self, item_id: str, embedding: np.ndarray, ttl_hours: int = 48):
        """Cache item embedding"""
        key = f"embedding:item:{item_id}"
        ttl_seconds = ttl_hours * 3600
        
        embedding_bytes = embedding.astype(np.float32).tobytes()
        self.redis.setex(key, ttl_seconds, pickle.dumps(embedding_bytes))
    
    def batch_get_embeddings(self, user_ids: list) -> dict:
        """Get multiple embeddings in single roundtrip"""
        pipe = self.redis.pipeline()
        for user_id in user_ids:
            pipe.get(f"embedding:user:{user_id}")
        
        results = {}
        cached_values = pipe.execute()
        for user_id, cached in zip(user_ids, cached_values):
            if cached:
                results[user_id] = np.frombuffer(pickle.loads(cached), dtype=np.float32)
        return results
    
    def batch_set_embeddings(self, embeddings: dict, ttl_hours: int = 24):
        """Set multiple embeddings in single roundtrip"""
        pipe = self.redis.pipeline()
        ttl_seconds = ttl_hours * 3600
        
        for entity_id, embedding in embeddings.items():
            key = f"embedding:user:{entity_id}"
            embedding_bytes = embedding.astype(np.float32).tobytes()
            pipe.setex(key, ttl_seconds, pickle.dumps(embedding_bytes))
        
        pipe.execute()
    
    def clear_user_embedding(self, user_id: str):
        """Remove cached embedding"""
        self.redis.delete(f"embedding:user:{user_id}")
    
    def get_cache_stats(self) -> dict:
        """Get cache performance metrics"""
        info = self.redis.info('stats')
        return {
            'hits': info['keyspace_hits'],
            'misses': info['keyspace_misses'],
            'hit_rate': info['keyspace_hits'] / (info['keyspace_hits'] + info['keyspace_misses']) 
                       if (info['keyspace_hits'] + info['keyspace_misses']) > 0 else 0,
            'evictions': info.get('evicted_keys', 0)
        }

# Usage in recommendation service
from ml_models import RecommendationModel

class RecommendationService:
    def __init__(self):
        self.cache = EmbeddingCache()
        self.model = RecommendationModel()
    
    def get_recommendations(self, user_id: str, top_k: int = 20) -> list:
        """Get recommendations with embedding cache"""
        
        # Try cache first
        user_embedding = self.cache.get_user_embedding(user_id)
        
        if user_embedding is None:
            # Cache miss: compute embedding from user history
            user_embedding = self.model.compute_user_embedding(user_id)
            self.cache.set_user_embedding(user_id, user_embedding)
        
        # Get item embeddings (batch cached retrieval)
        all_item_ids = self.model.get_all_items()
        cached_embeddings = self.cache.batch_get_embeddings(all_item_ids)
        
        # Compute missing embeddings
        missing_ids = [item_id for item_id in all_item_ids if item_id not in cached_embeddings]
        if missing_ids:
            missing_embeddings = self.model.compute_item_embeddings(missing_ids)
            self.cache.batch_set_embeddings(missing_embeddings)
            cached_embeddings.update(missing_embeddings)
        
        # Score items using cached embeddings
        scores = {}
        for item_id, item_embedding in cached_embeddings.items():
            scores[item_id] = np.dot(user_embedding, item_embedding)
        
        # Return top-k
        top_items = sorted(scores.items(), key=lambda x: x[1], reverse=True)[:top_k]
        return [item_id for item_id, score in top_items]
```

---

## 3. Real-Time Counters (Analytics)

### Event Counter

```python
# services/event_counter.py
from redis import Redis
from datetime import datetime, timedelta
from typing import Dict

class EventCounter:
    def __init__(self, redis_host: str = 'redis', redis_port: int = 6379):
        self.redis = Redis(
            host=redis_host,
            port=redis_port,
            db=2,  # DB 2 for counters
            decode_responses=True
        )
    
    def record_listen(self, user_id: str, song_id: str, artist_id: str):
        """Record a listen event"""
        now = datetime.utcnow()
        today = now.strftime('%Y-%m-%d')
        
        # Key patterns for different time windows
        pipe = self.redis.pipeline()
        
        # Daily counters
        pipe.incr(f"listens:song:{song_id}:day:{today}")
        pipe.incr(f"listens:artist:{artist_id}:day:{today}")
        pipe.incr(f"listens:user:{user_id}:day:{today}")
        
        # Weekly (expire after 7 days)
        week = now.strftime('%Y-W%W')
        pipe.incr(f"listens:song:{song_id}:week:{week}")
        pipe.expire(f"listens:song:{song_id}:week:{week}", 604800)
        
        # Global hourly (for realtime stats)
        hour = now.strftime('%Y-%m-%d-%H')
        pipe.incr(f"listens:global:hour:{hour}")
        pipe.expire(f"listens:global:hour:{hour}", 86400)
        
        pipe.execute()
    
    def get_daily_stats(self, entity_type: str, entity_id: str) -> int:
        """Get today's count for entity"""
        today = datetime.utcnow().strftime('%Y-%m-%d')
        count = self.redis.get(f"listens:{entity_type}:{entity_id}:day:{today}")
        return int(count) if count else 0
    
    def get_top_songs_today(self, limit: int = 10) -> list:
        """Get trending songs (today)"""
        today = datetime.utcnow().strftime('%Y-%m-%d')
        pattern = f"listens:song:*:day:{today}"
        
        songs = []
        for key in self.redis.keys(pattern):
            song_id = key.split(':')[2]
            count = int(self.redis.get(key))
            songs.append({'song_id': song_id, 'listens': count})
        
        return sorted(songs, key=lambda x: x['listens'], reverse=True)[:limit]
    
    def get_user_daily_listens(self, user_id: str, days: int = 7) -> Dict[str, int]:
        """Get user listen count over past N days"""
        today = datetime.utcnow().date()
        stats = {}
        
        for i in range(days):
            date = (today - timedelta(days=i)).strftime('%Y-%m-%d')
            count = self.redis.get(f"listens:user:{user_id}:day:{date}")
            stats[date] = int(count) if count else 0
        
        return stats
    
    def get_realtime_velocity(self) -> float:
        """Get current listens per minute (last hour)"""
        now = datetime.utcnow()
        current_hour = now.strftime('%Y-%m-%d-%H')
        
        count = self.redis.get(f"listens:global:hour:{current_hour}")
        if not count:
            return 0.0
        
        minutes_elapsed = now.minute + 1  # +1 to avoid division by zero
        return int(count) / minutes_elapsed

# Usage in Flask
app = Flask(__name__)
counter = EventCounter()

@app.route('/record_listen', methods=['POST'])
def record_listen():
    data = request.json
    counter.record_listen(
        user_id=data['user_id'],
        song_id=data['song_id'],
        artist_id=data['artist_id']
    )
    return {'status': 'recorded'}

@app.route('/trending', methods=['GET'])
def get_trending():
    limit = request.args.get('limit', 10, type=int)
    trending = counter.get_top_songs_today(limit)
    return {'trending_songs': trending}

@app.route('/user_stats/<user_id>', methods=['GET'])
def user_stats(user_id):
    days = request.args.get('days', 7, type=int)
    stats = counter.get_user_daily_listens(user_id, days)
    return {'daily_listens': stats}
```

---

## 4. Feature Store (ML Model Input)

### Feature Store Manager

```python
# services/feature_store.py
import json
import numpy as np
from redis import Redis
from typing import Dict, Optional

class FeatureStore:
    def __init__(self, redis_host: str = 'redis', redis_port: int = 6379):
        self.redis = Redis(
            host=redis_host,
            port=redis_port,
            db=3,  # DB 3 for features
            decode_responses=True
        )
    
    def get_user_features(self, user_id: str) -> Optional[Dict]:
        """Get pre-computed user features"""
        features_json = self.redis.get(f"features:user:{user_id}")
        if not features_json:
            return None
        return json.loads(features_json)
    
    def set_user_features(self, user_id: str, features: Dict, ttl_hours: int = 12):
        """Cache user features"""
        ttl_seconds = ttl_hours * 3600
        self.redis.setex(
            f"features:user:{user_id}",
            ttl_seconds,
            json.dumps(features)
        )
    
    def get_item_features(self, item_id: str) -> Optional[Dict]:
        """Get pre-computed item features"""
        features_json = self.redis.get(f"features:item:{item_id}")
        if not features_json:
            return None
        return json.loads(features_json)
    
    def set_item_features(self, item_id: str, features: Dict, ttl_hours: int = 24):
        """Cache item features"""
        ttl_seconds = ttl_hours * 3600
        self.redis.setex(
            f"features:item:{item_id}",
            ttl_seconds,
            json.dumps(features)
        )
    
    def batch_get_user_features(self, user_ids: list) -> Dict[str, Dict]:
        """Get features for multiple users"""
        pipe = self.redis.pipeline()
        for user_id in user_ids:
            pipe.get(f"features:user:{user_id}")
        
        results = {}
        cached_values = pipe.execute()
        for user_id, cached in zip(user_ids, cached_values):
            if cached:
                results[user_id] = json.loads(cached)
        return results
    
    def batch_get_item_features(self, item_ids: list) -> Dict[str, Dict]:
        """Get features for multiple items"""
        pipe = self.redis.pipeline()
        for item_id in item_ids:
            pipe.get(f"features:item:{item_id}")
        
        results = {}
        cached_values = pipe.execute()
        for item_id, cached in zip(item_ids, cached_values):
            if cached:
                results[item_id] = json.loads(cached)
        return results

# Usage in inference pipeline
class InferencePipeline:
    def __init__(self):
        self.feature_store = FeatureStore()
        self.model = load_model()
    
    def predict(self, user_id: str, item_id: str) -> float:
        """Predict user-item score with feature caching"""
        
        # Get cached features
        user_features = self.feature_store.get_user_features(user_id)
        item_features = self.feature_store.get_item_features(item_id)
        
        # If missing, compute and cache
        if not user_features:
            user_features = compute_user_features(user_id)
            self.feature_store.set_user_features(user_id, user_features)
        
        if not item_features:
            item_features = compute_item_features(item_id)
            self.feature_store.set_item_features(item_id, item_features)
        
        # Build feature vector for model
        feature_vector = self._build_feature_vector(user_features, item_features)
        
        # Score with ML model
        score = self.model.predict(feature_vector)[0]
        return float(score)
    
    def batch_predict(self, user_id: str, item_ids: list) -> Dict[str, float]:
        """Score multiple items for user"""
        
        # Get user features once
        user_features = self.feature_store.get_user_features(user_id)
        if not user_features:
            user_features = compute_user_features(user_id)
            self.feature_store.set_user_features(user_id, user_features)
        
        # Batch get item features
        item_features_dict = self.feature_store.batch_get_item_features(item_ids)
        
        # Compute missing item features
        missing_ids = [item_id for item_id in item_ids if item_id not in item_features_dict]
        if missing_ids:
            missing_features = {item_id: compute_item_features(item_id) for item_id in missing_ids}
            self.feature_store.redis.pipeline(transaction=False).execute()  # Batch set
            item_features_dict.update(missing_features)
        
        # Score all items
        scores = {}
        for item_id, item_features in item_features_dict.items():
            feature_vector = self._build_feature_vector(user_features, item_features)
            score = self.model.predict(feature_vector)[0]
            scores[item_id] = float(score)
        
        return scores
    
    def _build_feature_vector(self, user_features: Dict, item_features: Dict) -> np.ndarray:
        """Combine user and item features into model input"""
        return np.concatenate([
            np.array([
                user_features['listen_count'],
                user_features['avg_rating'],
                user_features['age_days']
            ]),
            np.array([
                item_features['popularity'],
                item_features['release_year_norm'],
                item_features['genre_id']
            ])
        ])
```

---

## 5. Connection Pooling (Production)

### Optimized Redis Connection

```python
# services/redis_pool.py
from redis import Redis
from redis.connection import ConnectionPool
from typing import Optional

class RedisPool:
    """Singleton Redis connection pool for all services"""
    _instance = None
    _pools = {}
    
    def __new__(cls):
        if cls._instance is None:
            cls._instance = super(RedisPool, cls).__new__(cls)
        return cls._instance
    
    @staticmethod
    def get_connection(db: int = 0, decode_responses: bool = True) -> Redis:
        """Get or create Redis connection"""
        key = f"redis_{db}_{decode_responses}"
        
        if key not in RedisPool._pools:
            pool = ConnectionPool(
                host='redis.navidrome-platform.svc.cluster.local',
                port=6379,
                db=db,
                max_connections=50,
                decode_responses=decode_responses,
                socket_keepalive=True,
                socket_keepalive_options={
                    1: 1,    # TCP_KEEPIDLE
                    2: 3,    # TCP_KEEPINTVL
                    3: 3     # TCP_KEEPCNT
                },
                health_check_interval=30
            )
            RedisPool._pools[key] = Redis(connection_pool=pool)
        
        return RedisPool._pools[key]
    
    @staticmethod
    def get_session_db() -> Redis:
        """Get DB 0 (sessions)"""
        return RedisPool.get_connection(db=0, decode_responses=True)
    
    @staticmethod
    def get_embeddings_db() -> Redis:
        """Get DB 1 (embeddings)"""
        return RedisPool.get_connection(db=1, decode_responses=False)
    
    @staticmethod
    def get_counters_db() -> Redis:
        """Get DB 2 (counters)"""
        return RedisPool.get_connection(db=2, decode_responses=True)
    
    @staticmethod
    def get_features_db() -> Redis:
        """Get DB 3 (features)"""
        return RedisPool.get_connection(db=3, decode_responses=True)

# Usage
from services.redis_pool import RedisPool

# In any service
r = RedisPool.get_session_db()
r.set('key', 'value')

# Or specific DB
r_embeddings = RedisPool.get_embeddings_db()
```

---

## 6. Monitoring & Health Checks

```python
# services/redis_monitor.py
from redis import Redis
from typing import Dict

class RedisMonitor:
    def __init__(self, redis: Redis):
        self.redis = redis
    
    def get_health(self) -> Dict:
        """Check Redis health"""
        try:
            self.redis.ping()
            info = self.redis.info('memory')
            return {
                'status': 'healthy',
                'memory_usage_mb': info['used_memory'] / 1024 / 1024,
                'memory_limit_mb': info.get('maxmemory', 0) / 1024 / 1024,
                'memory_percent': info['used_memory_percent']
            }
        except Exception as e:
            return {
                'status': 'unhealthy',
                'error': str(e)
            }
    
    def get_performance(self) -> Dict:
        """Get performance metrics"""
        info = self.redis.info('stats')
        total_commands = info['total_commands_processed']
        hits = info['keyspace_hits']
        misses = info['keyspace_misses']
        hit_rate = hits / (hits + misses) if (hits + misses) > 0 else 0
        
        return {
            'total_commands': total_commands,
            'hits': hits,
            'misses': misses,
            'hit_rate': hit_rate,
            'evictions': info.get('evicted_keys', 0)
        }

# Flask health check endpoint
from flask import Flask, jsonify

app = Flask(__name__)
monitor = RedisMonitor(RedisPool.get_session_db())

@app.route('/health/redis', methods=['GET'])
def redis_health():
    health = monitor.get_health()
    status = 200 if health['status'] == 'healthy' else 503
    perf = monitor.get_performance()
    return jsonify({**health, **perf}), status
```

---

## Key Takeaways

1. **Use separate Redis DBs** for different data types
2. **Always set TTL** to prevent unbounded memory growth
3. **Use pipelining** for batch operations
4. **Monitor hit rate** (aim for >80%)
5. **Handle cache misses gracefully** with fallback to DB
6. **Use connection pooling** for production
7. **Track evictions** — if > 0, memory pressure exists

All services connect to: `redis.navidrome-platform.svc.cluster.local:6379`

---

**Last Updated:** April 2026
