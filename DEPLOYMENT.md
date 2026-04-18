# Deployment Guide — Navidrome MLOps IaC

Complete step-by-step guide to deploy the Navidrome recommendation system on Chameleon Cloud for production (Apr 20 System Implementation).

---

## Prerequisites

### 1. Local Setup
```bash
# Install required tools
brew install terraform ansible helm kubectl

# SSH key for Chameleon (must be registered in Chameleon UI)
ssh-add ~/.ssh/id_rsa_chameleon

# OpenStack credentials (from Chameleon dashboard)
cp ~/.config/openstack/clouds.yaml  # File must exist
```

### 2. Chameleon Lease Reservation

Create a Blazar reservation on **KVM@TACC** (or similar site):

**Option A: CPU-only (single powerful node)**
- **Flavor:** `m1.xlarge` (16 CPU, 32GB RAM)
- **Count:** 1
- **Duration:** 7 days
- **Cost:** ~$30-40 for the week
- **Use case:** If your training fits on CPU or you want to minimize costs

**Option B: CPU + GPU (RECOMMENDED for Apr 20)**
- **Node 1:** `m1.xlarge` (16 CPU, 32GB) — control-plane + services
- **Node 2:** `gpu_v100` (8 CPU, 32GB + 1× V100 GPU) — training/inference
- **Count:** 1 of each
- **Duration:** 7 days
- **Cost:** ~$60-70 for the week
- **Use case:** Full MLOps pipeline with GPU acceleration

Get the **reservation/lease ID** (UUID) after approval. This is `RESERVATION_ID` below.

### 3. Security Groups (Pre-create on Chameleon)

Ensure these security groups exist in your OpenStack project:
- `default` (usually pre-exists)
- `allow-ssh` (inbound port 22)
- `navidrome-sg-proj05` (inbound ports: 4533, 8000, 9000, 9001, 3000, 9090, 9093)

Get their **IDs** from Chameleon UI → Network → Security Groups

---

## Deployment Steps

### Phase 1: Export Configuration

```bash
# Set required variables
export RESERVATION_ID="<your-blazar-lease-id>"
export GPU_RESERVATION_ID="<optional-gpu-lease-id>"  # Leave empty if CPU-only

# Security group IDs from Chameleon
export SG_DEFAULT_ID="<id>"
export SG_SSH_ID="<id>"
export SG_NAVIDROME_ID="<id>"

# Clone repo
git clone https://github.com/<org>/navidrome-iac.git
cd navidrome-iac
```

---

### Phase 2: Terraform (VM Provisioning)

```bash
# Create terraform.tfvars file
cat > tf/kvm/terraform.tfvars <<EOF
reservation_id = "$RESERVATION_ID"
gpu_reservation_id = "$GPU_RESERVATION_ID"
sg_default_id = "$SG_DEFAULT_ID"
sg_ssh_id = "$SG_SSH_ID"
sg_navidrome_id = "$SG_NAVIDROME_ID"
EOF

# Provision infrastructure
cd tf/kvm
terraform init -upgrade
terraform plan -out=tfplan
terraform apply tfplan

# Capture outputs (needed for Ansible)
export FLOATING_IP=$(terraform output -raw floating_ip_out)
export INTERNAL_IP=$(terraform output -raw node1_internal_ip_out)
export ALL_NODE_IPS=$(terraform output -json all_node_ips | jq -r 'to_entries | map("\(.key)=\(.value)") | join(" ")')

echo "Floating IP: $FLOATING_IP"
echo "Internal IP: $INTERNAL_IP"
echo "All nodes: $ALL_NODE_IPS"

cd ../..
```

---

### Phase 3: Ansible (Kubernetes Setup)

#### Step 1: Update Inventory with IPs

