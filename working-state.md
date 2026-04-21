# Working State - Navidrome MLOps Platform

Last updated: April 21, 2026

## Cluster

- **Provider:** Chameleon Cloud KVM@TACC
- **Node:** node1-mlops-proj05
- **Flavor:** m1.xlarge (8 vCPU, 16GB RAM, 40GB root disk)
- **Floating IP:** 129.114.27.204
- **Internal IP (sharednet/ens3):** 10.56.2.132
- **Private IP:** 192.168.1.11
- **K8s version:** v1.30.4 (Kubespray)
- **Container runtime:** Docker 26.1.2
- **Lease expires:** May 3, 2026

## Storage

| Volume | Device | Mount | Size | Purpose |
|--------|--------|-------|------|---------|
| Root disk | /dev/vda3 | / | 37GB | OS, Docker images, K8s |
| Block storage | /dev/vdb | /mnt/music-storage | 100GB | Docker data, music, MinIO, Prometheus |

### Block storage layout

```
/mnt/music-storage/
├── docker/              # Docker data (moved from root)
├── music/
│   └── audio_complete/  # 2,053 enriched 30Music MP3s with ID3 metadata
├── minio-data/          # MinIO PVC data
├── prometheus/          # Prometheus PVC data
└── serve-artifacts/     # Model artifacts PVC (model.pt, vocabs.pkl)
```

## SSH Access

```bash
ssh -i ~/.ssh/id_rsa_chameleon cc@129.114.27.204
```

### kubectl access (from laptop)

```bash
# Terminal 1: tunnel
ssh -i ~/.ssh/id_rsa_chameleon -L 6443:127.0.0.1:6443 -N cc@129.114.27.204 &

# Terminal 2: copy kubeconfig (one-time)
scp -i ~/.ssh/id_rsa_chameleon cc@129.114.27.204:~/.kube/config /tmp/navidrome-kubeconfig

# Use
export KUBECONFIG=/tmp/navidrome-kubeconfig
kubectl get pods -A
```

## Services

| Service | Namespace | Port | External URL | Type |
|---------|-----------|------|-------------|------|
| Navidrome | navidrome-platform | 4533 | http://129.114.27.204:4533 | ClusterIP + externalIP |
| MLflow | navidrome-platform | 8000 | http://129.114.27.204:8000 | ClusterIP + externalIP |
| MinIO API | navidrome-platform | 9000 | http://129.114.27.204:9000 | ClusterIP + externalIP |
| MinIO Console | navidrome-platform | 9001 | http://129.114.27.204:9001 | ClusterIP + externalIP |
| Feedback API | navidrome-platform | 8001 | http://129.114.27.204:8001 | NodePort + externalIP |
| PostgreSQL | navidrome-platform | 5432 | Internal only | ClusterIP |
| Redis | navidrome-platform | 6379 | Internal only | ClusterIP |
| Redis Exporter | navidrome-platform | 9121 | Internal only | ClusterIP |
| navidrome-serve | navidrome-platform | 8080 | Internal only | ClusterIP |
| Prometheus | navidrome-monitoring | 9090 | http://129.114.27.204:9090 | ClusterIP + externalIP |
| Grafana | navidrome-monitoring | 3000 | http://129.114.27.204:3000 | ClusterIP + externalIP |
| Alertmanager | navidrome-monitoring | 9093 | http://129.114.27.204:9093 | ClusterIP + externalIP |

**Important:** externalIP must be `10.56.2.132` (sharednet), NOT `192.168.1.11` (private). Helm upgrades reset this. The CI/CD pipeline auto-fixes it.

## Credentials

### PostgreSQL

```
Host: postgres.navidrome-platform.svc.cluster.local
Port: 5432
User: postgres
Password: navidrome2026
Databases: mlflow, navidrome
```

### MinIO

```
Endpoint: http://minio.navidrome-platform.svc.cluster.local:9000
Access Key: minioadmin
Secret Key: navidrome2026
Buckets: artifacts, training-data, feedback, mlflow-artifacts, navidrome-metadata, audio-cache
```

### Grafana

```
URL: http://129.114.27.204:3000
User: admin
Password: admin
```

### Chameleon Swift (Object Storage)

```
OS_AUTH_URL=https://chi.uc.chameleoncloud.org:5000/v3
OS_APPLICATION_CREDENTIAL_ID=648ff7bbd6644376bae2177818acc3fb
OS_APPLICATION_CREDENTIAL_SECRET=21CQ_fWzYJF-sY1OMzkNt8zWmNBAfyrv3QmNH0qh67PeS2EYw5YaW8blTBcZO7mq8Mg3l2CrgiEo86EJHVXxaQ
OS_AUTH_TYPE=v3applicationcredential
```

