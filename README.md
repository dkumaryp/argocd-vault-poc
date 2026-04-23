# ArgoCD + Vault Plugin POC

A proof-of-concept showing how to use **ArgoCD Vault Plugin (AVP)** to inject secrets from a **HashiCorp Vault running in Docker** (outside the Kubernetes cluster) into Kubernetes manifests at sync time.

No secrets ever live in Git. AVP replaces `<placeholder>` tokens with real Vault values during the ArgoCD sync cycle.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Host Machine                                                   │
│                                                                 │
│  ┌──────────────────────┐      ┌──────────────────────────────┐│
│  │  Docker               │      │  Kubernetes Cluster          ││
│  │  ┌────────────────┐  │      │                              ││
│  │  │  HashiCorp      │  │      │  ┌────────────────────────┐ ││
│  │  │  Vault          │◄─┼──────┼──│  argocd-repo-server    │ ││
│  │  │  :8200          │  │  HTTP│  │  ┌──────────────────┐  │ ││
│  │  │                 │  │      │  │  │  AVP sidecar     │  │ ││
│  │  │  secret/data/   │  │      │  │  │  (CMP plugin)    │  │ ││
│  │  │   demo-app      │  │      │  │  └──────────────────┘  │ ││
│  │  └────────────────┘  │      │  └────────────────────────┘ ││
│  └──────────────────────┘      │                              ││
│                                │  ┌────────────────────────┐ ││
│  ┌──────────────────────┐      │  │  demo namespace         │ ││
│  │  Git Repository       │      │  │  Secret (populated)    │ ││
│  │  demo-app/secret.yaml │──────►  │  Deployment            │ ││
│  │  (with <placeholders>)│  sync│  └────────────────────────┘ ││
│  └──────────────────────┘      └──────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘

Flow:
  1. Git has manifests with <placeholder> tokens (no real secrets)
  2. ArgoCD triggers sync → calls AVP CMP plugin
  3. AVP reads Vault credentials from a K8s Secret
  4. AVP fetches real values from Vault over HTTP
  5. AVP substitutes placeholders → rendered manifest applied to cluster
```

---

## Prerequisites

| Tool                  | Version | Install                                                    |
|-----------------------|---------|------------------------------------------------------------|
| Docker + Compose      | v24+    | https://docs.docker.com/get-docker/                        |
| kubectl               | v1.28+  | https://kubernetes.io/docs/tasks/tools/                    |
| A local K8s cluster   | any     | minikube / kind / k3s / Docker Desktop                     |
| ArgoCD CLI (optional) | v2.10+  | https://argo-cd.readthedocs.io/en/stable/cli_installation/ |
| Vault CLI (optional)  | v1.15+  | https://developer.hashicorp.com/vault/install              |

> **Cluster tip:** This guide uses minikube. Adjust host addresses for other clusters (see Step 3).

---

## Directory Structure

```
argocd-vault-poc/
├── Makefile                              # Helper commands
├── vault/
│   ├── docker-compose.yml                # Vault (production-like, file storage)
│   ├── docker-compose.dev.yml            # Vault (dev mode, quick start)
│   ├── config/
│   │   └── vault.hcl                     # Vault server configuration
│   └── scripts/
│       ├── 01-init-vault.sh              # Initialize & unseal (prod only)
│       └── 02-setup-vault.sh             # Create secrets, policy, Kubernetes auth
├── argocd/
│   ├── install/
│   │   ├── namespace.yaml               # argocd namespace
│   │   └── vault-reviewer-sa.yaml       # SA that Vault uses for TokenReview
│   ├── plugins/
│   │   ├── cmp-plugin-configmap.yaml    # AVP plugin definition for ArgoCD
│   │   └── avp-credentials-secret.yaml.template
│   ├── patches/
│   │   └── argocd-repo-server-patch.yaml # Adds AVP sidecar to repo-server
│   └── apps/
│       └── demo-secret-app.yaml         # ArgoCD Application manifest
└── demo-app/                            # Sample app with Vault-backed secrets
    ├── kustomization.yaml
    ├── namespace.yaml
    ├── deployment.yaml
    ├── service.yaml
    └── secret.yaml                      # Secret with <placeholder> tokens
```

---

## Step-by-Step Guide

### Step 1 — Start HashiCorp Vault in Docker

Choose **Dev Mode** (fastest, data lost on restart) or **Production-like Mode** (persistent).

#### Option A: Dev Mode (Recommended for first run)

```bash
cd vault
docker compose -f docker-compose.dev.yml up -d

# Verify
docker logs vault-poc-dev
# Root token is: root
# Vault UI: http://localhost:8200
```

#### Option B: Production-like Mode (File storage backend)

```bash
cd vault
docker compose up -d

# Wait ~10 seconds for Vault to start, then initialize it
bash scripts/01-init-vault.sh
# ⚠ IMPORTANT: Save the unseal keys and root token printed to .vault-keys
```

**Verify Vault is running:**

```bash
curl http://localhost:8200/v1/sys/health | python3 -m json.tool
# "initialized": true, "sealed": false
```

Open the Vault UI: **http://localhost:8200**

---

### Step 2 — Configure Vault (manual commands)

> All commands below use `curl` against Vault's HTTP API and `kubectl` — no scripts needed.  
> Set these two variables first and keep them in your shell for all steps below:

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=root   # dev mode token; use your root token for prod mode
```

