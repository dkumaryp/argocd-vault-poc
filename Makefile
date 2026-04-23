# ArgoCD Vault Plugin POC — Makefile helper
# Usage: make <target>
# Override variables as needed, e.g.:
#   CLUSTER_VAULT_ADDR=http://172.18.0.1:8200 CLUSTER_K8S_HOST=https://172.18.0.2:6443 make vault-setup

VAULT_ADDR        ?= http://localhost:8200
ARGOCD_NS         ?= argocd
ARGOCD_VER        ?= v2.10.0

# kind: get gateway IP dynamically (host IP as seen from pods)
KIND_GW           := $(shell docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
# kind: get control-plane container IP (K8s API reachable from Vault Docker container)
KIND_CP_IP        := $(shell docker inspect kind-control-plane -f '{{.NetworkSettings.Networks.kind.IPAddress}}' 2>/dev/null)

CLUSTER_VAULT_ADDR ?= http://$(KIND_GW):8200
CLUSTER_K8S_HOST   ?= https://$(KIND_CP_IP):6443

.PHONY: help vault-dev vault-start vault-init vault-setup \
        argocd-install argocd-avp-patch argocd-secret argocd-port-forward \
        demo-deploy demo-verify clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# ── Vault ────────────────────────────────────────────────────────────────────

vault-dev: ## Start Vault in DEV mode (quick start, data lost on restart)
	cd vault && docker compose -f docker-compose.dev.yml up -d
	@echo "Vault UI: http://localhost:8200  |  Token: root"

vault-kind-network: ## Connect Vault container to kind network (required for K8s auth)
	docker network connect kind vault-poc-dev 2>/dev/null || \
	docker network connect kind vault-poc 2>/dev/null || \
	echo "Already connected or container not running"
	@echo "Kind gateway (CLUSTER_VAULT_ADDR host): $(KIND_GW)"
	@echo "Kind control-plane (CLUSTER_K8S_HOST host): $(KIND_CP_IP)"

vault-start: ## Start Vault in production-like mode (file storage)
	cd vault && docker compose up -d
	@echo "Vault started. Run 'make vault-init' if first time."

vault-init: ## Initialize Vault (prod mode only, run once)
	bash vault/scripts/01-init-vault.sh

vault-setup: ## Configure Vault secrets, policy, Kubernetes auth
	VAULT_ADDR=$(VAULT_ADDR) CLUSTER_K8S_HOST=$(CLUSTER_K8S_HOST) bash vault/scripts/02-setup-vault.sh

vault-stop: ## Stop Vault container
	cd vault && docker compose down || docker compose -f docker-compose.dev.yml down

# ── ArgoCD ───────────────────────────────────────────────────────────────────

argocd-install: ## Install ArgoCD into cluster
	kubectl apply -f argocd/install/namespace.yaml
	kubectl apply -n $(ARGOCD_NS) \
	  -f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VER)/manifests/install.yaml
	@echo "Waiting for ArgoCD to be ready..."
	kubectl rollout status deployment/argocd-server -n $(ARGOCD_NS) --timeout=180s

argocd-avp-configure: ## Apply CMP ConfigMap and patch repo-server with AVP sidecar
	kubectl apply -f argocd/install/vault-reviewer-sa.yaml
	kubectl apply -f argocd/plugins/cmp-plugin-configmap.yaml
	kubectl patch deployment argocd-repo-server -n $(ARGOCD_NS) \
	  --patch-file argocd/patches/argocd-repo-server-patch.yaml
	kubectl rollout status deployment/argocd-repo-server -n $(ARGOCD_NS) --timeout=180s

argocd-secret: ## Create AVP credentials secret (Kubernetes auth — no static creds)
	kubectl create secret generic argocd-vault-plugin-credentials \
	  --namespace $(ARGOCD_NS) \
	  --from-literal=VAULT_ADDR=$(CLUSTER_VAULT_ADDR) \
	  --from-literal=AVP_TYPE=vault \
	  --from-literal=AVP_AUTH_TYPE=k8s \
	  --from-literal=AVP_K8S_ROLE=argocd-role \
	  --dry-run=client -o yaml | kubectl apply -f -

argocd-password: ## Get initial ArgoCD admin password
	@kubectl get secret argocd-initial-admin-secret -n $(ARGOCD_NS) \
	  -o jsonpath="{.data.password}" | base64 -d && echo

argocd-port-forward: ## Port-forward ArgoCD UI to localhost:8080
	kubectl port-forward svc/argocd-server -n $(ARGOCD_NS) 8080:443

# ── Demo App ─────────────────────────────────────────────────────────────────

demo-deploy: ## Deploy demo app via ArgoCD Application manifest
	kubectl apply -f argocd/apps/demo-secret-app.yaml

demo-verify: ## Verify secrets were injected into the demo pod
	@echo "==> Secret values in Kubernetes:"
	kubectl get secret demo-secret -n demo -o jsonpath='{.data}' | \
	  python3 -c "import sys,json,base64; \
	    d=json.load(sys.stdin); \
	    [print(f'  {k}: {base64.b64decode(v).decode()}') for k,v in d.items()]"

# ── Cleanup ──────────────────────────────────────────────────────────────────

clean: ## Remove ArgoCD app and demo namespace
	kubectl delete -f argocd/apps/demo-secret-app.yaml --ignore-not-found
	kubectl delete namespace demo --ignore-not-found
	kubectl delete secret argocd-vault-plugin-credentials -n $(ARGOCD_NS) --ignore-not-found