## Navidrome Deployment Env Vars

```yaml
ND_MUSICFOLDER: /music
ND_DATAFOLDER: /data
ND_LOGLEVEL: info
ND_ENABLERECOMMENDATIONS: "true"
ND_RECOMMENDATIONSERVICEURL: http://navidrome-serve.navidrome-platform.svc.cluster.local:8080
FEEDBACK_API_URL: http://feedback-api-proj05.navidrome-platform.svc.cluster.local:8001
POSTGRES_USER: (from secret postgres-credentials)
POSTGRES_PASSWORD: (from secret postgres-credentials)
POSTGRES_DB: (from secret postgres-credentials)
ND_DBPATH: postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres/$(POSTGRES_DB)?sslmode=disable
```

### Navidrome Volumes

```yaml
volumes:
  - name: navidrome-data       # PVC: /data (SQLite DB, config)
  - name: navidrome-music      # PVC: /music (unused after hostPath added)
  - name: external-music       # hostPath: /mnt/music-storage/music/audio_complete -> /music/audio_complete
```

## navidrome-serve Deployment Env Vars

```yaml
MLFLOW_TRACKING_URI: ""                    # Empty = load model from local file
VOCAB_PATH: /app/artifacts/vocabs.pkl
MODEL_PATH: /app/artifacts/best_gru4rec.pt
DEVICE: cpu
MINIO_URL: http://minio.navidrome-platform.svc.cluster.local:9000
MINIO_USER: minioadmin
MINIO_PASSWORD: navidrome2026
MINIO_BUCKET: artifacts
MINIO_POPULARITY_KEY: popularity.npy
TRACK_META_BUCKET: navidrome-metadata
TRACK_META_KEY: track_dict.parquet
AUDIO_BUCKET: audio-cache
```

### Serve Volumes

```yaml
volumes:
  - name: artifacts            # PVC: serve-artifacts-pvc -> /app/artifacts
  - name: app-patch            # ConfigMap: serve-app-patch (popularity fallback)
```

## Feedback API Env Vars

```yaml
PG_HOST: postgres.navidrome-platform.svc.cluster.local
PG_PORT: "5432"
PG_DB: navidrome
PG_USER: postgres
PG_PASS: navidrome2026
REDIS_HOST: redis.navidrome-platform.svc.cluster.local
REDIS_PORT: "6379"
OS_AUTH_URL: https://chi.uc.chameleoncloud.org:5000/v3
OS_APPLICATION_CREDENTIAL_ID: 648ff7bbd6644376bae2177818acc3fb
OS_APPLICATION_CREDENTIAL_SECRET: 21CQ_fWzYJF-sY1OMzkNt8zWmNBAfyrv3QmNH0qh67PeS2EYw5YaW8blTBcZO7mq8Mg3l2CrgiEo86EJHVXxaQ
FEEDBACK_API_URL: http://feedback-api-proj05.navidrome-platform.svc.cluster.local:8000
```

## K8s Secrets

```bash
# postgres-credentials (in navidrome-platform namespace)
kubectl get secret postgres-credentials -n navidrome-platform -o yaml
# Keys: username, password, dbname, navidrome_dbname

# minio-credentials (in navidrome-platform namespace)
kubectl get secret minio-credentials -n navidrome-platform -o yaml
# Keys: accesskey, secretkey
```

## CI/CD Pipelines

### navidrome_mlops repo (yeshavyas27)

- **Trigger:** Push to `navidrome-custom` branch
- **Workflow:** `.github/workflows/deploy.yml`
- **Action:** SSH to cluster -> Argo build workflow -> restart Navidrome pod
- **Secrets needed:** `CHAMELEON_HOST`, `CHAMELEON_SSH_KEY`
- **URL:** https://github.com/yeshavyas27/navidrome_mlops/actions

### navidrome-iac repo (salawhaaat)

- **Trigger:** Push to `main` (when k8s/ or workflows/ change)
- **Workflow:** `.github/workflows/deploy-infra.yml`
- **Action:** SSH to cluster -> helm upgrade platform + monitoring -> apply Argo workflows -> re-add hostPath volume
- **Secrets needed:** `CHAMELEON_HOST`, `CHAMELEON_SSH_KEY`
- **URL:** https://github.com/salawhaaat/navidrome-iac/actions

## Argo Workflow Templates

```bash
argo list -n argo              # List recent runs
argo submit -n argo --from workflowtemplate/build-navidrome-custom   # Build Navidrome
argo submit -n argo --from workflowtemplate/build-serve              # Build serving container
```

## DNS Fix