```bash
# Update Kubespray inventory
sed -i.bak "s/FLOATING_IP_HERE/$FLOATING_IP/g" \
  ansible/k8s/inventory/mycluster/hosts.yaml

# If using 2-node cluster (CPU + GPU):
if [ ! -z "$GPU_RESERVATION_ID" ]; then
  cat >> ansible/k8s/inventory/mycluster/hosts.yaml <<EOF
    node2:
      ansible_host: 192.168.1.12
      ansible_user: cc
      ip: 192.168.1.12
      access_ip: 192.168.1.12
    node3:  # GPU node
      ansible_host: 192.168.1.13
      ansible_user: cc
      ip: 192.168.1.13
      access_ip: 192.168.1.13
EOF
  
  # Update control-plane config
  sed -i.bak 's/node1:/node1:\n        node2:\n        node3:/g' \
    ansible/k8s/inventory/mycluster/hosts.yaml
fi

# Update values.yaml with internal IP
sed -i.bak "s/0\.0\.0\.0/$INTERNAL_IP/g" k8s/platform/values.yaml
sed -i.bak "s/0\.0\.0\.0/$INTERNAL_IP/g" k8s/monitoring/values.yaml
```

#### Step 2: Run Ansible Playbooks

```bash
# Wait for SSH to be ready
until ssh -i ~/.ssh/id_rsa_chameleon cc@$FLOATING_IP true 2>/dev/null; do
  echo "Waiting for SSH..."
  sleep 5
done

# Pre-K8s setup (disable firewall, configure Docker)
ansible-playbook -i ansible/inventory.yml \
  ansible/pre_k8s/pre_k8s_configure.yml \
  -e "jump_host=$FLOATING_IP"

# Wait a minute for reboots
sleep 60

# Install Kubernetes (takes ~30 min)
cd ansible/k8s/kubespray
python3 -m venv kubespray-venv
./kubespray-venv/bin/pip install -r requirements.txt -q
./kubespray-venv/bin/ansible-playbook \
  -i ../inventory/mycluster/hosts.yaml \
  cluster.yml \
  -e "jump_host=$FLOATING_IP"

# Enable GPU support if needed
if [ ! -z "$GPU_RESERVATION_ID" ]; then
  sed -i 's/nvidia_gpu_enabled: false/nvidia_gpu_enabled: true/' \
    ../inventory/mycluster/group_vars/all.yaml
  sed -i 's/nvidia_runtime_enabled: false/nvidia_runtime_enabled: true/' \
    ../inventory/mycluster/group_vars/all.yaml
fi

cd ../../..

# Post-K8s setup (ArgoCD, Argo Workflows, DNS patches)
ansible-playbook -i ansible/inventory.yml \
  ansible/post_k8s/post_k8s_configure.yml \
  -e "jump_host=$FLOATING_IP"

# Wait for Kubernetes to stabilize
sleep 30
```

#### Step 3: Fetch Kubeconfig

```bash
# SSH tunnel setup (run in background)
ssh -i ~/.ssh/id_rsa_chameleon \
  -L 6443:127.0.0.1:6443 \
  -N cc@$FLOATING_IP &

# Export kubeconfig
export KUBECONFIG=/tmp/navidrome-kubeconfig
ssh -i ~/.ssh/id_rsa_chameleon cc@$FLOATING_IP "cat ~/.kube/config" > $KUBECONFIG

# Verify cluster access
kubectl cluster-info
kubectl get nodes
```

---

### Phase 4: Create Secrets (Never in Git)

```bash
# Create namespace and secrets
kubectl create namespace navidrome-platform

# PostgreSQL credentials (choose your own passwords!)
kubectl create secret generic postgres-credentials \
  -n navidrome-platform \
  --from-literal=username=postgres \
  --from-literal=password=<postgres-password> \
  --from-literal=dbname=mlflow \
  --from-literal=navidrome_dbname=navidrome

# MinIO credentials
kubectl create secret generic minio-credentials \
  -n navidrome-platform \
  --from-literal=accesskey=minioadmin \
  --from-literal=secretkey=<minio-password>

# Verify
kubectl get secrets -n navidrome-platform
```

