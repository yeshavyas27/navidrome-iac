# Quick Start — Navidrome IaC Deployment (Apr 20)

**TL;DR:** Deploy a production-ready ML system in ~2 hours.

---

## 30-Second Overview

You're deploying:
- ✅ **Multi-node Kubernetes cluster** (CPU control-plane + optional GPU worker)
- ✅ **Navidrome music server** with ML recommendations
- ✅ **MLflow model registry** + training pipeline
- ✅ **Monitoring stack** (Prometheus/Grafana/Alertmanager)
- ✅ **GPU support** (optional: train models on GPU)

Everything runs on **Chameleon Cloud** in automated fashion.

---

## Prerequisites Checklist (5 min)

- [ ] Chameleon account with KVM@TACC access
- [ ] SSH key registered on Chameleon
- [ ] Local tools: `brew install terraform ansible helm kubectl`
- [ ] OpenStack credentials at `~/.config/openstack/clouds.yaml`
- [ ] Blazar lease reservation IDs (create on Chameleon UI)

---

## Step 1: Create Blazar Leases (5 min)

Go to **Chameleon UI** → **Leases** → **Create Lease**:

### Option A: CPU-Only (Budget, Simpler)
```
Resource: m1.xlarge (16 CPU, 32GB RAM)
Count: 1
Duration: 7 days
```
→ Get `RESERVATION_ID` (UUID)

### Option B: CPU + GPU (Full-Featured, RECOMMENDED)
Create **TWO** separate leases:

**Lease 1 (Control-plane):**
```
Resource: m1.xlarge (16 CPU, 32GB RAM)
Count: 1
Duration: 7 days
```
→ Get `RESERVATION_ID`

**Lease 2 (GPU node):**
```
Resource: GPU_NVIDIA_V100 (bare-metal)
Count: 1
Duration: 7 days
```
→ Get `GPU_RESERVATION_ID`

---

## Step 2: Security Groups (5 min)

Chameleon UI → **Network** → **Security Groups** → Create these (if missing):

| Name | Inbound Ports |
|---|---|
| `allow-ssh` | 22 |
| `navidrome-sg-proj05` | 4533, 8000, 9000, 9001, 3000, 9090, 9093 |

Get their **IDs** for Step 3.

---

## Step 3: Deploy! (90 min)

```bash
# 1. Clone repo
git clone https://github.com/<org>/navidrome-iac.git
cd navidrome-iac

# 2. Export environment variables
export RESERVATION_ID="<lease-id-cpu>"
export GPU_RESERVATION_ID="<lease-id-gpu>"  # Leave empty if CPU-only
export SG_DEFAULT_ID="<default-sg-id>"
export SG_SSH_ID="<allow-ssh-sg-id>"
export SG_NAVIDROME_ID="<navidrome-sg-proj05-sg-id>"

# 3. Run deployment (takes ~90 min total)
make all \
  RESERVATION_ID=$RESERVATION_ID \
  GPU_RESERVATION_ID=$GPU_RESERVATION_ID

# Behind the scenes:
# ├─ Terraform: creates VMs, networks, floating IPs (5 min)
# ├─ Ansible pre-k8s: disables firewall, configures Docker (5 min)
# ├─ Kubespray: installs K8s cluster (30-40 min) ☕
# ├─ Ansible post-k8s: configures kubectl, ArgoCD, Argo (5 min)
# └─ Helm: deploys platform + monitoring (5 min)
```

---

## Step 4: Verify Everything Works (5 min)

```bash
# Get IPs
export FLOATING_IP=$(terraform -chdir=tf/kvm output -raw floating_ip_out)
export INTERNAL_IP=$(terraform -chdir=tf/kvm output -raw node1_internal_ip_out)

# Check cluster
kubectl cluster-info
kubectl get nodes          # Should show node1, node2 (+ node3 if GPU)
kubectl get pods -A        # Should show services Running

# Verify services reachable
curl http://$INTERNAL_IP:4533     # Navidrome
curl http://$INTERNAL_IP:8000     # MLflow
curl http://$INTERNAL_IP:9090     # Prometheus
curl http://$INTERNAL_IP:3000     # Grafana (admin/admin)
```

---

## Step 5: Create Secrets (Required)

**NEVER commit secrets to Git!** Create them on the cluster:

```bash
# PostgreSQL (choose your own passwords!)
kubectl create secret generic postgres-credentials \
  -n navidrome-platform \
  --from-literal=username=postgres \
  --from-literal=password=<choose-password> \
  --from-literal=dbname=mlflow \
  --from-literal=navidrome_dbname=navidrome

# MinIO
kubectl create secret generic minio-credentials \
  -n navidrome-platform \
  --from-literal=accesskey=minioadmin \
  --from-literal=secretkey=<choose-password>

# Verify
kubectl get secrets -n navidrome-platform
```

---

## Step 6: Deploy Helm Charts

```bash
# Platform services (Navidrome, MLflow, Postgres, MinIO)
helm install navidrome-platform ./k8s/platform \
  --namespace navidrome-platform \
  --set navidrome.externalIP=$INTERNAL_IP \
  --set minio.externalIP=$INTERNAL_IP \
  --set mlflow.externalIP=$INTERNAL_IP \
  --set gateway.externalIP=$INTERNAL_IP

# Monitoring (Prometheus, Grafana, Alertmanager)
helm install navidrome-monitoring ./k8s/monitoring \
  --namespace navidrome-monitoring \
  --set prometheus.externalIP=$INTERNAL_IP \
  --set grafana.externalIP=$INTERNAL_IP \
  --set alertmanager.externalIP=$INTERNAL_IP

# Wait for all pods to be Ready
kubectl wait --for=condition=Ready pod --all -A --timeout=300s

# Verify
kubectl get pods -n navidrome-platform
kubectl get pods -n navidrome-monitoring
```