NodeLocalDNS was forwarding to `/etc/resolv.conf` which had a broken upstream. Fixed to use `8.8.8.8`:

```bash
# If DNS breaks again:
kubectl get configmap nodelocaldns -n kube-system -o yaml | \
  sed 's|forward . /etc/resolv.conf|forward . 8.8.8.8 1.1.1.1|' | \
  kubectl apply -f -
kubectl delete pod -l k8s-app=nodelocaldns -n kube-system
```

## externalIP Fix

After Helm upgrades, externalIPs reset to `192.168.1.11`. Fix:

```bash
kubectl patch svc navidrome -n navidrome-platform --type='json' -p='[{"op":"replace","path":"/spec/externalIPs/0","value":"10.56.2.132"}]'
kubectl patch svc minio -n navidrome-platform --type='json' -p='[{"op":"replace","path":"/spec/externalIPs/0","value":"10.56.2.132"}]'
kubectl patch svc mlflow -n navidrome-platform --type='json' -p='[{"op":"replace","path":"/spec/externalIPs/0","value":"10.56.2.132"}]'
```

## Repos

| Repo | Purpose | Branch |
|------|---------|--------|
| yeshavyas27/navidrome_mlops | Navidrome fork + training + data | `navidrome-custom` (app), `master` (training/data) |
| salawhaaat/navidrome-iac | Infrastructure as code | `main` |
| vanshika2022/navidrome-recommendations | Serving container | `main` |

## Data Pipeline (Confirmed Working)

```
User plays 3+ songs (15+ sec each)
  -> Navidrome scrobbler extracts track ID from filename (e.g. 3012335 from audio_complete/3012335.mp3)
  -> POST to feedback API at :8001/api/feedback
  -> Feedback API stores session in Postgres (sessions table)
  -> 167k+ sessions in database
```

## Recommendation Pipeline (Confirmed Working)

```
User visits /app/#/recommendation
  -> Go handler queries Navidrome SQLite for random songs
  -> Extracts 30Music track IDs from filenames
  -> POST /recommend-by-tracks to navidrome-serve:8080
  -> GRU4Rec model returns top 100 recommendations (with popularity fallback for OOV)
  -> Go handler filters to tracks in Navidrome library (matching by filename)
  -> Returns top 10 with real title/artist from SQLite DB
  -> React UI shows recommendations with play button
  -> Play button dispatches to Navidrome native player
```

## Music Library

- **Source:** 30Music dataset audio files enriched with ID3 metadata by Vanshika
- **Location:** Swift `navidrome-bucket-proj05/audio_complete/` -> `/mnt/music-storage/music/audio_complete/`
- **Mount:** hostPath volume into Navidrome pod at `/music/audio_complete`
- **Count:** 2,053 tracks
- **Size:** ~8GB
- **Format:** MP3 with embedded artist/title ID3 tags
- **Filenames:** 30Music integer track IDs (e.g. `3012335.mp3`)

## Track Metadata in MinIO

```
Bucket: navidrome-metadata
File: track_dict.parquet
Columns: track_id, title, artist
Rows: 2,053 (matches Navidrome library)
Purpose: Serving container loads this for title/artist in API responses
```

## Model Artifacts

```
Location: /mnt/music-storage/serve-artifacts/ (PVC mounted at /app/artifacts in serve pod)
Files:
  - best_gru4rec.pt (182MB) - GRU4Rec model weights
  - vocabs.pkl (7.2MB) - item2idx (745,352 items), user2idx (41,079 users)
```

## Team

| Member | Role | GitHub |
|--------|------|--------|
| Salauat | DevOps/Platform | @salawhaaat |
| Yesha | Training | @yeshavyas27 |
| Vanshika | Serving | @vanshika2022 |
| Hashir | Data | @hashirmuzaffar |

## Quick Health Check

```bash
# All pods running?
kubectl get pods -n navidrome-platform

# Disk OK?
df -h /dev/vda3 /dev/vdb

# Resources OK?
kubectl top nodes
kubectl top pods -n navidrome-platform

# DNS working?
kubectl run dns-test --rm -it --restart=Never --image=busybox -- nslookup github.com

# Feedback pipeline working?
kubectl exec deploy/postgres -n navidrome-platform -- psql -U postgres -d navidrome -c "SELECT count(*) FROM sessions;"

# Recommendations working?
kubectl exec deploy/navidrome -n navidrome-platform -- wget -qO- --timeout=10 \
  --post-data='{"session_id":"test","user_id":"admin","track_ids":["462963","3746662"],"top_n":3}' \
  --header='Content-Type: application/json' \
  http://navidrome-serve:8080/recommend-by-tracks
```
