#!/usr/bin/env bash
# Read secrets from .env.programmer and create SealedSecrets.
# Requirements: kubectl, kubeseal
#
# .env.programmer must define:
#   GITHUB_TOKEN=ghp_...          (Argo CD repo access for private chart repo)
#   GHCR_AUTH=<base64 of user:token>  (docker config auth for ghcr.io)
#   POSTGRES_PASSWORD=...         (must match URL-encoded segment in DATABASE_URL)
#   DATABASE_URL=postgresql://user:password@programmer-server-postgresql:5432/programmer

set -euo pipefail

NAMESPACE="programmer"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BASE_DIR="$SCRIPT_DIR"
ENV_FILE="$SCRIPT_DIR/.env.programmer"
CERT_FILE="$(mktemp)"
KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/.kubeconfig}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env.programmer not found."
  echo "Create it with the following variables:"
  echo "  GITHUB_TOKEN=ghp_..."
  echo "  GHCR_AUTH=<base64 of user:token>"
  echo "  POSTGRES_PASSWORD=..."
  echo "  DATABASE_URL=postgresql://postgres:ENCODED_PASSWORD@programmer-server-postgresql:5432/programmer"
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

: "${GITHUB_TOKEN:?GITHUB_TOKEN not set in .env.programmer}"
: "${GHCR_AUTH:?GHCR_AUTH not set in .env.programmer}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD not set in .env.programmer}"
: "${DATABASE_URL:?DATABASE_URL not set in .env.programmer}"

echo "==> Fetching sealed-secrets public cert from cluster..."
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  --kubeconfig "$KUBECONFIG" \
  > "$CERT_FILE"

echo "==> Sealing ghcr-pull-secret..."
DOCKER_CONFIG_JSON="{\"auths\":{\"ghcr.io\":{\"auth\":\"${GHCR_AUTH}\"}}}"
kubectl --kubeconfig "$KUBECONFIG" create secret generic ghcr-pull-secret \
  --namespace="$NAMESPACE" \
  --from-literal=.dockerconfigjson="$DOCKER_CONFIG_JSON" \
  --type=kubernetes.io/dockerconfigjson \
  --dry-run=client -o yaml \
| kubeseal --cert "$CERT_FILE" --format yaml \
> "$BASE_DIR/programmer-ghcr-sealed-secret.yaml"

echo "==> Sealing programmer-github-token (namespace: argocd)..."
kubectl --kubeconfig "$KUBECONFIG" create secret generic programmer-github-token \
  --namespace="argocd" \
  --from-literal=token="$GITHUB_TOKEN" \
  --dry-run=client -o yaml \
| kubeseal --cert "$CERT_FILE" --format yaml \
> "$BASE_DIR/programmer-github-token-sealed-secret.yaml"

echo "==> Sealing programmer-server-app (namespace: $NAMESPACE)..."
kubectl --kubeconfig "$KUBECONFIG" create secret generic programmer-server-app \
  --namespace="$NAMESPACE" \
  --from-literal=database-url="$DATABASE_URL" \
  --from-literal=postgres-password="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml \
| kubectl --kubeconfig "$KUBECONFIG" annotate --local -f - \
    argocd.argoproj.io/sync-wave=-3 \
    --dry-run=client -o yaml \
| kubeseal --cert "$CERT_FILE" --format yaml \
> "$BASE_DIR/programmer-app-sealed-secret.yaml"

rm -f "$CERT_FILE"
echo "==> Done: $BASE_DIR/programmer-*-sealed-secret.yaml"