---

#### 2a. Deploy the vault-reviewer ServiceAccount

Vault runs outside the cluster. To validate a pod's SA token, Vault calls the K8s **TokenReview API** using a privileged ServiceAccount (`vault-reviewer`). Create it first:

```bash
kubectl apply -f argocd/install/namespace.yaml
kubectl apply -f argocd/install/vault-reviewer-sa.yaml

# Verify — K8s auto-populates the token into the Secret
kubectl get secret vault-reviewer-token -n argocd
kubectl describe secret vault-reviewer-token -n argocd
```

---

#### 2b. Connect Vault Docker container to the kind network

Vault (in Docker) needs to reach the K8s API server. On kind, both are Docker containers — they communicate via the `kind` Docker network.

```bash
# Connect Vault to kind network
docker network connect kind vault-poc-dev   # dev mode container name
# docker network connect kind vault-poc     # prod mode container name

# Confirm Vault is now on the kind network
docker inspect vault-poc-dev \
  -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}: {{$v.IPAddress}}{{"\n"}}{{end}}'
# Should show both 'bridge' and 'kind' entries
```

---

#### 2c. Collect the IPs you need

```bash
# IP of the kind control-plane container — Vault calls this to verify SA tokens
KIND_CP_IP=$(docker inspect desktop-control-plane \
  -f '{{.NetworkSettings.Networks.kind.IPAddress}}')
echo "K8s API (for Vault): https://${KIND_CP_IP}:6443"

# Gateway IP of the kind network — pods use this to reach Vault on your host
KIND_GW=$(docker network inspect kind \
  -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
echo "Vault addr (for pods): http://${KIND_GW}:8200"
```

---

#### 2d. Enable the KV v2 secrets engine

This is the secrets backend where your app secrets will live.

```bash
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data '{"type": "kv-v2"}' \
  $VAULT_ADDR/v1/sys/mounts/secret | python3 -m json.tool

# Verify it's mounted
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  $VAULT_ADDR/v1/sys/mounts | python3 -m json.tool | grep '"secret/'
```

---

#### 2e. Write demo secrets

These are the actual secrets AVP will pull at sync time.

```bash
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data '{
    "data": {
      "username": "demo-user",
      "password": "super-secret-password",
      "api-key": "1234567890abcdef",
      "db-host": "postgres.internal",
      "db-name": "appdb"
    }
  }' \
  $VAULT_ADDR/v1/secrets/data/demo-app | python3 -m json.tool

# Read it back to confirm
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  $VAULT_ADDR/v1/secrets/data/demo-app | python3 -m json.tool
# Look for "data": { "username": "demo-user", ... } in the response
```

---

#### 2f. Create the ArgoCD policy

This policy grants read-only access to `secret/data/*`. AVP will use a token bound to this policy.

```bash
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request PUT \
  --data '{
    "policy": "path \"secrets/data/*\" { capabilities = [\"read\", \"list\"] }\npath \"secrets/metadata/*\" { capabilities = [\"read\", \"list\"] }"
  }' \
  $VAULT_ADDR/v1/sys/policies/acl/argocd-policy

# Verify
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  $VAULT_ADDR/v1/sys/policies/acl/argocd-policy | python3 -m json.tool
```

---

#### 2g. Enable Kubernetes auth method

```bash
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data '{"type": "kubernetes"}' \
  $VAULT_ADDR/v1/sys/auth/kubernetes | python3 -m json.tool

# Verify it's enabled
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  $VAULT_ADDR/v1/sys/auth | python3 -m json.tool | grep kubernetes
```

---

#### 2h. Configure Kubernetes auth

Tell Vault how to reach the K8s API and which token to use for TokenReview calls.

> ⚠️ **Critical for Vault running outside K8s (Docker/VM)**: You MUST set `disable_local_ca_jwt: true`. Without it, Vault tries to read `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt` from its own container — which doesn't exist outside K8s — and silently falls back to broken behavior, causing every login to return `403 permission denied` even when the reviewer token and CA cert are correctly provided.

