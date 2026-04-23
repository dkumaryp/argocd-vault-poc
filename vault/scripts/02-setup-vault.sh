#!/usr/bin/env bash
# =============================================================================
# 02-setup-vault.sh
# Unseal Vault and configure:
#   - KV v2 secrets engine
#   - Demo secrets
#   - Kubernetes auth method (no static credentials — uses pod SA tokens)
#   - Policy for ArgoCD
#
# Auth flow:
#   AVP pod → presents its own SA JWT → Vault calls K8s TokenReview API
#   → K8s confirms SA identity → Vault issues short-lived token
#
# Prerequisites:
#   - vault-reviewer SA deployed: kubectl apply -f argocd/install/vault-reviewer-sa.yaml
#   - CLUSTER_K8S_HOST: K8s API URL reachable from Docker (e.g. https://host.minikube.internal:8443)
# =============================================================================
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
# K8s API server URL as reachable FROM the Vault Docker container
CLUSTER_K8S_HOST="${CLUSTER_K8S_HOST:-https://host.minikube.internal:8443}"

# ── Prompt for root token if not in env ───────────────────────────────────────
if [ -z "${VAULT_TOKEN:-}" ]; then
  read -rsp "Enter Vault Root Token: " VAULT_TOKEN
  echo ""
fi
export VAULT_TOKEN
export VAULT_ADDR

# ── Helper: vault CLI via Docker or local ────────────────────────────────────
vault_cmd() {
  if command -v vault &>/dev/null; then
    vault "$@"
  else
    docker exec -e VAULT_ADDR="$VAULT_ADDR" -e VAULT_TOKEN="$VAULT_TOKEN" vault-poc vault "$@"
  fi
}

echo ""
echo "==> [1/6] Unsealing Vault (prod mode only) ..."
STATUS=$(curl -sf "$VAULT_ADDR/v1/sys/seal-status" | python3 -c "import sys,json; print(json.load(sys.stdin)['sealed'])")
if [ "$STATUS" = "True" ]; then
  KEYS_FILE="$(dirname "$0")/../.vault-keys"
  if [ ! -f "$KEYS_FILE" ]; then
    echo "ERROR: .vault-keys file not found. Run 01-init-vault.sh first."
    exit 1
  fi
  echo "    Vault is sealed. Applying unseal keys..."
  grep "Key [1-3]:" "$KEYS_FILE" | awk '{print $NF}' | while read -r key; do
    curl -sf --request POST --data "{\"key\": \"$key\"}" "$VAULT_ADDR/v1/sys/unseal" | \
      python3 -c "import sys,json; d=json.load(sys.stdin); print(f'    Sealed: {d[\"sealed\"]}')"
  done
else
  echo "    Vault is already unsealed."
fi

echo ""
echo "==> [2/6] Enabling KV v2 secrets engine at 'secret/' ..."
vault_cmd secrets list -format=json | python3 -c "
import sys, json
engines = json.load(sys.stdin)
if 'secret/' in engines:
    print('    KV engine already enabled at secret/')
    exit(1)
" || vault_cmd secrets enable -path=secret kv-v2 && echo "    KV v2 enabled."

echo ""
echo "==> [3/6] Writing demo secrets ..."
vault_cmd kv put secret/demo-app \
  username="demo-user" \
  password="super-secret-password" \
  api-key="1234567890abcdef" \
  db-host="postgres.internal" \
  db-name="appdb"

echo "    Secrets written to secret/data/demo-app"

echo ""
echo "==> [4/6] Creating ArgoCD Vault policy ..."
vault_cmd policy write argocd-policy - <<'EOF'
# ArgoCD Vault Plugin - read-only access to app secrets
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF
echo "    Policy 'argocd-policy' created."

echo ""
echo "==> [5/6] Enabling Kubernetes auth and configuring it ..."

# Ensure vault-reviewer SA exists in the cluster
if ! kubectl get secret vault-reviewer-token -n argocd &>/dev/null; then
  echo "ERROR: vault-reviewer-token secret not found in argocd namespace."
  echo "       Run: kubectl apply -f argocd/install/vault-reviewer-sa.yaml"
  exit 1
fi

# Get the reviewer JWT — Vault uses this to call the K8s TokenReview API
REVIEWER_JWT=$(kubectl get secret vault-reviewer-token -n argocd \
  -o jsonpath='{.data.token}' | base64 -d)

# Get the cluster CA cert — Vault uses this to trust the K8s API TLS cert
K8S_CA_CERT=$(kubectl config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

vault_cmd auth list -format=json | python3 -c "
import sys, json
auths = json.load(sys.stdin)
if 'kubernetes/' in auths:
    print('    Kubernetes auth already enabled.')
    exit(1)
" || vault_cmd auth enable kubernetes && echo "    Kubernetes auth enabled."

# Configure Vault to talk to the K8s API server (outside-cluster Vault needs this)
vault_cmd write auth/kubernetes/config \
  kubernetes_host="$CLUSTER_K8S_HOST" \
  kubernetes_ca_cert="$K8S_CA_CERT" \
  token_reviewer_jwt="$REVIEWER_JWT" \
  disable_iss_validation=true

echo "    Kubernetes auth configured (host: $CLUSTER_K8S_HOST)"

# Create a Vault role that maps the argocd-repo-server ServiceAccount to argocd-policy.
# Any pod running as 'argocd-repo-server' SA in the 'argocd' namespace can authenticate.
vault_cmd write auth/kubernetes/role/argocd-role \
  bound_service_account_names="argocd-repo-server" \
  bound_service_account_namespaces="argocd" \
  policies="argocd-policy" \
  ttl=1h

echo "    Vault role 'argocd-role' created."
echo "    Bound to: SA=argocd-repo-server, namespace=argocd"

echo ""
echo "==> [6/6] Verifying setup ..."
vault_cmd read auth/kubernetes/role/argocd-role

echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo "  Vault Setup Complete! (Kubernetes auth — no static credentials)"
echo "══════════════════════════════════════════════════════════════════════"
echo ""
echo "  VAULT_ADDR        : $VAULT_ADDR"
echo "  Auth method       : Kubernetes (AVP uses pod SA token automatically)"
echo "  Vault role        : argocd-role"
echo "  Bound SA          : argocd-repo-server (argocd namespace)"
echo ""
echo "  Create the AVP credentials secret (only VAULT_ADDR + role name needed):"
echo "  ─────────────────────────────────────────────────────────────────────"
cat <<KUBE_SECRET

  kubectl create secret generic argocd-vault-plugin-credentials \\
    --namespace argocd \\
    --from-literal=VAULT_ADDR=<CLUSTER_VAULT_ADDR> \\
    --from-literal=AVP_TYPE=vault \\
    --from-literal=AVP_AUTH_TYPE=k8s \\
    --from-literal=AVP_K8S_ROLE=argocd-role

KUBE_SECRET
echo "  Replace <CLUSTER_VAULT_ADDR> with the Vault URL reachable from pods."
echo "══════════════════════════════════════════════════════════════════════"
