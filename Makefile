RESERVATION_ID ?= $(error Set RESERVATION_ID: make <target> RESERVATION_ID=<uuid>)
GPU_RESERVATION_ID ?=  # Optional: GPU reservation ID for GPU nodes
KUBESPRAY_DIR  := ansible/k8s/kubespray
VENV           := $(KUBESPRAY_DIR)/kubespray-venv
VENV_ANSIBLE   := $(VENV)/bin/ansible-playbook
KUBECONFIG     := /tmp/navidrome-kubeconfig

# Derive IPs from Terraform output (after apply)
FLOATING_IP    := $(shell terraform -chdir=tf/kvm output -raw floating_ip_out 2>/dev/null)
INTERNAL_IP    := $(shell terraform -chdir=tf/kvm output -raw node1_internal_ip_out 2>/dev/null)

.PHONY: all infra pre-k8s k8s post-k8s kubeconfig helm-install helm-upgrade deploy wait-ssh monitoring gpu-plugin

## Full deploy from scratch (with monitoring and optional GPU)
all: infra pre-k8s k8s post-k8s kubeconfig helm-install monitoring

## 1. Provision VM + floating IP + security group rules on KVM@TACC
infra:
	terraform -chdir=tf/kvm init -upgrade
	@if [ -z "$(GPU_RESERVATION_ID)" ]; then \
		echo "Deploying CPU-only cluster"; \
		terraform -chdir=tf/kvm apply -auto-approve \
			-var="reservation_id=$(RESERVATION_ID)" \
			-var="gpu_reservation_id="; \
	else \
		echo "Deploying CPU + GPU cluster"; \
		terraform -chdir=tf/kvm apply -auto-approve \
			-var="reservation_id=$(RESERVATION_ID)" \
			-var="gpu_reservation_id=$(GPU_RESERVATION_ID)" \
			-var="gpu_nodes={node3=\"192.168.1.13\"}"; \
	fi

## 2. Pre-K8s: disable firewalld, configure Docker registry
pre-k8s: wait-ssh
	ansible-playbook -i ansible/inventory.yml ansible/pre_k8s/pre_k8s_configure.yml \
		-e "jump_host=$(FLOATING_IP)"

## 3. Install Kubernetes via kubespray (uses pinned ansible in venv)
k8s: $(VENV_ANSIBLE)
	cd $(KUBESPRAY_DIR) && $(abspath $(VENV_ANSIBLE)) \
		-i ../inventory/mycluster/hosts.yaml cluster.yml \
		-e "jump_host=$(FLOATING_IP)"

## 4. Post-K8s: kubectl, ArgoCD, Argo Workflows
post-k8s: wait-ssh
	ansible-playbook -i ansible/inventory.yml ansible/post_k8s/post_k8s_configure.yml \
		-e "jump_host=$(FLOATING_IP)"

## 5. Fetch kubeconfig from node and patch to use tunnel
kubeconfig:
	ssh -i ~/.ssh/id_rsa_chameleon -o StrictHostKeyChecking=no cc@$(FLOATING_IP) \
		"cat ~/.kube/config" > $(KUBECONFIG)
	@echo "Kubeconfig saved to $(KUBECONFIG)"
	@echo "Start SSH tunnel before using helm/kubectl locally:"
	@echo "  ssh -i ~/.ssh/id_rsa_chameleon -L 6443:127.0.0.1:6443 -N cc@$(FLOATING_IP) &"

## 6. Install platform Helm chart
helm-install:
	KUBECONFIG=$(KUBECONFIG) helm install navidrome-platform ./k8s/platform \
		--namespace navidrome-platform \
		--create-namespace \
		--set navidrome.externalIP=$(INTERNAL_IP) \
		--set minio.externalIP=$(INTERNAL_IP) \
		--set mlflow.externalIP=$(INTERNAL_IP) \
		--set gateway.externalIP=$(INTERNAL_IP)