```bash
# Extract the vault-reviewer's JWT (Vault uses this to call K8s TokenReview API)
REVIEWER_JWT=$(kubectl get secret vault-reviewer-token -n argocd \
  -o jsonpath='{.data.token}' | base64 -d)

# Extract the cluster CA certificate (Vault uses this to trust the K8s API TLS)
K8S_CA=$(kubectl get secret vault-reviewer-token -n argocd \
  -o jsonpath='{.data.ca\.crt}' | base64 -d)

# Write config to a temp file — avoids shell escaping issues with large JWT/cert values
python3 -c "
import json, sys
payload = {
    'kubernetes_host': 'https://' + sys.argv[1] + ':6443',
    'token_reviewer_jwt': sys.argv[2],
    'kubernetes_ca_cert': sys.argv[3],
    'disable_iss_validation': True,
    'disable_local_ca_jwt': True   # REQUIRED when Vault runs outside K8s
}
print(json.dumps(payload))
" "$KIND_CP_IP" "$REVIEWER_JWT" "$K8S_CA" > /tmp/vault-k8s-config.json

# Apply — must run curl from a host that can reach Vault's actual IP
# On macOS with kind: use docker exec to send the request from inside Vault's network
docker cp /tmp/vault-k8s-config.json vault-poc-dev:/tmp/vault-k8s-config.json
docker exec vault-poc-dev sh -c \
  "wget -qO- --header='X-Vault-Token: root' --header='Content-Type: application/json' \
   --post-file=/tmp/vault-k8s-config.json \
   http://${VAULT_KIND_IP}:8200/v1/auth/kubernetes/config && echo 'Config OK'"

rm /tmp/vault-k8s-config.json

# Verify — confirm disable_local_ca_jwt is true
docker exec vault-poc-dev sh -c \
  "wget -qO- --header='X-Vault-Token: root' \
   http://${VAULT_KIND_IP}:8200/v1/auth/kubernetes/config" \
  | python3 -m json.tool | grep -E "disable_local|disable_iss|kubernetes_host"
# Expected:
#   "disable_iss_validation": true,
#   "disable_local_ca_jwt": true,
#   "kubernetes_host": "https://172.19.0.5:6443",
```

---

#### 2i. Create a Vault role for ArgoCD

This role maps the `argocd-repo-server` ServiceAccount in the `argocd` namespace to the `argocd-policy`. When the AVP pod logs in to Vault using its SA token, Vault checks this binding.

```bash
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data '{
    "bound_service_account_names": ["argocd-repo-server"],
    "bound_service_account_namespaces": ["argocd"],
    "policies": ["argocd-policy"],
    "ttl": "1h"
  }' \
  $VAULT_ADDR/v1/auth/kubernetes/role/argocd-role | python3 -m json.tool

# Verify
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  $VAULT_ADDR/v1/auth/kubernetes/role/argocd-role | python3 -m json.tool
# Confirm: bound_service_account_names, bound_service_account_namespaces, policies
```

---

#### 2j. Test the full auth flow manually

Simulate what AVP does at sync time — authenticate using a SA token and read a secret:

```bash
# Get the argocd-repo-server SA token (once ArgoCD is installed — do this after Step 4)
SA_TOKEN=$(kubectl get secret -n argocd \
  $(kubectl get sa argocd-repo-server -n argocd -o jsonpath='{.secrets[0].name}' 2>/dev/null) \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d \
  || kubectl create token argocd-repo-server -n argocd)

# Login to Vault using that SA token
VAULT_CLIENT_TOKEN=$(curl -s \
  --request POST \
  --data "{\"jwt\": \"$SA_TOKEN\", \"role\": \"argocd-role\"}" \
  $VAULT_ADDR/v1/auth/kubernetes/login | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")
echo "Got Vault token: $VAULT_CLIENT_TOKEN"

# Use that token to read the secret — this is exactly what AVP does
curl -s \
  --header "X-Vault-Token: $VAULT_CLIENT_TOKEN" \
  $VAULT_ADDR/v1/secrets/data/demo-app | python3 -m json.tool
# Should show your demo-app secret values
```

> **How is this different from AppRole?** AppRole requires storing a static Role ID + Secret ID in a K8s Secret. With Kubernetes auth, the pod's SA token (auto-mounted, short-lived, rotated by K8s) is the credential. Nothing static is ever stored.

---

### Step 2 (alternative) — Configure Vault via the UI

Open **http://localhost:8200** and sign in with token `root`.

> Steps 2a–2c (vault-reviewer SA, kind network, IPs) still require the terminal — those are Kubernetes and Docker operations. The UI replaces the `curl` commands for Vault configuration only (2d onwards).

---

#### UI: Enable KV v2 secrets engine

1. Click **Secrets Engines** in the left sidebar
2. Click **Enable new engine**
3. Choose **KV** → click **Next**
4. Set **Path** to `secret`
5. Set **Version** to `2`
6. Click **Enable engine**

---

#### UI: Write demo secrets

1. Click **Secrets Engines** → `secret/`
2. Click **Create secret**
3. Set **Path** to `demo-app`
4. Under **Secret data**, add each key-value pair using **+ Add**:

   | Key | Value |
   |---|---|
   | `username` | `demo-user` |
   | `password` | `super-secret-password` |
   | `api-key` | `1234567890abcdef` |
   | `db-host` | `postgres.internal` |
   | `db-name` | `appdb` |

5. Click **Save**

---

#### UI: Create the ArgoCD policy

1. Click **Policies** in the left sidebar
2. Click **Create ACL policy**
3. Set **Name** to `argocd-policy`
4. Paste this into the **Policy** editor:

   ```hcl
   path "secrets/data/*" {
     capabilities = ["read", "list"]
   }
   path "secrets/metadata/*" {
     capabilities = ["read", "list"]
   }
   ```

5. Click **Create policy**

---

#### UI: Enable Kubernetes auth method

1. Click **Access** in the left sidebar
2. Click **Enable new method**
3. Choose **Kubernetes** → click **Next**
4. Leave the path as `kubernetes`
5. Click **Enable method**

