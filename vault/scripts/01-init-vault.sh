#!/usr/bin/env bash
# =============================================================================
# 01-init-vault.sh
# Initialize Vault, unseal it, and save the keys/token to .vault-keys
# Run this ONCE after first starting Vault with the file storage backend.
# For dev mode (docker-compose.dev.yml) this script is NOT needed.
# =============================================================================
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
KEYS_FILE="$(dirname "$0")/../.vault-keys"

echo "==> Waiting for Vault to be reachable at $VAULT_ADDR ..."
for i in $(seq 1 30); do
  if curl -sf "$VAULT_ADDR/v1/sys/health" > /dev/null 2>&1; then
    break
  fi
  echo "    Attempt $i/30 - not ready yet..."
  sleep 2
done

STATUS=$(curl -sf "$VAULT_ADDR/v1/sys/health" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('initialized','unknown'))" 2>/dev/null || echo "unknown")

if [ "$STATUS" = "True" ] || [ "$STATUS" = "true" ]; then
  echo "==> Vault is already initialized. Skipping init."
  echo "    Load your root token from: $KEYS_FILE"
  exit 0
fi

echo "==> Initializing Vault with 5 key shares, threshold 3 ..."
INIT_OUTPUT=$(curl -sf \
  --request POST \
  --data '{"secret_shares": 5, "secret_threshold": 3}' \
  "$VAULT_ADDR/v1/sys/init")

echo "$INIT_OUTPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('==> Vault initialized successfully!')
print()
print('Unseal Keys:')
for i, key in enumerate(d['keys_base64'], 1):
    print(f'  Key {i}: {key}')
print()
print(f'Root Token: {d[\"root_token\"]}')
" | tee "$KEYS_FILE"

chmod 600 "$KEYS_FILE"

echo ""
echo "==> Keys saved to $KEYS_FILE (chmod 600)"
echo "    IMPORTANT: Back these up securely before continuing!"
echo ""
echo "==> Now run 02-setup-vault.sh to unseal and configure Vault."
