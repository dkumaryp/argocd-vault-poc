# POC Report: ArgoCD Vault Plugin (AVP) — Secret Injection via Kubernetes Auth

**Status:** ✅ Complete — End-to-end verified  
**Repo:** https://github.com/dkumaryp/argocd-vault-poc  
**Date:** April 2025  

---

## 1. Objective

Demonstrate that ArgoCD can inject secrets from HashiCorp Vault into Kubernetes manifests **at sync time**, without secrets ever being stored in Git or Kubernetes Secrets statically.

The specific goal was to validate the **ArgoCD Vault Plugin (AVP)** using **Kubernetes auth** (not static credentials), with Vault running **outside** the Kubernetes cluster — matching the intended production topology where Vault is hosted on GCP GKE and BDCD clusters are on separate cloud providers.

---

## 2. Scope

| Item | Value |
|---|---|
| Vault deployment | Docker container on macOS (outside the cluster) |
| Kubernetes cluster | kind (`desktop`) running on macOS via Docker |
| ArgoCD version | v2.10.0 (core-install, no Dex/Redis) |
| AVP version | v1.17.0 |
| Auth method | Kubernetes auth (no static secrets) |
| Secret backend | KV v2 (`secrets/data/demo-app`) |
| Source of truth | GitHub (`dkumaryp/argocd-vault-poc`) |

---

## 3. Architecture

### Component Map

```
┌──────────────────────────────────────────────────────────────────────────┐
│  macOS Host Machine                                                      │
│                                                                          │
│  ┌─────────────────────┐        ┌──────────────────────────────────────┐│
│  │  Docker              │        │  kind Kubernetes Cluster             ││
│  │                      │        │  (namespace: argocd)                 ││
│  │  ┌───────────────┐  │        │                                      ││
│  │  │  HashiCorp    │  │        │  ┌──────────────────────────────┐   ││
│  │  │  Vault        │◄─┼──②────►│  │  argocd-repo-server pod      │   ││
│  │  │  :8200        │  │        │  │                              │   ││
│  │  │               │  │        │  │  ┌──────────┐  ┌─────────┐  │   ││
│  │  │  KV engine:   │  │        │  │  │  argocd  │  │   AVP   │  │   ││
│  │  │  secrets/     │  │   ①    │  │  │  main    │  │ sidecar │  │   ││
│  │  │  data/        │──┼────────┼──│  │  container│  │  (CMP)  │  │   ││
│  │  │  demo-app     │  │        │  │  └──────────┘  └─────────┘  │   ││
│  │  └───────────────┘  │        │  └──────────────────────────────┘   ││
│  └─────────────────────┘        │                                      ││
│                                  │  ┌──────────────────────────────┐   ││
│  ┌─────────────────────┐   ③    │  │  namespace: demo              │   ││
│  │  GitHub              │────────►  │  Secret (values from Vault)  │   ││
│  │  demo-app/           │        │  │  Deployment                  │   ││
│  │  secret.yaml         │        │  │  Service                     │   ││
│  │  (with <placeholders>│        │  └──────────────────────────────┘   ││
│  └─────────────────────┘        └──────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────────────────┘
```

### Network Layout (kind + macOS)

```
  macOS Terminal → Vault (scripts/UI) : http://localhost:8200   (Docker port-map)
  Vault container → K8s API           : https://172.19.0.5:6443 (KIND_CP_IP)
  K8s Pods → Vault                    : http://172.19.0.6:8200  (VAULT_KIND_IP)
```

> Docker internal IPs (`172.19.x.x`) live inside Docker's Linux VM — they are NOT reachable from macOS terminal. Only `localhost:8200` works from the Mac.

---

## 4. Secret Injection Flow (Detailed)

This is exactly what happens when ArgoCD syncs the `demo-secret-app` application:

```
Step 1 — Git Pull
  ArgoCD detects drift (or manual sync triggered)
  ArgoCD pulls demo-app/ from GitHub
  Manifests contain <placeholder> tokens — not real secrets

Step 2 — AVP Plugin Invoked
  argocd-repo-server detects plugin annotation in secret.yaml:
    avp.kubernetes.io/path: "secrets/data/demo-app"
  Routes manifest generation to the AVP CMP sidecar

Step 3 — Kubernetes Auth Login
  AVP sidecar reads its own SA token:
    /var/run/secrets/kubernetes.io/serviceaccount/token
  POST http://172.19.0.6:8200/v1/auth/kubernetes/login
    { "jwt": "<sa-token>", "role": "argocd-role" }

Step 4 — Vault TokenReview Callback
  Vault receives the login request
  Vault calls K8s TokenReview API using vault-reviewer SA token:
    POST https://172.19.0.5:6443/apis/authentication.k8s.io/v1/tokenreviews
  K8s confirms:
    ServiceAccount = argocd-repo-server ✓
    Namespace      = argocd             ✓
  Vault checks role binding → argocd-policy matched
  Vault issues short-lived Vault token (TTL: 1h)

Step 5 — Secret Retrieval
  AVP uses Vault token to read:
    GET http://172.19.0.6:8200/v1/secrets/data/demo-app
  Vault returns:
    { username, password, api-key, db-host, db-name }

Step 6 — Placeholder Substitution
  AVP replaces tokens in secret.yaml:
    <username>  → "demo-user"
    <password>  → "super-secret-password"
    <api-key>   → "1234567890abcdef"
    <db-host>   → "postgres.internal"
    <db-name>   → "appdb"

Step 7 — Apply to Cluster
  ArgoCD applies the rendered manifest to the cluster
  K8s Secret "demo-secret" created in namespace "demo"
  Secret contains real Vault values — Git never saw them
```

---

## 5. Components Deployed

### Vault (Docker)

| Component | Detail |
|---|---|
| Image | `hashicorp/vault:1.15` |
| Mode | Dev (root token = `root`) |
| KV engine | `secrets/` (KV v2) |
| Auth method | Kubernetes (`/v1/auth/kubernetes`) |
| Policy | `argocd-policy` — read/list on `secrets/data/*` and `secrets/metadata/*` |
| Role | `argocd-role` — bound to `argocd-repo-server` SA in `argocd` namespace |

### ArgoCD (kind cluster)

| Component | Detail |
|---|---|
| Install | `core-install.yaml` (no Dex, no Redis) |
| Namespace | `argocd` |
| Plugin | AVP v1.17.0 as CMP sidecar on `argocd-repo-server` |
| Sidecar image | `alpine:3.18` (init container downloads AVP binary at startup) |
| Plugin config | `cmp-plugin-configmap.yaml` — triggers on `avp.kubernetes.io/path` annotation |

### Vault Reviewer ServiceAccount

```yaml
# vault-reviewer SA — allows Vault to call K8s TokenReview API
ServiceAccount: vault-reviewer (namespace: argocd)
ClusterRoleBinding: system:auth-delegator
Secret: vault-reviewer-token (long-lived, manually created for K8s 1.24+)
```

### AVP Credentials Secret

```yaml
# argocd-vault-plugin-credentials (namespace: argocd)
VAULT_ADDR:     http://172.19.0.6:8200   # Vault's kind network IP — NOT localhost
AVP_TYPE:       vault
AVP_AUTH_TYPE:  k8s
AVP_K8S_ROLE:   argocd-role
```

> With Kubernetes auth, no static Role ID or Secret ID is stored — only the Vault address and role name.

---

## 6. Demo App Manifest

`demo-app/secret.yaml` in Git (with placeholders):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: demo-secret
  namespace: demo
  annotations:
    avp.kubernetes.io/path: "secrets/data/demo-app"
type: Opaque
stringData:
  username: <username>
  password: <password>
  api-key: <api-key>
  db-host: <db-host>
  db-name: <db-name>
```

After AVP processes it (what gets applied to the cluster):

```yaml
stringData:
  username: demo-user
  password: super-secret-password
  api-key: 1234567890abcdef
  db-host: postgres.internal
  db-name: appdb
