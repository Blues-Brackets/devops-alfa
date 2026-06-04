#!/usr/bin/env bash
# Creates SealedSecrets for Velero local and remote backup locations.
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

Create it with the following content:
  LOCAL_ACCESS_KEY=<minio-root-user>
  LOCAL_SECRET_KEY=<minio-root-password>
  REMOTE_ACCESS_KEY=<your-ovh-s3-access-key>
  REMOTE_SECRET_KEY=<your-ovh-s3-secret-key>
EOF
  exit 1
fi

source "$ENV_FILE"

: "${LOCAL_ACCESS_KEY:?LOCAL_ACCESS_KEY not set in .env.velero}"
: "${LOCAL_SECRET_KEY:?LOCAL_SECRET_KEY not set in .env.velero}"
: "${REMOTE_ACCESS_KEY:?REMOTE_ACCESS_KEY not set in .env.velero}"
: "${REMOTE_SECRET_KEY:?REMOTE_SECRET_KEY not set in .env.velero}"

echo "==> Fetching sealed-secrets public cert from cluster..."
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  --kubeconfig "$SCRIPT_DIR/../../../.kubeconfig" \
  > "$CERT_FILE"

create_sealed_secret() {
  local secret_name="$1"
  local access_key="$2"
  local secret_key="$3"
  local credentials_content

  # Velero expects a credentials file in AWS CLI format.
  credentials_content="[default]
aws_access_key_id=${access_key}
aws_secret_access_key=${secret_key}"

  kubectl create secret generic "$secret_name" \
    --namespace="$NAMESPACE" \
    --from-literal=cloud="$credentials_content" \
    --dry-run=client \
    -o yaml \
    | kubeseal \
        --cert "$CERT_FILE" \
        --format yaml
}

echo "==> Creating SealedSecrets for Velero backup locations in namespace $NAMESPACE..."
create_sealed_secret "velero-local-credentials" "$LOCAL_ACCESS_KEY" "$LOCAL_SECRET_KEY" > "$OUTPUT_FILE"
printf "\n---\n" >> "$OUTPUT_FILE"
create_sealed_secret "velero-remote-credentials" "$REMOTE_ACCESS_KEY" "$REMOTE_SECRET_KEY" >> "$OUTPUT_FILE"

rm -f "$CERT_FILE"

echo "==> Done! SealedSecrets written to: $OUTPUT_FILE"
echo "==> Commit and push to apply."
