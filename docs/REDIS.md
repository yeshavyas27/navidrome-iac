# Redis Configuration & Usage Guide

Redis is now integrated into the navidrome-platform as a shared cache for:
- 🔑 **Session state** (user sessions, authentication tokens)
- 🧠 **User embeddings** (cached recommendation features)
- 📊 **Real-time metrics** (counters, rates)
- 🎯 **Feature store** (preprocessed features for inference)

---

## Architecture

Redis runs as a **single-replica StatefulSet** with:
- ✅ Persistent storage (5Gi PVC, `local-path` provisioner)
- ✅ LRU eviction policy (auto-remove least-recently-used keys when full)
- ✅ RDB snapshots (saves state every 15 min)
- ✅ Graceful shutdown (waits for clients to disconnect)
- ✅ Health checks (TCP liveness, PING readiness)
- ✅ Prometheus metrics (redis-exporter included)

---

## Access From Services

All services share the same **local IP** and communicate via Kubernetes DNS:

```yaml
# Service endpoint (inside cluster):
redis.navidrome-platform.svc.cluster.local:6379

# From environment variable (recommended):
REDIS_URL=redis://redis.navidrome-platform.svc.cluster.local:6379

# Using redis-cli inside pod:
kubectl exec -it redis-xxx -n navidrome-platform -- redis-cli
```

---

## Use Cases

### 1. Session Caching (Navidrome)

Store user sessions to enable:
- Multi-device login (same session ID across clients)
- Fast session lookup (< 1ms vs 100ms from DB)
- Automatic expiration (TTL-based cleanup)

**Example (Python):**
```python
import redis

r = redis.Redis(host='redis', port=6379, db=0, decode_responses=True)

# Store session
session_id = "user123-session-abc"
r.setex(session_id, 3600, json.dumps({
    'user_id': 123,
    'login_time': time.time(),
    'device': 'mobile'
}))

# Retrieve session
session = json.loads(r.get(session_id))

# Check if session exists
if r.exists(session_id):
    print("Session valid")
```

### 2. User Embeddings Cache (Recommendation Engine)

Cache user/item embeddings to avoid recomputing:

**Example (Python):**
```python
import redis
import numpy as np

r = redis.Redis(host='redis', port=6379, db=1, decode_responses=False)

# Store embedding (8 bytes per float32)
user_id = "user:123"
embedding = np.random.randn(128).astype(np.float32).tobytes()
r.set(user_id, embedding, ex=3600)  # Expires in 1 hour

# Retrieve embedding
cached = r.get(user_id)
if cached:
    embedding = np.frombuffer(cached, dtype=np.float32)
    print(f"Cache hit! Embedding shape: {embedding.shape}")
else:
    print("Cache miss, compute embedding...")
```

### 3. Real-Time Counters (Metrics)

Track events without hitting PostgreSQL:

**Example (Python):**
```python
r = redis.Redis(host='redis', port=6379, db=2)

# Count listens
r.incr(f"listens:song:{song_id}:today")
r.expire(f"listens:song:{song_id}:today", 86400)  # 24h TTL

# Get counter
listens = r.get(f"listens:song:{song_id}:today")

# Batch increment
pipe = r.pipeline()
for song in recently_played:
    pipe.incr(f"listens:song:{song}")
pipe.execute()
```

### 4. Feature Store (ML Inference)

Pre-compute and cache features for fast inference:

**Example (Python):**
```python
r = redis.Redis(host='redis', port=6379, db=3)

# Store pre-computed features for user
user_features = {
    'listen_count': 150,
    'avg_rating': 4.2,
    'favorite_genre': 'jazz',
    'embedding': np.random.randn(64).tobytes()
}

# Hash storage (good for structured data)
r.hset(f"features:user:{user_id}", mapping={
    'listen_count': user_features['listen_count'],
    'avg_rating': user_features['avg_rating'],
    'favorite_genre': user_features['favorite_genre']
})
r.hset(f"features:user:{user_id}:embedding", 
       'data', user_features['embedding'])

# Retrieve features
features = r.hgetall(f"features:user:{user_id}")
```

---

## Configuration

### Memory Management

Current config: **1GB max memory** with **LRU eviction**

```yaml
maxmemory 1gb                    # Max memory before eviction
maxmemory-policy allkeys-lru     # Remove least-recently-used keys
```

**To increase memory:**
```bash
# Edit redis.conf in ConfigMap
kubectl edit cm redis-config -n navidrome-platform

# Change:
maxmemory 2gb  # or desired size

# Restart Redis pod
kubectl rollout restart deployment/redis -n navidrome-platform
```