---

#### UI: Configure Kubernetes auth

1. Click **Access** → **kubernetes** → **Configuration** tab
2. Click **Edit configuration** (or **Configure** if first time)
3. Fill in:

   - **Kubernetes host**: `https://<KIND_CP_IP>:6443`  
     *(from step 2c: `echo $KIND_CP_IP`)*
   - **Kubernetes CA certificate**: paste the output of:
     ```bash
     kubectl get secret vault-reviewer-token -n argocd \
       -o jsonpath='{.data.ca\.crt}' | base64 -d
     ```
   - **Token reviewer JWT**: paste the output of:
     ```bash
     kubectl get secret vault-reviewer-token -n argocd \
       -o jsonpath='{.data.token}' | base64 -d
     ```
   - Check **Disable JWT issuer validation** (required for kind)

4. Click **Save**

---

#### UI: Create the argocd-role

> ⚠️ **Vault UI limitation**: The Kubernetes auth method does **not** expose role management in the UI. The `Access → kubernetes` page only shows the Configuration tab. This is a known gap in Vault's UI — use the API instead:

```bash
curl -s -H "X-Vault-Token: root" \
  --request POST \
  --data '{
    "bound_service_account_names": ["argocd-repo-server"],
    "bound_service_account_namespaces": ["argocd"],
    "policies": ["argocd-policy"],
    "ttl": "1h"
  }' \
  http://localhost:8200/v1/auth/kubernetes/role/argocd-role

# Verify — list all roles
curl -s -H "X-Vault-Token: root" \
  --request LIST \
  http://localhost:8200/v1/auth/kubernetes/role | python3 -m json.tool
# Expected: { "data": { "keys": ["argocd-role"] } }
```

---

#### UI: Verify everything

- **Secrets**: Click **Secrets Engines** → `secret/` → `demo-app` → confirm all 5 keys are present
- **Policy**: Click **Policies** → `argocd-policy` → confirm the HCL rules
- **Auth role**: Not visible in UI — use CLI: `curl -s -H "X-Vault-Token: root" --request LIST http://localhost:8200/v1/auth/kubernetes/role | python3 -m json.tool`



### Step 3 — Determine Network Addresses (kind + macOS)

On macOS, Docker runs inside a Linux VM. Docker internal IPs (`172.x.x.x`) are **not reachable from your Mac terminal** — only from other containers on the same Docker network.

> **Key insight**: Vault needs its **own IP on the kind network** (not the gateway IP `172.19.0.1`). The gateway is the VM bridge — Vault's container IP is what pods route to.

#### 3a. Connect Vault to the kind network

```bash
# Connect Vault container to kind network (one-time)
docker network connect kind vault-poc-dev

# Find your container name if 'vault-poc-dev' doesn't work
docker ps --format "{{.Names}}\t{{.Image}}" | grep vault
```

#### 3b. Get Vault's IP on the kind network

```bash
VAULT_KIND_IP=$(docker inspect vault-poc-dev \
  -f '{{.NetworkSettings.Networks.kind.IPAddress}}')
echo $VAULT_KIND_IP   # e.g. 172.19.0.6

# If output is "<no value>" — Vault is not connected to kind network yet (run 3a again)
# If output is empty — check container name with: docker ps
```

#### 3c. Get kind control-plane IP (Vault → K8s API)

```bash
# Find your control-plane container name first
kind get clusters            # e.g. outputs "desktop"
# Container name = <cluster-name>-control-plane

KIND_CP_IP=$(docker inspect desktop-control-plane \
  -f '{{.NetworkSettings.Networks.kind.IPAddress}}')
echo $KIND_CP_IP   # e.g. 172.19.0.5
```

#### 3d. Export for use in remaining steps

```bash
export VAULT_KIND_IP=172.19.0.6    # replace with your actual value
export KIND_CP_IP=172.19.0.5       # replace with your actual value
export CLUSTER_VAULT_ADDR=http://${VAULT_KIND_IP}:8200
```

#### 3e. Test connectivity

```bash
# ✅ From Mac terminal — always use localhost (Docker port-maps this)
curl http://localhost:8200/v1/sys/health

# ❌ Do NOT test Docker IPs from Mac — they live inside the Docker VM
# curl http://172.19.0.6:8200   ← will get "Connection reset by peer" on macOS, this is expected

# ✅ Test from inside the cluster — this is what AVP does at sync time
kubectl delete pod vault-test --ignore-not-found --wait
kubectl run vault-test --image=curlimages/curl --restart=Never \
  -- curl -s http://${VAULT_KIND_IP}:8200/v1/sys/health

sleep 5
kubectl logs vault-test
# Expected: {"initialized":true,"sealed":false,"standby":false,...}
kubectl delete pod vault-test
```

#### 3f. Confirmed working address map

| Who | Address | Notes |
|---|---|---|
| Mac scripts / Vault UI | `http://localhost:8200` | Docker port-maps 8200 |
| Vault container → K8s API | `https://${KIND_CP_IP}:6443` | Via kind Docker network |
| K8s pods → Vault | `http://${VAULT_KIND_IP}:8200` | Via kind Docker network |