## 6b. Install monitoring stack (Prometheus + Grafana + Alertmanager)
monitoring:
	KUBECONFIG=$(KUBECONFIG) helm install navidrome-monitoring ./k8s/monitoring \
		--namespace navidrome-monitoring \
		--create-namespace \
		--set prometheus.externalIP=$(INTERNAL_IP) \
		--set grafana.externalIP=$(INTERNAL_IP) \
		--set alertmanager.externalIP=$(INTERNAL_IP)
	@echo "✓ Monitoring stack deployed"
	@echo "  Prometheus: http://$(INTERNAL_IP):9090"
	@echo "  Grafana: http://$(INTERNAL_IP):3000 (admin/admin)"
	@echo "  Alertmanager: http://$(INTERNAL_IP):9093"

## 6c. Install NVIDIA GPU device plugin (only if GPU nodes present)
gpu-plugin:
	KUBECONFIG=$(KUBECONFIG) kubectl apply -f k8s/monitoring/templates/nvidia-device-plugin.yaml
	@echo "✓ GPU device plugin deployed"
	@sleep 5
	@echo "Waiting for GPU metrics to appear..."
	@KUBECONFIG=$(KUBECONFIG) kubectl wait --for=condition=Ready pod -l name=nvidia-device-plugin-ds -n kube-system --timeout=60s || true
	@echo "GPU nodes detected:"
	@KUBECONFIG=$(KUBECONFIG) kubectl get nodes -L nvidia.com/gpu || echo "(No GPU nodes)"

## Upgrade platform Helm chart (use after config changes)
helm-upgrade:
	KUBECONFIG=$(KUBECONFIG) helm upgrade navidrome-platform ./k8s/platform \
		--namespace navidrome-platform \
		--set navidrome.externalIP=$(INTERNAL_IP) \
		--set minio.externalIP=$(INTERNAL_IP) \
		--set mlflow.externalIP=$(INTERNAL_IP) \
		--set gateway.externalIP=$(INTERNAL_IP)

## Upgrade monitoring stack
monitoring-upgrade:
	KUBECONFIG=$(KUBECONFIG) helm upgrade navidrome-monitoring ./k8s/monitoring \
		--namespace navidrome-monitoring \
		--set prometheus.externalIP=$(INTERNAL_IP) \
		--set grafana.externalIP=$(INTERNAL_IP) \
		--set alertmanager.externalIP=$(INTERNAL_IP)

## Create kubespray venv with pinned ansible version
$(VENV_ANSIBLE):
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q -r $(KUBESPRAY_DIR)/requirements.txt

## Wait for SSH to be ready (handles post-kubespray reboot)
wait-ssh:
	@echo "Waiting for SSH on $(FLOATING_IP)..."
	@until ssh -i ~/.ssh/id_rsa_chameleon -o StrictHostKeyChecking=no \
		-o ConnectTimeout=5 cc@$(FLOATING_IP) true 2>/dev/null; do \
		sleep 5; \
	done
	@echo "SSH ready."

## Label GPU nodes and install device plugin
setup-gpu:
	@echo "Labeling GPU nodes..."
	@KUBECONFIG=$(KUBECONFIG) kubectl get nodes -o name | grep node3 | xargs -I {} kubectl label {} gpu=true --overwrite 2>/dev/null || echo "No GPU nodes found (expected if GPU_RESERVATION_ID not set)"
	@echo "Installing NVIDIA device plugin..."
	@$(MAKE) gpu-plugin

## Verify cluster health
verify:
	@echo "Cluster status:"
	@KUBECONFIG=$(KUBECONFIG) kubectl get nodes
	@echo "\nPlatform services:"
	@KUBECONFIG=$(KUBECONFIG) kubectl get pods -n navidrome-platform
	@echo "\nMonitoring stack:"
	@KUBECONFIG=$(KUBECONFIG) kubectl get pods -n navidrome-monitoring || echo "(monitoring not yet deployed)"
	@echo "\nExternal IPs:"
	@echo "  Node1 (control-plane): $(INTERNAL_IP)"
	@echo "  Floating IP: $(FLOATING_IP)"
