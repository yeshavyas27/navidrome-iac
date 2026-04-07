# navidrome-iac Tasks

## Deadline: Apr 6 (Initial Implementation) — IN PROGRESS
## Next: Apr 20 (System Implementation)

---

## Phase 1: Infrastructure (DONE)

- [x] KVM@TACC lease created (`navidrome-proj05`, 1x m1.large)
- [x] Terraform — single node + floating IP + security group rules
- [x] Ansible pre-k8s — firewalld disabled, Docker registry configured
- [x] Kubespray — single-node K8s cluster (v1.30.4)
- [x] Ansible post-k8s — kubectl, ArgoCD, Argo Workflows, Argo Events
- [x] Makefile — full deploy automation (`make all RESERVATION_ID=...`)

## Phase 2: Platform Services (DONE)

- [x] Helm chart — Navidrome + MLflow + PostgreSQL + MinIO
- [x] PVCs — persistent storage via local-path-provisioner
- [x] Secrets — postgres-credentials, minio-credentials (not in Git)
- [x] All services reachable via floating IP:
  - Navidrome:     http://<FLOATING_IP>:4533
  - MLflow:        http://<FLOATING_IP>:8000
  - MinIO console: http://<FLOATING_IP>:9001

## Phase 3: K8s Extensions Installed (via kubespray group_vars)

- [x] ArgoCD — GitOps CD (namespace: argocd)
- [x] Argo Workflows — ML pipeline orchestration (namespace: argo)
- [x] Argo Events — event-driven triggers (namespace: argo-events)
- [x] local-path-provisioner — PVC storage on single node
- [x] metrics-server — `kubectl top pods` for resource usage
- [x] Kubernetes Dashboard — cluster UI
- [x] Helm — package manager
- [x] Internal Docker registry — kube-system

---

## Remaining: Initial Implementation (Due Apr 6)

- [ ] Push `navidrome-iac` to GitHub (private repo)
- [ ] Infrastructure requirements table (run `kubectl top pods`, screenshot)
- [ ] Demo video #1 — Navidrome running in K8s on Chameleon
- [ ] Demo video #2 — Platform services (MLflow, MinIO, PG) running in K8s
- [ ] Verify PVC persistence (delete pod → restart → data survives)
- [ ] Joint: agree JSON input/output sample with team
- [ ] Joint: container table (all roles, Dockerfile + manifest links)

---

## Extras (Post Apr 6 — System Implementation Apr 20)

### Domain + HTTPS (bonus points)
- [ ] Register free subdomain (DuckDNS)
- [ ] Deploy cert-manager + nginx ingress
- [ ] Let's Encrypt TLS certificate

### Music Library
- [ ] Add init job to Helm chart to pre-load CC-licensed sample tracks
- [ ] Document how to add music via `kubectl cp`

### Navidrome Integrations (all built-in, just need API keys)
- [ ] Last.fm — artist bio, album art, scrobbling (free API key)
- [ ] Spotify — artist images (free developer app)
- [ ] Set via `--set navidrome.lastfmApiKey=... --set navidrome.spotifyClientId=...`
- Already wired into Helm chart values (conditional, skipped if empty)

### OAuth2 / Google Login (bonus)
- [ ] Deploy oauth2-proxy in front of Navidrome
- [ ] Configure Google OAuth2 credentials
- [ ] Note: Navidrome accounts still need pre-creation by admin

### Monitoring (bonus)
- [ ] Loki (logging) or Trivy (image scanning) — pick one for bonus credit

---

## Notes

- Lease expires: **Apr 9** — renew or re-provision before showcase
- Security group rules (4533, 8000, 9000, 9001) in `navidrome-sg-proj05`
- `externalIP` must be node's internal sharednet1 IP (not floating IP)
- Secrets never in Git — apply with `kubectl create secret` after provisioning
- Floating IP changes on re-provision — update `FLOATING_IP` export