#### 3g. Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `<no value>` for `VAULT_KIND_IP` | Vault not on kind network | `docker network connect kind vault-poc-dev` |
| `$VAULT_HOST_IP` returns `fc00:...172.x.x.x` | IPv6+IPv4 concatenated | Use `grep -v ':'` or hardcode the IPv4 |
| `Connection reset by peer` from Mac terminal | Docker IPs not routable from macOS | Use `localhost:8200` from Mac; test from pods only |
| `curl: (3) Bad hostname` | Variable empty or `{}` escaped in shell | Check `echo $VAR`; in zsh don't escape braces |
| Pod already exists error | Previous test pod not cleaned | `kubectl delete pod vault-test --ignore-not-found` |
| `no such object: kind-control-plane` | Cluster isn't named `kind` | Run `kind get clusters` to find the name |



### Step 4 — Install ArgoCD

> **POC recommendation**: Use `core-install.yaml` instead of `install.yaml`. The full install includes **Dex** (SSO/OIDC) and **Redis** (caching) which are not needed for this POC and will cause `ImagePullBackOff` from pulling large images inside the kind VM.

```bash
# Create namespace
kubectl apply -f argocd/install/namespace.yaml

# Install ArgoCD — core only (no Dex, no Redis, no notifications controller)
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.10.0/manifests/core-install.yaml

# Wait for all pods to be ready (~2 minutes)
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
kubectl get pods -n argocd
```

<details>
<summary>If you used full install.yaml and get ImagePullBackOff for redis or dex</summary>

Image pulls from inside the kind VM can fail with `unexpected EOF` (transient network error). Fix by pulling on your Mac and loading directly into kind:

```bash
# Pull on Mac (fast, uses your Mac's Docker cache)
docker pull redis:7.0.14-alpine
docker pull ghcr.io/dexidp/dex:v2.37.0

# Load directly into the kind cluster — bypasses in-VM network entirely
kind load docker-image redis:7.0.14-alpine --name desktop
kind load docker-image ghcr.io/dexidp/dex:v2.37.0 --name desktop

# Delete stuck pods so they recreate using the cached images
kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-redis
kubectl delete pod -n argocd -l app.kubernetes.io/name=dex
```

Or just scale them to zero since they're not needed for the POC:
```bash
kubectl scale deployment argocd-dex-server argocd-redis -n argocd --replicas=0
```
</details>

**Get the initial admin password:**

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

**Access the ArgoCD UI:**

```bash
# Port-forward in a separate terminal
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Open: https://localhost:8080
# Username: admin
# Password: <output from above>
```

**Login with the CLI (optional):**

```bash
argocd login localhost:8080 \
  --username admin \
  --password <password> \
  --insecure
```

---

### Step 5 — Install the ArgoCD Vault Plugin (CMP Sidecar)

The AVP is installed as a **sidecar** in the `argocd-repo-server` pod using the CMP (Config Management Plugin) pattern.

> ⚠️ **Complete Step 6 (create the credentials secret) BEFORE step 5c.** The patch references the secret — if it doesn't exist yet, the `avp` sidecar will crash on startup.

#### 5a. Apply the vault-reviewer SA (if not done in Step 2)

```bash
kubectl apply -f argocd/install/vault-reviewer-sa.yaml
```

#### 5b. Apply the plugin definition ConfigMap

```bash
kubectl apply -f argocd/plugins/cmp-plugin-configmap.yaml
```

#### 5c. Create the AVP credentials secret (Step 6 content — do this first)

```bash
kubectl create secret generic argocd-vault-plugin-credentials \
  --namespace argocd \
  --from-literal=VAULT_ADDR=http://${VAULT_KIND_IP}:8200 \
  --from-literal=AVP_TYPE=vault \
  --from-literal=AVP_AUTH_TYPE=k8s \
  --from-literal=AVP_K8S_ROLE=argocd-role
```

#### 5d. Patch the argocd-repo-server deployment

This adds:
- An **init container** (`alpine:3.18`) that downloads the AVP binary — uses the image already cached on the node
- An **AVP sidecar** (`alpine:3.18`) that runs the CMP server and reads the pod's SA token

```bash
kubectl patch deployment argocd-repo-server \
  -n argocd \
  --patch-file argocd/patches/argocd-repo-server-patch.yaml

# Watch the rollout
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=180s
```

**Verify the sidecar is running:**

```bash
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server
# Should show 2/2 containers ready (original + avp sidecar)
```

**Check AVP binary in the sidecar:**

```bash
AVP_POD=$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -it "$AVP_POD" -n argocd -c avp -- argocd-vault-plugin version
```

<details>
<summary>If the avp sidecar gets ImagePullBackOff for alpine:3.18</summary>

```bash
docker pull alpine:3.18
kind load docker-image alpine:3.18 --name desktop
kubectl rollout restart deployment/argocd-repo-server -n argocd
```
</details>

With Kubernetes auth, **no Role ID or Secret ID are needed**. The secret only contains:
- `VAULT_ADDR` — the Vault address **reachable from inside pods** (not `localhost`)
- `AVP_TYPE` — always `vault`
- `AVP_AUTH_TYPE` — `k8s` (use pod SA token)
- `AVP_K8S_ROLE` — the Vault role that maps this SA to a policy

