#!/usr/bin/env bash
# Read passwords from .env.passbolt and create a SealedSecret in base/.
# Requirements: kubectl, kubeseal

set -euo pipefail

NAMESPACE="passbolt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
ENV_FILE="$SCRIPT_DIR/.env.passbolt"
CERT_FILE="$(mktemp)"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env.passbolt not found."
  echo "Run first: bash scripts/1-generate-passbolt-passwords.sh"
  exit 1
fi

# Load passwords from .env.passbolt
source "$ENV_FILE"

: "${MARIADB_PASSWORD:?MARIADB_PASSWORD not set in .env.passbolt}"
: "${MARIADB_ROOT_PASSWORD:?MARIADB_ROOT_PASSWORD not set in .env.passbolt}"
: "${REDIS_PASSWORD:?REDIS_PASSWORD not set in .env.passbolt}"
: "${SMTP_USERNAME:?SMTP_USERNAME not set in .env.passbolt}"
: "${SMTP_PASSWORD:?SMTP_PASSWORD not set in .env.passbolt}"

echo "==> Fetching sealed-secrets public cert from cluster..."
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  > "$CERT_FILE"

echo "==> Sealing passbolt-env-secret..."
kubectl create secret generic passbolt-env-secret \
  --namespace="$NAMESPACE" \
  --from-literal=mariadb-root-password="$MARIADB_ROOT_PASSWORD" \
  --from-literal=mariadb-password="$MARIADB_PASSWORD" \
  --from-literal=redis-password="$REDIS_PASSWORD" \
  --from-literal=DATASOURCES_DEFAULT_DATABASE=passbolt \
  --from-literal=DATASOURCES_DEFAULT_USERNAME=passbolt \
  --from-literal=DATASOURCES_DEFAULT_PASSWORD="$MARIADB_PASSWORD" \
  --from-literal=CACHE_DEFAULT_PASSWORD="$REDIS_PASSWORD" \
  --from-literal=CACHE_CAKECORE_PASSWORD="$REDIS_PASSWORD" \
  --from-literal=CACHE_CAKEMODEL_PASSWORD="$REDIS_PASSWORD" \
  --from-literal=EMAIL_TRANSPORT_DEFAULT_USERNAME="$SMTP_USERNAME" \
  --from-literal=EMAIL_TRANSPORT_DEFAULT_PASSWORD="$SMTP_PASSWORD" \
  --dry-run=client -o yaml \
| kubeseal --cert "$CERT_FILE" --format yaml \
> "$BASE_DIR/passbolt-sealed-secret.yaml"

rm -f "$CERT_FILE"
echo "==> Done: $BASE_DIR/passbolt-sealed-secret.yaml"

rm -f "$CERT_FILE"

