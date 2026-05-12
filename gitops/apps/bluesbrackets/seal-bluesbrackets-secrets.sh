#!/usr/bin/env bash
# Read secrets from .env.bluesbrackets and create SealedSecrets.
# Requirements: kubectl, kubeseal

set -euo pipefail

NAMESPACE="bluesbrackets"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BASE_DIR="$SCRIPT_DIR"
ENV_FILE="$SCRIPT_DIR/.env.bluesbrackets"
CERT_FILE="$(mktemp)"
KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/.kubeconfig}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env.bluesbrackets not found."
  echo "Create it with the following variables:"
  echo "  GITHUB_TOKEN=ghp_..."
  echo "  GHCR_AUTH=<base64 of user:token>"
  exit 1
fi

# Load secrets from .env.bluesbrackets
source "$ENV_FILE"

: "${GITHUB_TOKEN:?GITHUB_TOKEN not set in .env.bluesbrackets}"
: "${GHCR_AUTH:?GHCR_AUTH not set in .env.bluesbrackets}"

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
> "$BASE_DIR/bluesbrackets-ghcr-sealed-secret.yaml"

echo "==> Sealing bluesbrackets-github-token (namespace: argocd)..."
kubectl --kubeconfig "$KUBECONFIG" create secret generic bluesbrackets-github-token \
  --namespace="argocd" \
  --from-literal=token="$GITHUB_TOKEN" \
  --dry-run=client -o yaml \
| kubeseal --cert "$CERT_FILE" --format yaml \
> "$BASE_DIR/bluesbrackets-github-token-sealed-secret.yaml"

rm -f "$CERT_FILE"
echo "==> Done: $BASE_DIR/bluesbrackets-*-sealed-secret.yaml"
