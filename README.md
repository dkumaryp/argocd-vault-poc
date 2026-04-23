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
  $VAULT_ADDR/v1/secret/data/demo-app | python3 -m json.tool

# Read it back to confirm
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  $VAULT_ADDR/v1/secret/data/demo-app | python3 -m json.tool
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
    "policy": "path \"secret/data/*\" { capabilities = [\"read\", \"list\"] }\npath \"secret/metadata/*\" { capabilities = [\"read\", \"list\"] }"
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

```bash
# Extract the vault-reviewer's JWT (Vault uses this to call K8s TokenReview API)
REVIEWER_JWT=$(kubectl get secret vault-reviewer-token -n argocd \
  -o jsonpath='{.data.token}' | base64 -d)

# Extract the cluster CA certificate (Vault uses this to trust the K8s API TLS)
K8S_CA=$(kubectl get secret vault-reviewer-token -n argocd \
  -o jsonpath='{.data.ca\.crt}' | base64 -d)

# Configure Vault's kubernetes auth
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request POST \
  --data "{
    \"kubernetes_host\": \"https://${KIND_CP_IP}:6443\",
    \"kubernetes_ca_cert\": $(echo "$K8S_CA" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
    \"token_reviewer_jwt\": $(echo "$REVIEWER_JWT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
    \"disable_iss_validation\": true
  }" \
  $VAULT_ADDR/v1/auth/kubernetes/config | python3 -m json.tool

# Verify
curl -s \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  $VAULT_ADDR/v1/auth/kubernetes/config | python3 -m json.tool
# Check kubernetes_host matches your KIND_CP_IP
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
  $VAULT_ADDR/v1/secret/data/demo-app | python3 -m json.tool
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
   path "secret/data/*" {
     capabilities = ["read", "list"]
   }
   path "secret/metadata/*" {
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
  → AVP uses Vault token to read secret/data/demo-app
  → Placeholders replaced in manifests
```

---

### Step 7 — Push Demo App to Git and Deploy via ArgoCD

ArgoCD is GitOps-based — it syncs from a Git repository. You need to host the `demo-app/` directory in a Git repo that ArgoCD can access.

#### 7a. Push to Git

```bash
# Option 1: Push this entire poc directory to GitHub
git init
git remote add origin https://github.com/dkumaryp/argocd-vault-poc.git
git add .
git commit -m "feat: ArgoCD Vault Plugin POC"
git push -u origin main
```

#### 7b. Update the ArgoCD Application manifest

Edit `argocd/apps/demo-secret-app.yaml` and set your Git repo URL:

```yaml
source:
  repoURL: https://github.com/dkumaryp/argocd-vault-poc.git
  targetRevision: HEAD
  path: argocd-vault-poc/demo-app   # adjust if your repo layout differs
```

#### 7c. Register the repo with ArgoCD (if private)

```bash
argocd repo add https://github.com/dkumaryp/argocd-vault-poc.git \
  --username YOUR_USER \
  --password YOUR_PAT_TOKEN
```

#### 7d. Deploy the ArgoCD Application

```bash
kubectl apply -f argocd/apps/demo-secret-app.yaml

# Watch sync status
kubectl get applications -n argocd
argocd app get demo-secret-app
argocd app sync demo-secret-app   # manual sync if auto-sync is off
```

---

### Step 8 — Verify Secrets Are Injected

#### Check the Kubernetes Secret was created with real values:

```bash
# Decode all secret keys
kubectl get secret demo-secret -n demo -o jsonpath='{.data}' | \
  python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
for k, v in d.items():
    print(f'  {k}: {base64.b64decode(v).decode()}')
"

# Expected output:
#   username: demo-user
#   password: super-secret-password
#   api-key: 1234567890abcdef
#   db-host: postgres.internal
#   db-name: appdb
```

#### Check the demo pod has the env vars:

```bash
DEMO_POD=$(kubectl get pod -n demo -l app=demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it "$DEMO_POD" -n demo -- env | grep -E "APP_|DB_"

# Expected:
#   APP_USERNAME=demo-user
#   APP_PASSWORD=super-secret-password
#   APP_API_KEY=1234567890abcdef
#   DB_HOST=postgres.internal
```

#### Verify the Git secret still has placeholders (not real values):

```bash
cat demo-app/secret.yaml | grep -E "<|>"
# Should show: <username>, <password>, <api-key>, etc.
```

**✅ If you see real values in the cluster but placeholders in Git — the POC works!**

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
    avp.kubernetes.io/path: "secret/data/demo-app"  # Vault path
stringData:
  username: <username>   # key name in Vault KV secret
  password: <password>
```

### Inline path-style (alternative, no annotation needed)

```yaml
stringData:
  username: <path:secret/data/demo-app#username>
  password: <path:secret/data/demo-app#password>
```

### Versioned secret

```yaml
stringData:
  # Fetch a specific version of the secret
  password: <path:secret/data/demo-app#password | version=2>
```

---

## Troubleshooting

### AVP sidecar CrashLoopBackOff

```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server -c avp

# Common causes:
# - Secret 'argocd-vault-plugin-credentials' not found → run Step 6
# - Vault unreachable from pod → check CLUSTER_VAULT_ADDR in Step 3
# - Wrong AVP binary architecture (linux_amd64 vs arm64)
```

### ArgoCD sync fails with "plugin not found"

```bash
# Verify plugin is registered
kubectl exec -n argocd -c avp \
  $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server \
    -o jsonpath='{.items[0].metadata.name}') \
  -- ls /home/argocd/cmp-server/plugins/

# Verify ConfigMap
kubectl get cm cmp-plugin -n argocd -o yaml
```

### Vault connection refused from inside cluster

```bash
# Test connectivity from a pod
kubectl run test --rm -it --image=alpine -- \
  wget -qO- http://host.minikube.internal:8200/v1/sys/health

# If it fails, try the host's actual IP:
HOST_IP=$(kubectl get nodes -o wide | awk 'NR==2{print $6}')
kubectl run test --rm -it --image=alpine -- \
  wget -qO- http://$HOST_IP:8200/v1/sys/health
```

### Placeholders not replaced (secret has literal `<username>`)

```bash
# Check if AVP can authenticate with Vault
kubectl logs -n argocd \
  $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server \
    -o jsonpath='{.items[0].metadata.name}') -c avp | grep -i "error\|vault"

# Manually test AppRole auth from pod
kubectl exec -n argocd -c avp \
  $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server \
    -o jsonpath='{.items[0].metadata.name}') \
  -- argocd-vault-plugin generate /dev/stdin <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: test
  annotations:
    avp.kubernetes.io/path: "secret/data/demo-app"
stringData:
  username: <username>
EOF
```

### Vault is sealed after restart (prod mode)

```bash
# Unseal with 3 of the 5 keys from .vault-keys
VAULT_ADDR=http://localhost:8200
vault operator unseal <key1>
vault operator unseal <key2>
vault operator unseal <key3>
```

---

## Updating Secrets in Vault

When you update a secret in Vault, Kubernetes will **not** automatically update. You need to trigger an ArgoCD sync:

```bash
# Update secret in Vault
vault kv put secret/demo-app password="new-password-123"

# Force ArgoCD to re-sync (re-runs AVP)
argocd app sync demo-secret-app --force

# Or via kubectl
kubectl annotate application demo-secret-app -n argocd \
  argocd.argoproj.io/refresh=normal
```

> For automatic secret rotation, consider using [External Secrets Operator](https://external-secrets.io/) alongside AVP, or set up a Vault agent to watch for changes.

---

## Quick Reference Commands

```bash
# Vault status
curl http://localhost:8200/v1/sys/health | python3 -m json.tool

# List secrets
VAULT_TOKEN=root vault kv list secret/

# ArgoCD app status
argocd app list
argocd app get demo-secret-app

# View AVP logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server -c avp -f

# Decode all keys in a secret
kubectl get secret demo-secret -n demo -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
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
