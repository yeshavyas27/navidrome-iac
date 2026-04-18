# Your Action Plan — What to Do Now

## Quick Summary

You have everything you need. Here's exactly what to do:

1. **Reserve control-plane node** on Chameleon (10 min)
   - m1.xlarge at KVM@TACC
   - 7 days duration
   - Get Reservation ID

2. **Get security group IDs** (5 min)
   - default, allow-ssh, navidrome-sg-proj05

3. **Deploy everything** (90 min automated)
   - Run: `make all RESERVATION_ID=<your-id>`
   - System fully deployed in 90 minutes

4. **Access services** (1 min)
   - Navidrome: http://floating-ip:4533
   - MLflow: http://floating-ip:8000
   - Prometheus: http://floating-ip:9090
   - Grafana: http://floating-ip:3000

---

## Step-by-Step

### Step 1: Create Control-Plane Lease (10 min)

Go to: https://chi.tacc.chameleoncloud.org/

Navigate: **Leases** → **Create Lease**

Fill in:
```
Lease Name:       navidrome-control-plane-proj05
Resource Type:    Compute (KVM)
Location:         TACC (KVM@TACC)
Flavor:           m1.xlarge
Node Count:       1
Start Time:       Now
Duration:         7 days (until Apr 27+)
→ Click "Create Lease"
```

**Status will become ACTIVE** in ~1-2 minutes

**Copy the Reservation ID** (UUID like `12345678-1234-1234-1234-123456`)

### Step 2: Get Security Group IDs (5 min)

In Chameleon UI: **Network** → **Security Groups**

Find these groups and copy their IDs:
- `default`
- `allow-ssh` (create if missing: inbound SSH port 22)
- `navidrome-sg-proj05` (create if missing: inbound ports 4533, 8000, 9000, 9001, 3000, 9090, 9093)

### Step 3: Set Environment Variables (2 min)

In your terminal:
```bash
export CONTROL_PLANE_RESERVATION_ID="<paste-reservation-id>"
export SG_DEFAULT_ID="<paste-default-sg-id>"
export SG_SSH_ID="<paste-allow-ssh-sg-id>"
export SG_NAVIDROME_ID="<paste-navidrome-sg-proj05-sg-id>"
```

### Step 4: Create terraform.tfvars (2 min)

```bash
cd ~/Desktop/go-workspace/src/navidrome-iac

cat > tf/kvm/terraform.tfvars <<EOF
reservation_id = "$CONTROL_PLANE_RESERVATION_ID"
gpu_reservation_id = ""
sg_default_id = "$SG_DEFAULT_ID"
sg_ssh_id = "$SG_SSH_ID"
sg_navidrome_id = "$SG_NAVIDROME_ID"
EOF
```

### Step 5: Deploy Everything (90 min automated)

```bash
make all RESERVATION_ID=$CONTROL_PLANE_RESERVATION_ID
```

**What happens (automated):**
1. Terraform: Creates VM, networks, floating IP (5 min)
2. Ansible pre-k8s: Node setup (5 min)
3. Kubespray: Kubernetes install (30-40 min) ☕
4. Ansible post-k8s: ArgoCD, Argo setup (5 min)
5. Helm platform: Services deployed (5 min)
6. Helm monitoring: Monitoring stack (5 min)

**Just wait. Everything is automated.**

### Step 6: Get IPs and Verify (5 min)

```bash
export FLOATING_IP=$(terraform -chdir=tf/kvm output -raw floating_ip_out)
export INTERNAL_IP=$(terraform -chdir=tf/kvm output -raw node1_internal_ip_out)

echo "External IP: $FLOATING_IP"
echo "Internal IP: $INTERNAL_IP"

# Verify all services running
kubectl get pods -a
# Should show 20+ pods in Running status
```

### Step 7: Access Services (1 min)

Open in browser:
- **Navidrome:** http://<FLOATING_IP>:4533
- **MLflow:** http://<FLOATING_IP>:8000
- **Prometheus:** http://<FLOATING_IP>:9090
- **Grafana:** http://<FLOATING_IP>:3000 (admin/admin)

### Step 8: Test Redis (30 seconds)

```bash
kubectl exec -it redis-xxx -n navidrome-platform -- redis-cli PING
# Response: PONG ✅
```

---

## Done! ✅

Your system is running with:
- ✅ Kubernetes cluster
- ✅ Navidrome music server
- ✅ MLflow model registry
- ✅ PostgreSQL database
- ✅ MinIO object storage
- ✅ Redis cache (sessions, embeddings, counters)
- ✅ Prometheus + Grafana monitoring
- ✅ Argo Workflows (ML pipeline automation)

---

## Next Steps

**For Integration:**
- Read: `docs/REDIS_INTEGRATION_EXAMPLES.md`
- Copy code examples into your services
- Test cache hit rates

**For GPU Training (Later):**
- Create gpu_v100 lease when ready to train
- Run: `make setup-gpu`
- Submit training: `argo submit -n argo --from workflowtemplate/train-model-gpu`
- Delete GPU lease when done (save costs)

**For Monitoring:**
- Access Prometheus: http://floating-ip:9090
- Search for: `redis_`, `container_`, `node_` metrics
- Set up alerts in Alertmanager

---

## Cost

| Phase | Duration | Cost |
|-------|----------|------|
| Control-plane (m1.xlarge) | 7 days | ~$15-20 |
| GPU training (optional) | 2-3 days | ~$10-15 |
| Total for 4 weeks | Continuous + occasional | ~$80-120 |

**Cost-saving tip:** Only reserve GPU when actively training. Delete lease immediately after.

---

## Troubleshooting

**Terraform errors (missing SG IDs)?**
- Double-check security group IDs from Chameleon UI
- Ensure they're correct in terraform.tfvars

**Lease not available?**
- Try different site (KVM@CHI)
- Wait 30 min and retry
- Reduce to 1 node

**Services not running?**
- Check: `kubectl get pods -n navidrome-platform`
- Check logs: `kubectl logs <pod-name> -n navidrome-platform`

**Can't access services?**
- Check floating IP attached: `openstack server list | grep node1`
- Check security group rules allow traffic
- Wait 2-3 min for services to fully start

---

## Summary

| Item | What to Do | Time |
|------|-----------|------|
| Create lease | m1.xlarge, 7 days, KVM@TACC | 10 min |
| Get IDs | Reservation ID + security group IDs | 5 min |
| Environment | Export variables | 2 min |
| Deploy | `make all RESERVATION_ID=...` | 90 min |
| Verify | Access services in browser | 1 min |
| **Total** | **From scratch to running system** | **~108 min** |

---

## All Documentation

- `QUICKSTART.md` — 30-second overview
- `DEPLOYMENT.md` — Complete deployment guide
- `CHAMELEON_SETUP.md` — What to reserve (detailed version of this)
- `docs/REDIS.md` — Redis usage guide
- `docs/REDIS_INTEGRATION_EXAMPLES.md` — Code examples
- `docs/NETWORK_ARCHITECTURE.md` — How services connect
- `docs/SAFEGUARDING.md` — Fairness, privacy, safety
- `README.md` — Project overview

---

**You're ready! Follow the steps above and you'll have a full MLOps system running in 2 hours. 🚀**
