#!/usr/bin/env bash
# Creates a SealedSecret with OVH S3 credentials for Velero.
# Requirements: kubectl, kubeseal, .env.velero file

set -euo pipefail

NAMESPACE="velero"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.velero"
CERT_FILE="$(mktemp)"
OUTPUT_FILE="$SCRIPT_DIR/velero-s3-sealed-secret.yaml"

if [[ ! -f "$ENV_FILE" ]]; then
  cat <<EOF
ERROR: $ENV_FILE not found.

Create it with the following content for MinIO (dev/test):
  OVH_ACCESS_KEY=<minio-root-user>
  OVH_SECRET_KEY=<minio-root-password>

Or for OVH S3 (production):
  OVH_ACCESS_KEY=<your-ovh-s3-access-key>
  OVH_SECRET_KEY=<your-ovh-s3-secret-key>
EOF
  exit 1
fi

source "$ENV_FILE"

: "${OVH_ACCESS_KEY:?OVH_ACCESS_KEY not set in .env.velero}"
: "${OVH_SECRET_KEY:?OVH_SECRET_KEY not set in .env.velero}"

echo "==> Fetching sealed-secrets public cert from cluster..."
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  --kubeconfig "$SCRIPT_DIR/../../../.kubeconfig" \
  > "$CERT_FILE"

# Velero expects a credentials file in AWS CLI format
CREDENTIALS_CONTENT="[default]
aws_access_key_id=${OVH_ACCESS_KEY}
aws_secret_access_key=${OVH_SECRET_KEY}"

echo "==> Creating SealedSecret velero-s3-credentials in namespace $NAMESPACE..."
kubectl create secret generic velero-s3-credentials \
  --namespace="$NAMESPACE" \
  --from-literal=cloud="$CREDENTIALS_CONTENT" \
  --dry-run=client \
  -o yaml \
  | kubeseal \
      --cert "$CERT_FILE" \
      --format yaml \
  > "$OUTPUT_FILE"

rm -f "$CERT_FILE"

echo "==> Done! SealedSecret written to: $OUTPUT_FILE"
echo "==> Commit and push to apply."
