#!/usr/bin/env bash
# Read secrets from .env.monitoring and create SealedSecrets.
# Requirements: kubectl, kubeseal
#
# .env.monitoring must define:
#   SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
#   GRAFANA_SA_TOKEN=glsa_xxxx  (Grafana Service Account token, role: Admin)

set -euo pipefail

NAMESPACE="observability"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BASE_DIR="$SCRIPT_DIR"
ENV_FILE="$SCRIPT_DIR/.env.monitoring"
CERT_FILE="$(mktemp)"
KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/.kubeconfig}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env.monitoring not found."
  echo "Create it with the following variables:"
  echo "  SLACK_WEBHOOK_URL=https://hooks.slack.com/services/..."
  exit 1
fi

source "$ENV_FILE"

: "${SLACK_WEBHOOK_URL:?SLACK_WEBHOOK_URL not set in .env.monitoring}"
: "${GRAFANA_SA_TOKEN:?GRAFANA_SA_TOKEN not set in .env.monitoring}"

echo "==> Fetching sealed-secrets public cert from cluster..."
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  --kubeconfig "$KUBECONFIG" \
  > "$CERT_FILE"

echo "==> Sealing alertmanager-slack-webhook..."
kubectl --kubeconfig "$KUBECONFIG" create secret generic alertmanager-slack-webhook \
  --namespace="$NAMESPACE" \
  --from-literal=webhookUrl="$SLACK_WEBHOOK_URL" \
  --dry-run=client -o yaml \
| kubeseal --cert "$CERT_FILE" --format yaml \
> "$BASE_DIR/grafana-resources/alertmanager-slack-webhook-sealedsecret.yaml"

echo "==> Sealing grafana-sa-token..."
kubectl --kubeconfig "$KUBECONFIG" create secret generic grafana-sa-token \
  --namespace="$NAMESPACE" \
  --from-literal=token="$GRAFANA_SA_TOKEN" \
  --dry-run=client -o yaml \
| kubeseal --cert "$CERT_FILE" --format yaml \
> "$BASE_DIR/grafana-resources/grafana-sa-token-sealedsecret.yaml"

echo "==> Done."
rm -f "$CERT_FILE"