```bash
# VAULT_KIND_IP = Vault's IP on the kind Docker network (from Step 3)
# Do NOT use localhost — that's only reachable from your Mac, not from pods
kubectl create secret generic argocd-vault-plugin-credentials \
  --namespace argocd \
  --from-literal=VAULT_ADDR=http://${VAULT_KIND_IP}:8200 \
  --from-literal=AVP_TYPE=vault \
  --from-literal=AVP_AUTH_TYPE=k8s \
  --from-literal=AVP_K8S_ROLE=argocd-role

# Verify it was created
kubectl get secret argocd-vault-plugin-credentials -n argocd

# Inspect the keys (values are base64-encoded, not shown in plain text)
kubectl get secret argocd-vault-plugin-credentials -n argocd -o jsonpath='{.data}' | python3 -m json.tool
```

**If you need to update it later** (e.g. Vault IP changed):
```bash
kubectl delete secret argocd-vault-plugin-credentials -n argocd
# Then re-run the create command above with the new IP
```

**Auth flow at sync time:**
```
AVP sidecar pod
  → reads /var/run/secrets/kubernetes.io/serviceaccount/token  (auto-mounted by K8s)
  → POST http://vault:8200/v1/auth/kubernetes/login  { jwt: <token>, role: argocd-role }
  → Vault calls K8s TokenReview API using vault-reviewer token
  → K8s confirms: SA=argocd-repo-server, namespace=argocd ✓
  → Vault issues short-lived Vault token
  → AVP uses Vault token to read secrets/data/demo-app
  → Placeholders replaced in manifests
```

---

### Step 7 — Deploy via ArgoCD

The repo is already at `https://github.com/dkumaryp/argocd-vault-poc.git`. The Application manifest is pre-configured.

#### 7a. Apply the ArgoCD Application

```bash
kubectl apply -f argocd/apps/demo-secret-app.yaml
```

#### 7b. Sync the app

```bash
# If auto-sync doesn't trigger within 30s, sync manually
argocd app sync demo-secret-app --force

# Watch status
argocd app get demo-secret-app
kubectl get applications -n argocd
```

> ℹ️ **"Resource not found in cluster"** in ArgoCD UI is expected before the first sync — it just means the resources don't exist yet. Click **Sync** to create them.

#### 7c. If sync fails with a cached error

```bash
# Hard refresh clears the cached manifest error, then sync
argocd app terminate-op demo-secret-app
argocd app sync demo-secret-app --force
```

Or in the ArgoCD UI: click **Hard Refresh** → then **Sync**.

---

### Step 8 — Verify Secrets Are Injected

```bash
# Confirm resources were created
kubectl get ns demo
kubectl get secret demo-secret -n demo
kubectl get deployment demo-app -n demo

# ✅ THE KEY CHECK — decoded secret values must come from Vault, not placeholders
kubectl get secret demo-secret -n demo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
# Expected (your actual Vault values):
#   api-key: 1234567890abcdef
#   db-host: postgres.internal
#   db-name: appdb
#   password: uper-secret-password
#   username: demo-user

# Verify the deployment pod has env vars from the secret
DEMO_POD=$(kubectl get pod -n demo -l app=demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it "$DEMO_POD" -n demo -- env | grep -E "APP_|DB_"
```

**✅ POC success criteria:**
- `kubectl get secret demo-secret -n demo` → exists, created by ArgoCD
- Decoded values = real Vault values (not `<username>`, `<password>` etc.)
- `cat demo-app/secret.yaml` → still shows `<placeholders>` in Git


---

## Network Map (kind + macOS)

This is the confirmed working network layout. All three IPs must be right or auth will fail.

```
┌─────────────────────────────────────────────────────────────────────────┐
│  macOS Host                                                             │
│                                                                         │
│  localhost:8200 ──port-map──► Vault container (172.19.0.6:8200)        │
│                               [vault_default + kind networks]           │
│                                        │                                │
│                                  kind Docker network (172.19.0.0/16)    │
│                                        │                                │
│                          ┌─────────────┴──────────────┐                │
│                          │                             │                │
│                   172.19.0.5:6443              172.19.0.6:8200          │
│                   kind control-plane            Vault container         │
│                   (K8s API server)                                      │
│                          │                             ▲                │
│                   kind pods                            │                │
│                   (172.19.x.x)  ───── reach Vault ────┘                │
└─────────────────────────────────────────────────────────────────────────┘

Address reference:
  Mac → Vault (scripts/UI) : http://localhost:8200
  Vault → K8s API          : https://172.19.0.5:6443  (KIND_CP_IP)
  Pods → Vault             : http://172.19.0.6:8200   (VAULT_KIND_IP)
```

> **macOS gotcha**: Docker internal IPs (`172.19.x.x`) are inside Docker's Linux VM.
> They are NOT reachable from your Mac terminal — only from other containers on the same Docker network.
> Always use `localhost:8200` from your Mac and `172.19.0.6:8200` from inside pods.

---