```

---

## 7. Auth Method Comparison

| | AppRole | Kubernetes Auth (this POC) |
|---|---|---|
| What is stored in K8s | Role ID + Secret ID (static) | Only Vault address + role name |
| Token rotation | Manual | Automatic — K8s rotates SA tokens |
| Identity proof | Shared static secret | Cryptographically signed pod SA JWT |
| Risk if credentials leak | Must rotate Secret ID | Nothing to rotate — token is pod-specific |
| Vault → K8s connectivity | Not required | Required (TokenReview API call) |
| Recommended for production | No | **Yes** |

---

## 8. Issues Encountered and Resolutions

All issues were hit during this POC and are documented with root causes.

### 8.1 Vault 403 on Every Kubernetes Login

**Root cause:** `disable_local_ca_jwt` defaults to `false`. When false, Vault looks for `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt` inside its own container. Since Vault runs in Docker (not K8s), this file doesn't exist — Vault silently ignores the configured `kubernetes_ca_cert` and falls back to broken behavior. Every login returns `403 permission denied`.

**Fix:** Always set `disable_local_ca_jwt: true` when Vault runs outside Kubernetes.

```json
{
  "kubernetes_host": "https://172.19.0.5:6443",
  "token_reviewer_jwt": "<vault-reviewer-token>",
  "kubernetes_ca_cert": "<cluster-ca>",
  "disable_local_ca_jwt": true,
  "disable_iss_validation": true
}
```

> This is the single most important configuration requirement for the production topology (Vault on GCP, clusters external).

---

### 8.2 `curl localhost:8200` Silently Drops Large Payloads on macOS

**Root cause:** Docker NAT on macOS truncates large POST bodies (JWT ~900 bytes + CA cert ~1100 bytes). The request appears to succeed but the body is empty → Vault receives an invalid config.

**Fix:** Copy the payload file into the Vault container and POST from inside using `docker exec`:

```bash
docker cp /tmp/vault-k8s-config.json vault-poc-dev:/tmp/vault-k8s-config.json
docker exec vault-poc-dev sh -c \
  "wget -qO- --header='X-Vault-Token: root' \
   --post-file=/tmp/vault-k8s-config.json \
   http://172.19.0.6:8200/v1/auth/kubernetes/config"