---

### Phase 5: Deploy Platform Services

```bash
# Create namespace and deploy
kubectl create namespace navidrome-monitoring

# Install platform Helm chart (Navidrome, MLflow, PostgreSQL, MinIO)
helm install navidrome-platform ./k8s/platform \
  --namespace navidrome-platform \
  --set navidrome.externalIP=$INTERNAL_IP \
  --set minio.externalIP=$INTERNAL_IP \
  --set mlflow.externalIP=$INTERNAL_IP \
  --set gateway.externalIP=$INTERNAL_IP

# Wait for all pods to be ready
kubectl wait --for=condition=Ready pod \
  --all -n navidrome-platform \
  --timeout=300s

# Check status
kubectl get pods -n navidrome-platform
```

---

### Phase 6: Deploy Monitoring Stack

```bash
# Install Prometheus + Grafana + Alertmanager
helm install navidrome-monitoring ./k8s/monitoring \
  --namespace navidrome-monitoring \
  --set prometheus.externalIP=$INTERNAL_IP \
  --set grafana.externalIP=$INTERNAL_IP \
  --set alertmanager.externalIP=$INTERNAL_IP

# Wait for monitoring pods
kubectl wait --for=condition=Ready pod \
  --all -n navidrome-monitoring \
  --timeout=300s

# Verify
kubectl get pods -n navidrome-monitoring
```

---

### Phase 7: Setup GPU (if applicable)

```bash
# If GPU_RESERVATION_ID was set:
if [ ! -z "$GPU_RESERVATION_ID" ]; then
  # Label GPU node
  kubectl label nodes node3 gpu=true --overwrite
  
  # Install NVIDIA device plugin
  kubectl apply -f k8s/monitoring/templates/nvidia-device-plugin.yaml
  
  # Wait for plugin to start
  sleep 10
  
  # Verify GPUs are visible to Kubernetes
  kubectl describe nodes node3 | grep -A 5 "Allocatable"
  # Should show: nvidia.com/gpu: 1
fi
```

---

### Phase 8: Deploy ML Workflows

```bash
# Create workflow namespace
kubectl create namespace argo

# Apply Argo WorkflowTemplates (train, serve, promote)
kubectl apply -f workflows/train-model.yaml -n argo
kubectl apply -f workflows/train-gpu.yaml -n argo
kubectl apply -f workflows/build-container-image.yaml -n argo
kubectl apply -f workflows/test-staging.yaml -n argo
kubectl apply -f workflows/promote-model.yaml -n argo

# If using GPU inference:
if [ ! -z "$GPU_RESERVATION_ID" ]; then
  kubectl apply -f workflows/inference-gpu.yaml -n argo
fi

# Verify
kubectl get workflowtemplates -n argo
```

---

## Verification

### 1. Check All Services Running

```bash
kubectl get pods -A

# Expected output:
# navidrome-platform    navidrome-xxx              Running
# navidrome-platform    mlflow-xxx                 Running
# navidrome-platform    postgres-xxx               Running
# navidrome-platform    minio-xxx                  Running
# navidrome-monitoring  prometheus-xxx             Running
# navidrome-monitoring  grafana-xxx                Running
# navidrome-monitoring  alertmanager-xxx           Running
# argo                  <argo-server-running>      Running
# argocd                <argocd-pods-running>      Running
```

### 2. Check Persistent Volumes

```bash
kubectl get pvc -A

# Expected: All claims should be BOUND
```

### 3. Access Services

| Service | URL | Credentials |
|---------|-----|---|
| Navidrome | `http://$INTERNAL_IP:4533` | Create user in UI |
| MLflow | `http://$INTERNAL_IP:8000` | No auth |
| MinIO | `http://$INTERNAL_IP:9001` | minioadmin / <password> |
| Prometheus | `http://$INTERNAL_IP:9090` | No auth |
| Grafana | `http://$INTERNAL_IP:3000` | admin / admin |
| Alertmanager | `http://$INTERNAL_IP:9093` | No auth |