### Persistence

**Current:** RDB snapshots (AOF disabled)
- Snapshots every 15 min or on 10k writes
- Survives pod restarts (data in PVC)
- Fast startup (only loads RDB file)

**To enable durability (AOF):**
```bash
# Edit redis.conf
# Change: appendonly no → appendonly yes
# Restart Redis
```

### Database Selection

Redis has **16 logical databases** (0-15):
- **DB 0:** Sessions (TTL-based, expires in 1-24 hours)
- **DB 1:** User embeddings (1-hour TTL)
- **DB 2:** Real-time counters (24-hour TTL)
- **DB 3:** Feature store (variable TTL)
- **DB 4-15:** Available for other use cases

```python
# Select database
r = redis.Redis(host='redis', port=6379, db=0)  # Sessions
r = redis.Redis(host='redis', port=6379, db=1)  # Embeddings
```

---

## Monitoring

### Via Redis CLI

```bash
# Connect to Redis
kubectl exec -it redis-xxx -n navidrome-platform -- redis-cli

# Common commands
INFO                    # All statistics
INFO memory             # Memory usage
INFO stats              # Hit rate, commands
DBSIZE                  # Number of keys
KEYS *                  # List all keys (avoid in production!)
MEMORY USAGE <key>      # Size of single key
MONITOR                 # Real-time command stream
```

### Via Prometheus

Redis Exporter automatically exposes metrics:

```
redis_memory_used_bytes              # Current memory usage
redis_evicted_keys_total             # Total evictions (if > 0, OOM happening)
redis_expired_keys_total             # Keys auto-deleted by TTL
redis_connected_clients              # Active connections
redis_commands_processed_total        # Total commands
redis_keyspace_hits_total            # Cache hits
redis_keyspace_misses_total          # Cache misses
```

**Check in Prometheus:**
```
# Cache hit rate
rate(redis_keyspace_hits_total[5m]) / (rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m]))
```

**Alert rules (add to Prometheus):**
```yaml
- alert: RedisHighMemory
  expr: redis_memory_used_bytes / 1e9 > 0.8  # 80% of 1GB
  for: 5m
  annotations:
    summary: "Redis memory usage is {{ $value }}GB"

- alert: RedisHighEviction
  expr: rate(redis_evicted_keys_total[5m]) > 100
  for: 5m
  annotations:
    summary: "Redis evicting {{ $value }} keys/sec (out of memory!)"
```

---

## Best Practices

### 1. Use Appropriate TTL

```python
r = redis.Redis(host='redis', port=6379)

# Short TTL for ephemeral data
r.setex('session:abc123', 3600, data)        # 1 hour

# Medium TTL for embeddings (stale after a while)
r.setex('embedding:user:123', 86400, data)   # 24 hours

# Long TTL for feature store
r.setex('features:user:123', 604800, data)   # 7 days

# Set auto-expire on hash entries
r.hset('cache:user:123', mapping=data)
r.expire('cache:user:123', 3600)
```

### 2. Use Pipelining for Batch Operations

```python
pipe = r.pipeline()
for user_id in user_ids:
    pipe.get(f"embedding:user:{user_id}")
results = pipe.execute()  # Single roundtrip to Redis
```

### 3. Monitor Hit Rate

```python
# Get stats
info = r.info('stats')
hits = info['keyspace_hits']
misses = info['keyspace_misses']
hit_rate = hits / (hits + misses) if (hits + misses) > 0 else 0
print(f"Cache hit rate: {hit_rate:.2%}")  # Target: > 80%
```

### 4. Key Naming Convention

```python
# Hierarchical naming for organization
f"session:{user_id}:{session_id}"
f"embedding:user:{user_id}"
f"embedding:item:{item_id}"
f"features:user:{user_id}:{feature_name}"
f"counters:song:{song_id}:plays:today"
f"leaderboard:top_songs:week"
```

### 5. Handle Cache Misses Gracefully

```python
def get_user_embedding(user_id):
    # Try cache first
    cached = r.get(f"embedding:user:{user_id}")
    if cached:
        return pickle.loads(cached)
    
    # Cache miss: compute and store
    embedding = compute_embedding(user_id)
    r.setex(f"embedding:user:{user_id}", 3600, pickle.dumps(embedding))
    return embedding
```

---

## Troubleshooting

### Redis Pod Stuck in Pending

