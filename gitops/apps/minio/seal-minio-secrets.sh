#!/usr/bin/env bash
# Creates a SealedSecret with MinIO root credentials.
# Requirements: kubectl, kubeseal, .env.minio file

set -euo pipefail

NAMESPACE="minio"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.minio"
CERT_FILE="$(mktemp)"
OUTPUT_FILE="$SCRIPT_DIR/minio-sealed-secret.yaml"

if [[ ! -f "$ENV_FILE" ]]; then
  cat <<EOF
ERROR: $ENV_FILE not found.

Create it with the following content:
  MINIO_ROOT_USER=admin
  MINIO_ROOT_PASSWORD=<min-8-chars-password>
EOF
  exit 1
fi

source "$ENV_FILE"

: "${MINIO_ROOT_USER:?MINIO_ROOT_USER not set in .env.minio}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD not set in .env.minio}"

echo "==> Fetching sealed-secrets public cert from cluster..."
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  --kubeconfig "$SCRIPT_DIR/../../../.kubeconfig" \
  > "$CERT_FILE"

echo "==> Creating SealedSecret minio-credentials in namespace $NAMESPACE..."
kubectl create secret generic minio-credentials \
  --namespace="$NAMESPACE" \
  --from-literal=rootUser="$MINIO_ROOT_USER" \
  --from-literal=rootPassword="$MINIO_ROOT_PASSWORD" \
  --dry-run=client \
  -o yaml \
  | kubeseal \
      --cert "$CERT_FILE" \
      --format yaml \
  > "$OUTPUT_FILE"

rm -f "$CERT_FILE"

echo "==> Done! SealedSecret written to: $OUTPUT_FILE"
echo "==> Commit and push to apply."