### 4. Test End-to-End Workflow

```bash
# Submit a training job (triggers: train → build → test → promote)
argo submit -n argo --from workflowtemplate/train-model

# Watch progress
argo logs -n argo <workflow-name> -f

# Check MLflow for run
# Visit http://$INTERNAL_IP:8000 → Experiments → review runs
```

---

## Troubleshooting

### Pods stuck in Pending

```bash
# Check events
kubectl describe pod <pod-name> -n <namespace>

# Common causes:
# - Insufficient resources: kubectl top nodes
# - PVC not bound: kubectl get pvc -A
# - Image pull errors: kubectl logs <pod> --previous

# Solution: kubectl delete pod <pod> -n <namespace>  # Auto-restart
```

### Helm install fails

```bash
# Check helm chart syntax
helm lint ./k8s/platform
helm lint ./k8s/monitoring

# Dry-run to see what will be installed
helm install navidrome-platform ./k8s/platform --dry-run --debug
```

### GPU not detected

```bash
# Verify NVIDIA driver installed on node3
ssh -i ~/.ssh/id_rsa_chameleon cc@$FLOATING_IP
ssh -J cc@192.168.1.11 cc@192.168.1.13
nvidia-smi  # Should show V100 GPU

# If fails, re-run Ansible with nvidia_gpu_enabled: true
```

### Monitoring not scraping metrics

```bash
# Check Prometheus config
kubectl exec -it prometheus-xxx -n navidrome-monitoring -- cat /etc/prometheus/prometheus.yml

# Check targets
# Visit http://$INTERNAL_IP:9090 → Targets → check health

# Re-apply ServiceMonitors if needed
kubectl apply -f k8s/monitoring/templates/
```

---

## Cleanup & Cost Control

### Keep Cluster Alive Only While Testing

```bash
# To stop (pause lease on Chameleon):
# Chameleon UI → Leases → Suspend
# Costs freeze while suspended

# To destroy (permanent deletion):
terraform -chdir=tf/kvm destroy
# This deletes all VMs and floating IPs
```

### Long-Term Cost Optimization

- **Use spot instances** (if available) — cheaper than on-demand
- **Right-size resources:** Monitor `kubectl top pods` and adjust requests/limits
- **Use node affinity** to pack workloads on fewer nodes
- **Scheduled shutdown** for non-critical times (CronJob + kubectl drain)

---

## Next Steps (After Deployment)

1. **Load sample music data** into Navidrome
   ```bash
   # Via kubectl cp (for small datasets)
   kubectl cp /local/music/ navidrome-platform/navidrome-xxx:/music/
   
   # Or via MinIO (for larger datasets)
   # Upload to MinIO bucket via console
   ```

2. **Configure Last.fm / Spotify** (optional integrations)
   ```bash
   # Get API keys, then:
   helm upgrade navidrome-platform ./k8s/platform \
     --set navidrome.lastfmApiKey=<key> \
     --set navidrome.spotifyClientId=<id>
   ```

3. **Setup custom Grafana dashboards** for your metrics
   - Import community dashboards or create custom ones
   - Configure alerts for your SLOs

4. **Document your safeguarding plan**
   - See `docs/SAFEGUARDING.md` for framework
   - Fill in your specific metrics and thresholds

5. **Record demo videos** for submission
   - Show services running: `kubectl get pods`
   - Show Navidrome/MLflow/Grafana in browser
   - Show model training via Argo Workflows

---

## Support

- **Issues:** Open GitHub issue in `navidrome-iac` repo
- **Slack:** Tag @devops or @ml-team
- **Runbooks:** See `docs/RUNBOOK.md` for operations

---

**Last Updated:** April 2026  
**Deployed By:** DevOps Team  
**For:** ECE-GY 9183 MLOps Capstone