```

---

### 8.3 Wrong KV Engine Path

**Root cause:** Vault dev mode auto-creates a `secret/` engine. The actual data was written to a separately mounted `secrets/` engine. AVP annotation, policy HCL, and curl commands were all pointing to `secret/` instead of `secrets/`.

**Fix:** Match annotation path to where data actually lives:

```yaml
avp.kubernetes.io/path: "secrets/data/demo-app"   # note: secrets/ not secret/
```

Also update the Vault policy HCL to use `secrets/data/*` and `secrets/metadata/*`.

---

### 8.4 Vault Kubernetes Auth Roles Not Available in UI

**Root cause:** Vault's UI does not expose role management for the Kubernetes auth method — only the Configuration tab is shown. This is a known gap in Vault's UI.

**Fix:** Always use the API to create/verify roles:

```bash
# Create
curl -H "X-Vault-Token: root" --request POST \
  --data '{"bound_service_account_names":["argocd-repo-server"],"bound_service_account_namespaces":["argocd"],"policies":["argocd-policy"],"ttl":"1h"}' \
  http://localhost:8200/v1/auth/kubernetes/role/argocd-role

# List
curl -H "X-Vault-Token: root" --request LIST \
  http://localhost:8200/v1/auth/kubernetes/role
```

---

### 8.5 kustomization.yaml Conflict with AVP Plugin

**Root cause:** ArgoCD auto-detects `kustomization.yaml` in the app directory and routes to Kustomize — even when an AVP plugin is explicitly configured in the Application spec.

**Fix:** Delete `demo-app/kustomization.yaml`. AVP works in plain directory mode on raw `*.yaml` files.

---

### 8.6 ImagePullBackOff for ArgoCD Components (kind + macOS)

**Root cause:** `install.yaml` includes Dex (SSO) and Redis (caching) — both are large images that fail with `unexpected EOF` when pulled inside the kind VM over a flaky network.

**Fix (Option A — preferred):** Use `core-install.yaml` instead. No Dex or Redis are included.

**Fix (Option B):** Pull on Mac and load directly into kind (bypasses in-VM network):

```bash
docker pull redis:7.0.14-alpine
kind load docker-image redis:7.0.14-alpine --name desktop
```

---

### 8.7 AVP Sidecar ImagePullBackOff (ubuntu:22.04)

**Root cause:** The AVP sidecar was initially configured with `ubuntu:22.04` — a 77MB image that was not cached and failed to pull over the flaky kind VM network.

**Fix:** Change to `alpine:3.18` — already cached on the node from the init container, same architecture, works as a minimal shell runtime.

---

## 9. Verification Results

```bash
# Confirm secret was created and populated from Vault (not placeholders)
kubectl get secret demo-secret -n demo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Output:
api-key: 1234567890abcdef
db-host: postgres.internal
db-name: appdb
password: super-secret-password
username: demo-user
```

**✅ POC success criteria met:**

| Check | Result |
|---|---|
| `demo-secret` K8s Secret exists | ✅ Created by ArgoCD sync |
| Secret values = real Vault data | ✅ All 5 keys populated correctly |
| Git still shows `<placeholders>` | ✅ No secrets in Git |
| No static credentials in K8s | ✅ Only `VAULT_ADDR` + `AVP_K8S_ROLE` stored |
| Kubernetes auth (no AppRole) | ✅ Pod SA token used end-to-end |

---

## 10. Key Learnings for Production Rollout

### Must-do for Vault outside Kubernetes (production topology)

1. **`disable_local_ca_jwt: true`** in every kubernetes auth mount config — without this, auth silently fails with 403.
2. **One auth mount per cluster** — e.g., `auth/kubernetes-stage`, `auth/kubernetes-prod-us`. Each cluster needs its own config pointing to that cluster's API endpoint.
3. **vault-reviewer SA** must be deployed in the `argocd` namespace of each cluster — Vault needs this to validate pod tokens via TokenReview.
4. **Vault must be reachable from pods, not just from your terminal** — `localhost:8200` only works from the machine running Docker. Pods need the actual resolvable hostname or IP.
5. **Vault must be able to reach each cluster's K8s API on port 443** — this is the direction most teams miss in firewall requests.

### AVP-specific

6. **Never put `kustomization.yaml` in the same directory as AVP-managed manifests** — ArgoCD will route to Kustomize and bypass AVP entirely.
7. **Credentials secret must exist before patching argocd-repo-server** — the AVP sidecar reads it on startup and crashes if missing.
8. **VAULT_ADDR in the credentials secret must be the address reachable from inside pods**, not from your terminal.

### Security posture

9. **Kubernetes auth is strictly better than AppRole** for GitOps — no static credentials, pod identity is cryptographically verified, tokens auto-rotate.
10. **Secrets in Git should only ever be `<placeholder>` tokens** — the annotation path is metadata, not a secret.

---

## 11. Production Readiness Checklist

For rolling this out to BDCD clusters (stage, prod-eu, prod-us, acc):

- [ ] Vault stable external address confirmed (`vault.ops.duckutil.net` / `vault.stg.ops.duckutil.net`)
- [ ] Network rules open: cluster egress IPs → Vault port 443
- [ ] Network rules open: Vault IP → each cluster K8s API port 443
- [ ] `vault-reviewer` SA deployed in `argocd` namespace of each cluster
- [ ] Separate Vault kubernetes auth mount per cluster (e.g., `auth/kubernetes-stage`)
- [ ] Each mount configured with correct cluster API endpoint, CA cert, reviewer token, and `disable_local_ca_jwt: true`
- [ ] `argocd-role` created in each mount, bound to `argocd-repo-server` SA
- [ ] `argocd-policy` created with read access to relevant secret paths
- [ ] `argocd-vault-plugin-credentials` secret created in `argocd` namespace of each cluster
- [ ] AVP sidecar patch applied to `argocd-repo-server` in each cluster
- [ ] End-to-end test: deploy a test app with `<placeholder>` and confirm real values injected

---

## 12. Repository Structure

```
argocd-vault-poc/
├── README.md                              # Full step-by-step setup guide
├── POC-REPORT.md                          # This document
├── Makefile                               # Helper commands
├── vault/
│   ├── docker-compose.dev.yml             # Vault dev mode (quick start)
│   ├── docker-compose.yml                 # Vault production-like (file storage)
│   ├── config/vault.hcl                   # Vault server config
│   └── scripts/
│       ├── 01-init-vault.sh               # Init & unseal (prod mode only)
│       └── 02-setup-vault.sh              # Secrets, policy, K8s auth setup
├── argocd/
│   ├── install/
│   │   ├── namespace.yaml                 # argocd namespace
│   │   └── vault-reviewer-sa.yaml         # SA for Vault TokenReview
│   ├── plugins/
│   │   ├── cmp-plugin-configmap.yaml      # AVP plugin definition
│   │   └── avp-credentials-secret.yaml.template
│   ├── patches/
│   │   └── argocd-repo-server-patch.yaml  # Adds AVP sidecar (alpine:3.18)
│   └── apps/
│       └── demo-secret-app.yaml           # ArgoCD Application manifest
└── demo-app/
    ├── namespace.yaml
    ├── deployment.yaml
    ├── service.yaml
    └── secret.yaml                        # Secret with <placeholder> tokens
```
