# navidrome-iac

Infrastructure-as-code for the Navidrome MLOps course project (ECE-GY 9183).

**Apr 20 System Implementation:** Complete production-ready ML platform with multi-node Kubernetes, monitoring (Prometheus/Grafana), autoscaling (HPA), GPU support, and comprehensive safeguarding mechanisms.

Provisions a **multi-node Kubernetes cluster** on Chameleon Cloud (KVM@TACC) and deploys:
- 🎵 **Navidrome** — music server with recommendation engine
- 🤖 **MLflow** — model registry & experiment tracking
- 🗄️ **PostgreSQL** — backend database
- 📦 **MinIO** — S3-compatible object storage
- 📊 **Prometheus + Grafana + Alertmanager** — monitoring stack
- 📈 **HPA** — autoscaling for MLflow & Navidrome
- 🖥️ **NVIDIA GPU support** — optional GPU node for training/inference

---

## Getting Started

### 🚀 Quick Start (30 min read, 90 min deploy)
→ **[QUICKSTART.md](QUICKSTART.md)** — TL;DR deployment guide with all steps

### 📋 Full Deployment Guide  
→ **[DEPLOYMENT.md](DEPLOYMENT.md)** — Phase-by-phase walkthrough with troubleshooting

### 🛡️ Safeguarding Plan
→ **[docs/SAFEGUARDING.md](docs/SAFEGUARDING.md)** — Fairness, explainability, privacy, accountability, robustness mechanisms

### 📝 Latest Updates (Apr 20)
→ **[UPDATES_APR20.md](UPDATES_APR20.md)** — Summary of all changes for system implementation

---

## Repo Layout

```
tf/kvm/                 Terraform — multi-node VMs, networks, floating IP, security groups
ansible/
  pre_k8s/              Node prep (firewalld, Docker registry)
  k8s/kubespray/        Kubespray submodule — Kubernetes install
  k8s/inventory/        Kubespray inventory (multi-node cluster)
  post_k8s/             Post-install (kubectl, ArgoCD, Argo Workflows/Events)
k8s/
  platform/             Helm chart — Navidrome, MLflow, PostgreSQL, MinIO, HPA
  monitoring/           Helm chart — Prometheus, Grafana, Alertmanager, NVIDIA plugin
  staging/              Staging env deployment
  canary/               Canary env deployment
  production/           Production env deployment
workflows/              Argo WorkflowTemplates (train, serve, promote, GPU jobs)
docs/                   ARCHITECTURE.md, SAFEGUARDING.md
Makefile                Full deploy automation (terraform, ansible, helm, monitoring, GPU)
```

---

## Prerequisites

```bash
# Install dependencies
brew install terraform ansible helm

# OpenStack credentials for KVM@TACC
# Place your clouds.yaml at ~/.config/openstack/clouds.yaml

# SSH key registered on Chameleon
# Default expected at ~/.ssh/id_rsa_chameleon
```

---

## Deploy

**TL;DR:**
```bash
# 1. Get Blazar lease IDs
export RESERVATION_ID="<cpu-lease-uuid>"
export GPU_RESERVATION_ID="<gpu-lease-uuid>"  # optional

# 2. Deploy entire system (takes ~90 min)
make all RESERVATION_ID=$RESERVATION_ID GPU_RESERVATION_ID=$GPU_RESERVATION_ID

# 3. Export IPs and verify
export FLOATING_IP=$(terraform -chdir=tf/kvm output -raw floating_ip_out)
kubectl cluster-info
kubectl get pods -A
```

**Full instructions:** See [DEPLOYMENT.md](DEPLOYMENT.md) or [QUICKSTART.md](QUICKSTART.md)

After deploy, services are available at:

| Service | URL | Purpose |
|---------|-----|---------|
| Navidrome | `http://$INTERNAL_IP:4533` | 🎵 Music server + recommendations |
| MLflow | `http://$INTERNAL_IP:8000` | 🤖 Model registry & tracking |
| MinIO | `http://$INTERNAL_IP:9001` | 📦 S3-compatible object storage |
| Prometheus | `http://$INTERNAL_IP:9090` | 📊 Metrics collection |
| Grafana | `http://$INTERNAL_IP:3000` | 📈 Dashboards (admin/admin) |
| Alertmanager | `http://$INTERNAL_IP:9093` | 🚨 Alert routing |

**GPU Support (optional):**
```bash
# If GPU_RESERVATION_ID set:
kubectl label nodes node3 gpu=true
make gpu-plugin

# Submit GPU training job:
argo submit -n argo --from workflowtemplate/train-model-gpu
```

---

## Security

- Secrets are never stored in Git — apply with `kubectl create secret` after provisioning
- All Chameleon resources are named with `-proj05` suffix as required by course policy

---

## AI Disclosure

Infrastructure code and configurations in this repository were developed with assistance
from Claude (Anthropic) as an implementation tool. All design decisions, architecture
choices, and tradeoffs were made by the author. AI assistance was used to accelerate
implementation of IaC patterns (Terraform, Ansible, Helm, Kubernetes manifests) based
on the author's specifications.

Per course policy: *"You tell the LLM what to do, based on the design you developed."*

AI-assisted files are noted in [.claude/](.claude/).