| | AppRole | Kubernetes Auth (this POC) |
|---|---|---|
| Credentials stored in K8s | ✗ Role ID + Secret ID in a Secret | ✓ Only Vault address + role name |
| Token rotation | Manual | Automatic (K8s rotates SA tokens) |
| Identity proof | Shared static secret | Pod's cryptographically signed SA JWT |
| If credentials leak | Must rotate Secret ID | Nothing to leak — token is pod-specific |
| Extra setup | None | vault-reviewer SA + Vault K8s auth config |

---



### Annotation-style (used in this POC)

```yaml
# In secret.yaml:
metadata:
  annotations:
    avp.kubernetes.io/path: "secrets/data/demo-app"  # Vault path
stringData:
  username: <username>   # key name in Vault KV secret
  password: <password>
```

### Inline path-style (alternative, no annotation needed)

```yaml
stringData:
  username: <path:secrets/data/demo-app#username>
  password: <path:secrets/data/demo-app#password>
```

### Versioned secret

```yaml
stringData:
  # Fetch a specific version of the secret
  password: <path:secrets/data/demo-app#password | version=2>
```

---

## Troubleshooting

All issues actually encountered during this POC, in the order they appeared.

### ❌ ImagePullBackOff for redis / dex / ubuntu

**Cause**: Transient network failure inside kind VM pulling from Docker Hub (`unexpected EOF`).

```bash
# Fix: pull on Mac and load directly into kind — bypasses in-VM network
docker pull redis:7.0.14-alpine
docker pull ghcr.io/dexidp/dex:v2.37.0
kind load docker-image redis:7.0.14-alpine --name desktop
kind load docker-image ghcr.io/dexidp/dex:v2.37.0 --name desktop
kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-redis
kubectl delete pod -n argocd -l app.kubernetes.io/name=dex
```

Or avoid entirely: use `core-install.yaml` instead of `install.yaml` (no Dex/Redis).

---

### ❌ avp sidecar ImagePullBackOff for ubuntu:22.04

**Cause**: The AVP sidecar image was set to `ubuntu:22.04` — heavy image, slow pull, fails on flaky network.

**Fix**: Change `image: ubuntu:22.04` → `image: alpine:3.18` in `argocd-repo-server-patch.yaml`. Alpine is already cached on the node from the init container.

---

### ❌ Vault 403 permission denied on kubernetes login

**Cause**: `disable_local_ca_jwt: false` (Vault default) makes Vault look for `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt` inside its container. Since Vault runs in Docker (not K8s), that file doesn't exist — Vault silently ignores your configured `kubernetes_ca_cert` and fails every login.

**Fix**: Always set `disable_local_ca_jwt: true` when Vault runs outside K8s.

**Diagnose**:
```bash
# Confirm the setting
curl -s -H "X-Vault-Token: root" \
  http://localhost:8200/v1/auth/kubernetes/config | python3 -m json.tool | grep disable_local
# Must be: "disable_local_ca_jwt": true

# Test login (run from inside Vault container — Mac can't reach kind IPs)
docker exec vault-poc-dev sh -c \
  "wget -qO- --header='Content-Type: application/json' \
   --post-data='{\"jwt\":\"'\"$(kubectl exec -n argocd \
     $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server \
       -o jsonpath='{.items[0].metadata.name}') \
     -c avp -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)'\"',\"role\":\"argocd-role\"}' \
   http://172.19.0.6:8200/v1/auth/kubernetes/login" | python3 -m json.tool | grep client_token
```

**Re-apply config** (must use `docker exec` — `curl localhost` from Mac drops large payloads):
```bash
REVIEWER_JWT=$(kubectl get secret vault-reviewer-token -n argocd -o jsonpath='{.data.token}' | base64 -d)
K8S_CA=$(kubectl get secret vault-reviewer-token -n argocd -o jsonpath='{.data.ca\.crt}' | base64 -d)
python3 -c "
import json, sys
print(json.dumps({
  'kubernetes_host': 'https://172.19.0.5:6443',
  'token_reviewer_jwt': sys.argv[1],
  'kubernetes_ca_cert': sys.argv[2],
  'disable_iss_validation': True,
  'disable_local_ca_jwt': True
}))
" "$REVIEWER_JWT" "$K8S_CA" > /tmp/vk8s.json
docker cp /tmp/vk8s.json vault-poc-dev:/tmp/vk8s.json
docker exec vault-poc-dev sh -c \
  "wget -qO- --header='X-Vault-Token: root' --header='Content-Type: application/json' \
   --post-file=/tmp/vk8s.json http://172.19.0.6:8200/v1/auth/kubernetes/config && echo OK"
rm /tmp/vk8s.json
```

---

### ❌ Could not find secrets at path secret/data/demo-app

**Cause**: Vault has two KV engines — `secret/` (auto-created by dev mode) and `secrets/` (where data actually lives). Wrong engine name in the annotation.

**Fix**: Match the annotation to where your secrets actually are:
```bash
# Check which engine has your data
curl -s -H "X-Vault-Token: root" \
  http://localhost:8200/v1/secrets/data/demo-app | python3 -m json.tool | grep -E "username|error"

# Update annotation in demo-app/secret.yaml
avp.kubernetes.io/path: "secrets/data/demo-app"   # note: secrets/ not secret/
```

