#!/usr/bin/env bash
# Read secrets from .env.czeq and create SealedSecrets.
# Requirements: kubectl, kubeseal

set -euo pipefail

NAMESPACE="czeq"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BASE_DIR="$SCRIPT_DIR"
ENV_FILE="$SCRIPT_DIR/.env.czeq"
CERT_FILE="$(mktemp)"
KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/.kubeconfig}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env.czeq not found."
  echo "Create it with the following variables:"
  echo "  BACKEND_ROOT_EMAIL=..."
  echo "  BACKEND_ROOT_PASSWORD=..."
  echo "  BACKEND_DB_PASSWORD=..."
  echo "  BETTER_AUTH_SECRET=..."
  echo "  GOOGLE_CLIENT_ID=..."
  echo "  GOOGLE_CLIENT_SECRET=..."
  echo "  APPLE_PRIVATE_KEY=..."
  echo "  CMS_ROOT_EMAIL=..."
  echo "  CMS_ROOT_PASSWORD=..."
  echo "  CMS_DB_PASSWORD=..."
  echo "  PAYLOAD_SECRET=..."
  echo "  MINIO_ROOT_USER=..."
  echo "  MINIO_ROOT_PASSWORD=..."
  echo "  ELEVENLABS_API_KEY=..."
  echo "  ELEVENLABS_VOICE_ID=..."
  echo "  ELEVENLABS_MODEL_ID=..."
  echo "  GITHUB_TOKEN=ghp_..."
  echo "  GHCR_AUTH=..."
  exit 1
fi

# Load secrets from .env.czeq
source "$ENV_FILE"

: "${BACKEND_ROOT_EMAIL:?BACKEND_ROOT_EMAIL not set in .env.czeq}"
: "${BACKEND_ROOT_PASSWORD:?BACKEND_ROOT_PASSWORD not set in .env.czeq}"
: "${BACKEND_DB_PASSWORD:?BACKEND_DB_PASSWORD not set in .env.czeq}"
: "${BETTER_AUTH_SECRET:?BETTER_AUTH_SECRET not set in .env.czeq}"
: "${CMS_ROOT_EMAIL:?CMS_ROOT_EMAIL not set in .env.czeq}"
: "${CMS_ROOT_PASSWORD:?CMS_ROOT_PASSWORD not set in .env.czeq}"
: "${CMS_DB_PASSWORD:?CMS_DB_PASSWORD not set in .env.czeq}"
: "${PAYLOAD_SECRET:?PAYLOAD_SECRET not set in .env.czeq}"
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER not set in .env.czeq}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD not set in .env.czeq}"
: "${ELEVENLABS_API_KEY:?ELEVENLABS_API_KEY not set in .env.czeq}"
: "${ELEVENLABS_VOICE_ID:?ELEVENLABS_VOICE_ID not set in .env.czeq}"
: "${ELEVENLABS_MODEL_ID:?ELEVENLABS_MODEL_ID not set in .env.czeq}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN not set in .env.czeq}"
: "${GHCR_AUTH:?GHCR_AUTH not set in .env.czeq}"

echo "==> Fetching sealed-secrets public cert from cluster..."
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  --kubeconfig "$KUBECONFIG" \
  > "$CERT_FILE"

echo "==> Sealing czeq-backend-secret..."
kubectl --kubeconfig "$KUBECONFIG" create secret generic czeq-backend-secret \
  --namespace="$NAMESPACE" \
  --from-literal=ROOT_EMAIL="$BACKEND_ROOT_EMAIL" \
  --from-literal=ROOT_PASSWORD="$BACKEND_ROOT_PASSWORD" \
  --from-literal=BETTER_AUTH_SECRET="$BETTER_AUTH_SECRET" \
  --from-literal=GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}" \
  --from-literal=GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}" \
  --from-literal=APPLE_PRIVATE_KEY="${APPLE_PRIVATE_KEY:-}" \
  --from-literal=POSTGRES_PASSWORD="$BACKEND_DB_PASSWORD" \
  --dry-run=client -o yaml \
| kubeseal --cert "$CERT_FILE" --format yaml \
> "$BASE_DIR/czeq-backend-sealed-secret.yaml"

echo "==> Sealing czeq-cms-secret..."
kubectl --kubeconfig "$KUBECONFIG" create secret generic czeq-cms-secret \
  --namespace="$NAMESPACE" \
  --from-literal=ROOT_EMAIL="$CMS_ROOT_EMAIL" \
  --from-literal=ROOT_PASSWORD="$CMS_ROOT_PASSWORD" \
  --from-literal=PAYLOAD_SECRET="$PAYLOAD_SECRET" \
  --from-literal=S3_ACCESS_KEY="$MINIO_ROOT_USER" \
  --from-literal=S3_SECRET_KEY="$MINIO_ROOT_PASSWORD" \
  --from-literal=POSTGRES_PASSWORD="$CMS_DB_PASSWORD" \
  --from-literal=ELEVENLABS_API_KEY="$ELEVENLABS_API_KEY" \
  --from-literal=ELEVENLABS_VOICE_ID="$ELEVENLABS_VOICE_ID" \
  --from-literal=ELEVENLABS_MODEL_ID="$ELEVENLABS_MODEL_ID" \
  --dry-run=client -o yaml \
| kubeseal --cert "$CERT_FILE" --format yaml \
> "$BASE_DIR/czeq-cms-sealed-secret.yaml"

echo "==> Sealing ghcr-pull-secret..."
DOCKER_CONFIG_JSON="{\"auths\":{\"ghcr.io\":{\"auth\":\"${GHCR_AUTH}\"}}}"
kubectl --kubeconfig "$KUBECONFIG" create secret generic ghcr-pull-secret \
  --namespace="$NAMESPACE" \
  --from-literal=.dockerconfigjson="$DOCKER_CONFIG_JSON" \
  --type=kubernetes.io/dockerconfigjson \
  --dry-run=client -o yaml \
| kubeseal --cert "$CERT_FILE" --format yaml \
> "$BASE_DIR/czeq-ghcr-sealed-secret.yaml"

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  echo "==> Sealing github-token (namespace: argocd)..."
  kubectl --kubeconfig "$KUBECONFIG" create secret generic github-token \
    --namespace="argocd" \
    --from-literal=token="$GITHUB_TOKEN" \
    --dry-run=client -o yaml \
  | kubeseal --cert "$CERT_FILE" --format yaml \
  > "$BASE_DIR/czeq-github-token-sealed-secret.yaml"
else
  echo "==> Skipping github-token (GITHUB_TOKEN not set)"
fi

rm -f "$CERT_FILE"
echo "==> Done: $BASE_DIR/czeq-*-sealed-secret.yaml"