---

## Step 7: Setup GPU (Optional, if GPU_RESERVATION_ID set)

```bash
# Label GPU node
kubectl label nodes node3 gpu=true --overwrite

# Install NVIDIA device plugin
kubectl apply -f k8s/monitoring/templates/nvidia-device-plugin.yaml

# Verify GPUs visible
kubectl describe nodes node3 | grep -A 5 nvidia.com/gpu
# Should show: nvidia.com/gpu: 1
```

---

## Step 8: Access Services

| Service | URL | Login |
|---------|-----|-------|
| **Navidrome** | `http://$INTERNAL_IP:4533` | Create user in UI |
| **MLflow** | `http://$INTERNAL_IP:8000` | No auth |
| **MinIO** | `http://$INTERNAL_IP:9001` | minioadmin / <password> |
| **Prometheus** | `http://$INTERNAL_IP:9090` | No auth |
| **Grafana** | `http://$INTERNAL_IP:3000` | admin / admin |
| **Alertmanager** | `http://$INTERNAL_IP:9093` | No auth |

---

## Step 9: Deploy ML Workflows (Optional)

```bash
# Create Argo namespace
kubectl create namespace argo

# Deploy workflow templates
kubectl apply -f workflows/train-model.yaml -n argo
kubectl apply -f workflows/train-gpu.yaml -n argo       # If GPU
kubectl apply -f workflows/build-container-image.yaml -n argo
kubectl apply -f workflows/test-staging.yaml -n argo

# Submit test run
argo submit -n argo --from workflowtemplate/train-model

# Watch progress
argo logs -n argo <workflow-id> -f
```

---

## Step 10: Record Demo Videos

For Apr 20 submission, record these (OBS, ScreenFlow, etc.):

1. **Cluster Health (2 min)**
   ```bash
   kubectl get nodes
   kubectl get pods -A
   kubectl top nodes
   ```

2. **Services Running (2 min)**
   - Open Navidrome in browser
   - Open MLflow in browser
   - Create a user in Navidrome

3. **Monitoring (2 min)**
   - Open Prometheus dashboard
   - Open Grafana dashboard
   - Show alerts configured

4. **GPU Job (2 min, optional)**
   - Submit training job
   - Show GPU utilization with `nvidia-smi`
   - Show job completion in Argo UI

---

## Cleanup (When Done)

```bash
# Suspend lease (pause costs, can resume later)
# Chameleon UI → Leases → <lease> → Suspend

# Or delete everything (permanent):
terraform -chdir=tf/kvm destroy -auto-approve
```

---

## Troubleshooting

### Pods stuck in Pending
```bash
kubectl describe pod <pod-name> -n <namespace>
# Check events for: PVC not bound, insufficient resources, image pull errors
kubectl delete pod <pod> -n <namespace>  # Force restart
```

### Helm install fails
```bash
helm lint ./k8s/platform              # Check chart syntax
helm install --dry-run --debug ...    # Preview what will happen
```

### Can't connect to services
```bash
# Check SSH tunnel is running
ps aux | grep 'ssh.*6443'

# Or create it manually:
ssh -i ~/.ssh/id_rsa_chameleon \
  -L 6443:127.0.0.1:6443 \
  -N cc@$FLOATING_IP &
```

### GPU not detected
```bash
# On GPU node (node3):
ssh -J cc@$FLOATING_IP cc@192.168.1.13
nvidia-smi  # Should show V100

# If fails, re-enable GPU in Kubespray:
# ansible/k8s/inventory/mycluster/group_vars/all.yaml
# nvidia_gpu_enabled: true
# nvidia_runtime_enabled: true
```

---

## For More Details

- **Full deployment guide:** `DEPLOYMENT.md`
- **Safeguarding plan:** `docs/SAFEGUARDING.md`
- **All changes:** `UPDATES_APR20.md`
- **Architecture:** `docs/ARCHITECTURE.md`

---

## Timeline

| Phase | Duration | What Happens |
|-------|----------|---|
| Terraform | 5 min | VMs created, networks configured |
| Wait SSH | 5 min | Boot and network initialization |
| Pre-K8s | 5 min | Firewall disabled, Docker configured |
| Kubespray | 30-40 min | K8s cluster installed (longest step) |
| Post-K8s | 5 min | kubectl, ArgoCD, Argo installed |
| Helm | 5 min | Platform services deployed |
| Total | ~60-90 min | **System ready!** |

---

## Success Criteria

✅ `kubectl get nodes` shows all nodes Ready  
✅ `kubectl get pods -A` shows all pods Running  
✅ Can access Navidrome, MLflow, Prometheus, Grafana in browser  
✅ HPA working: `kubectl get hpa -n navidrome-platform`  
✅ Alerts configured: Prometheus Targets all Green  
✅ (Optional) GPU visible: `kubectl describe node node3 | grep nvidia`  
✅ Can submit Argo Workflow and see it progress  

---

## Next Steps

1. Load sample music into Navidrome
2. Create users and test recommendations
3. Submit training workflow and monitor in MLflow
4. Check Grafana dashboards
5. Record demo videos for submission
6. Complete safeguarding documentation
7. Submit!

---

**Good luck! 🚀**

For help: GitHub issues or Slack @devops-team