Also update the Vault policy to match:
```bash
curl -s -H "X-Vault-Token: root" --request POST \
  --data '{"policy":"path \"secrets/data/*\" {\n  capabilities = [\"read\",\"list\"]\n}\npath \"secrets/metadata/*\" {\n  capabilities = [\"read\",\"list\"]\n}"}' \
  http://localhost:8200/v1/sys/policies/acl/argocd-policy
```

---

### ❌ Kustomization CRD not found

**Cause**: ArgoCD auto-detects `kustomization.yaml` in the app path and routes to Kustomize instead of the AVP plugin — even when the plugin is explicitly configured.

**Fix**: Delete `demo-app/kustomization.yaml`. AVP works in plain directory mode on raw `*.yaml` files.

---

### ❌ "Resource not found in cluster" for all demo-app resources

**Cause**: This is NOT an error — it means AVP successfully generated the manifests but ArgoCD hasn't applied them yet (waiting for Sync).

**Fix**: Click **Sync** in the ArgoCD UI, or:
```bash
argocd app sync demo-secret-app --force
```

---

### ❌ AVP sidecar CrashLoopBackOff

```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server -c avp
# Common causes:
# - secret "argocd-vault-plugin-credentials" not found → create it (Step 5c)
# - Vault unreachable from pod → verify VAULT_KIND_IP (Step 3)
```

---

### ❌ ArgoCD sync fails with "plugin not found"

```bash
# Verify plugin ConfigMap exists
kubectl get cm cmp-plugin -n argocd -o yaml

# Verify AVP binary is in the sidecar
kubectl exec -n argocd \
  $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server \
    -o jsonpath='{.items[0].metadata.name}') \
  -c avp -- argocd-vault-plugin version
```

---

### ❌ Vault connection refused / Bad hostname from Mac terminal

**Cause**: Docker internal IPs (`172.19.x.x`) are inside Docker's Linux VM — not routable from macOS.

**Fix**:
- Mac → Vault: always use `http://localhost:8200`
- Pods → Vault: use `http://${VAULT_KIND_IP}:8200` (Vault's kind network IP)
- Run Vault API calls from inside the container: `docker exec vault-poc-dev sh -c "wget ..."`



---

## Updating Secrets in Vault

When you update a secret in Vault, Kubernetes will **not** automatically update. You need to trigger an ArgoCD sync:

```bash
# Update secret in Vault
curl -s -H "X-Vault-Token: root" --request POST \
  --data '{"data":{"password":"new-password-123"}}' \
  http://localhost:8200/v1/secrets/data/demo-app

# Force ArgoCD to re-sync (re-runs AVP, replaces placeholders with new values)
argocd app sync demo-secret-app --force
```

> For automatic secret rotation, consider using [External Secrets Operator](https://external-secrets.io/) or Vault Agent alongside AVP.

---

## Quick Reference Commands

```bash
# Vault health (from Mac)
curl http://localhost:8200/v1/sys/health | python3 -m json.tool

# List secrets in engine
curl -s -H "X-Vault-Token: root" --request LIST \
  http://localhost:8200/v1/secrets/metadata | python3 -m json.tool

# Read a secret
curl -s -H "X-Vault-Token: root" \
  http://localhost:8200/v1/secrets/data/demo-app | python3 -m json.tool

# Test Vault login (simulates what AVP does at sync time)
docker exec vault-poc-dev sh -c \
  "wget -qO- --header='Content-Type: application/json' \
   --post-data='{\"role\":\"argocd-role\",\"jwt\":\"'\"$(kubectl exec -n argocd \
     $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server \
       -o jsonpath='{.items[0].metadata.name}') \
     -c avp -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)'\"'}' \
   http://172.19.0.6:8200/v1/auth/kubernetes/login" | python3 -m json.tool | grep client_token

# ArgoCD app status
argocd app list
argocd app get demo-secret-app

# Force re-sync
argocd app sync demo-secret-app --force

# View AVP logs (live)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server -c avp -f

# Decode all keys in the deployed secret
kubectl get secret demo-secret -n demo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
```

---

## Cleanup

```bash
# Remove demo app
kubectl delete -f argocd/apps/demo-secret-app.yaml
kubectl delete namespace demo

# Remove ArgoCD plugin config
kubectl delete secret argocd-vault-plugin-credentials -n argocd
kubectl delete cm cmp-plugin -n argocd

# Remove ArgoCD entirely
kubectl delete namespace argocd

# Stop Vault
cd vault && docker compose down -v   # -v removes volumes (data)
```

---

## References

- [ArgoCD Vault Plugin (AVP)](https://argocd-vault-plugin.readthedocs.io/)
- [AVP GitHub](https://github.com/argoproj-labs/argocd-vault-plugin)
- [HashiCorp Vault Docs](https://developer.hashicorp.com/vault/docs)
- [ArgoCD CMP Docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/config-management-plugins/)
- [ArgoCD Installation](https://argo-cd.readthedocs.io/en/stable/getting_started/)