```bash
# Check events
kubectl describe pod redis-xxx -n navidrome-platform

# Common causes:
# - PVC not created → check: kubectl get pvc -n navidrome-platform
# - Storage full → check: df -h on node
```

### Out of Memory Errors

```bash
# Check memory usage
kubectl exec -it redis-xxx -n navidrome-platform -- redis-cli INFO memory

# If memory near limit and evictions increasing:
# 1. Increase maxmemory in redis.conf
# 2. Reduce TTL for some keys
# 3. Implement cache eviction policy in application
```

### Slow Queries

```bash
# Monitor commands in real-time
kubectl exec -it redis-xxx -n navidrome-platform -- redis-cli MONITOR

# Find slow commands
kubectl exec -it redis-xxx -n navidrome-platform -- redis-cli SLOWLOG GET 10

# Adjust slowlog threshold
kubectl exec -it redis-xxx -n navidrome-platform -- redis-cli CONFIG SET slowlog-log-slower-than 10000
```

### Data Loss on Pod Restart

If data not persisting:

```bash
# Check PVC is bound
kubectl get pvc -n navidrome-platform

# Check Redis config has persistence enabled
kubectl exec -it redis-xxx -n navidrome-platform -- redis-cli CONFIG GET save
# Should show: save 900 1 (or similar)

# Check dump.rdb exists
kubectl exec -it redis-xxx -n navidrome-platform -- ls -lh /data/
# Should show dump.rdb file
```

---

## Security (Optional)

### Enable Password Authentication

```bash
# 1. Set password in secret
kubectl create secret generic redis-credentials \
  -n navidrome-platform \
  --from-literal=password=<strong-password> \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. Update redis.conf
kubectl edit cm redis-config -n navidrome-platform
# Uncomment: requirepass <strong-password>

# 3. Restart Redis
kubectl rollout restart deployment/redis -n navidrome-platform

# 4. Connect with password
kubectl exec -it redis-xxx -n navidrome-platform -- redis-cli -a <password>
```

### ACL (Advanced)

For production, use Redis ACL:

```bash
# Inside redis-cli
> ACL SETUSER default on >mypassword ~* &* +@all
> ACL SETUSER app-user on >app-password ~* &* +@read +@write -shutdown
> ACL SAVE
```

---

## Integration with Services

### Navidrome (Session Caching)

```python
# In navidrome config
REDIS_URL = "redis://redis.navidrome-platform.svc.cluster.local:6379/0"
SESSION_BACKEND = "redis"
SESSION_TTL = 86400  # 24 hours
```

### MLflow (Artifact Caching)

```python
# In mlflow config
cache_backend = "redis"
redis_url = "redis://redis.navidrome-platform.svc.cluster.local:6379/1"
```

### Recommendation Service (Embedding Cache)

```python
# In serving app
from redis import Redis

cache = Redis(
    host='redis.navidrome-platform.svc.cluster.local',
    port=6379,
    db=3,  # Feature store DB
    decode_responses=False
)

@app.route('/recommend', methods=['POST'])
def recommend(user_id):
    # Check cache first
    cached_features = cache.get(f"features:user:{user_id}")
    if cached_features:
        features = pickle.loads(cached_features)
    else:
        features = fetch_features(user_id)
        cache.setex(f"features:user:{user_id}", 3600, pickle.dumps(features))
    
    # Inference
    recommendations = model.predict(features)
    return recommendations
```

---

## Performance Tips

- **Connection pooling:** Use Redis ConnectionPool for multiple requests
- **Batch operations:** Use Pipeline for multiple commands
- **Appropriate serialization:** Use pickle for complex objects, JSON for simple data
- **Key expiration:** Always set TTL to prevent unbounded memory growth
- **Monitoring:** Track hit rate, memory usage, evictions

---

## Storage Location

All data persists in:
```
Kubernetes PVC: redis-data (5Gi)
Physical location: /opt/local-path-provisioner/redis-data/ (on node)
RDB file: /data/dump.rdb (inside Redis pod)
```

---

## Cleanup (If Removing Redis)

```bash
# Delete Redis deployment
kubectl delete deployment redis -n navidrome-platform
kubectl delete deployment redis-exporter -n navidrome-platform
kubectl delete svc redis -n navidrome-platform
kubectl delete svc redis-exporter -n navidrome-platform
kubectl delete cm redis-config -n navidrome-platform
kubectl delete secret redis-credentials -n navidrome-platform
kubectl delete pvc redis-data -n navidrome-platform
```

---

**Last Updated:** April 2026  
**Status:** Ready for production use
