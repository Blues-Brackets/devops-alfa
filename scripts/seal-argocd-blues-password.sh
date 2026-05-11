#!/usr/bin/env bash
set -euo pipefail

# Generates a local Argo CD user password, asks for approval,
# hashes it with bcrypt, seals values with kubeseal, and updates:
# gitops/env/prod/argocd-blues-password-sealedsecret.yaml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_FILE="${REPO_ROOT}/gitops/env/prod/argocd-blues-password-sealedsecret.yaml"

KUBECONFIG_PATH="${1:-}"
if [[ -z "${KUBECONFIG_PATH}" ]]; then
  echo "Usage: $0 /path/to/kubeconfig"
  exit 1
fi

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
  echo "ERROR: kubeconfig not found: ${KUBECONFIG_PATH}"
  exit 1
fi

if [[ ! -f "${TARGET_FILE}" ]]; then
  echo "ERROR: target file not found: ${TARGET_FILE}"
  exit 1
fi

for cmd in kubectl kubeseal; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: missing required command: ${cmd}"
    exit 1
  fi
done

gen_password() {
  local id random
  id="$(date +%Y%m%d)"
  random="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"
  printf 'BLUES-%s-%s' "${id}" "${random}"
}

bcrypt_password() {
  local password="$1"

  if command -v argocd >/dev/null 2>&1; then
    argocd account bcrypt --password "${password}"
    return 0
  fi

  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -bnBC 10 "" "${password}" | sed -E 's/^:[[:space:]]*//; s/[[:space:]]*$//'
    return 0
  fi

  echo "ERROR: cannot create bcrypt hash."
  echo "Install either 'argocd' CLI or 'htpasswd' (apache-tools/httpd-tools)."
  exit 1
}

PASSWORD=""
while true; do
  PASSWORD="$(gen_password)"
  echo
  echo "Generated password:"
  echo "  ${PASSWORD}"
  read -r -p "Accept this password? [y/N]: " answer
  case "${answer}" in
    y|Y|yes|YES) break ;;
    *) echo "Generating a new one..." ;;
  esac
done

PASSWORD_HASH="$(bcrypt_password "${PASSWORD}")"
PASSWORD_MTIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TMP_SECRET="$(mktemp)"
TMP_SEALED="$(mktemp)"
cleanup() {
  rm -f "${TMP_SECRET}" "${TMP_SEALED}"
}
trap cleanup EXIT

cat > "${TMP_SECRET}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-secret
  namespace: argocd
type: Opaque
stringData:
  accounts.blues.password: ${PASSWORD_HASH}
  accounts.blues.passwordMtime: ${PASSWORD_MTIME}
EOF

kubeseal \
  --kubeconfig "${KUBECONFIG_PATH}" \
  --controller-name sealed-secrets-controller \
  --controller-namespace sealed-secrets \
  --format yaml \
  < "${TMP_SECRET}" > "${TMP_SEALED}"

ENC_PASSWORD="$(awk '/^[[:space:]]*accounts\.blues\.password:/{print $2; exit}' "${TMP_SEALED}")"
ENC_PASSWORD_MTIME="$(awk '/^[[:space:]]*accounts\.blues\.passwordMtime:/{print $2; exit}' "${TMP_SEALED}")"

if [[ -z "${ENC_PASSWORD}" || -z "${ENC_PASSWORD_MTIME}" ]]; then
  echo "ERROR: could not extract encryptedData from kubeseal output."
  exit 1
fi

awk -v p="${ENC_PASSWORD}" -v m="${ENC_PASSWORD_MTIME}" '
  /^[[:space:]]+accounts\.blues\.password:/ {print "    accounts.blues.password: " p; next}
  /^[[:space:]]+accounts\.blues\.passwordMtime:/ {print "    accounts.blues.passwordMtime: " m; next}
  {print}
' "${TARGET_FILE}" > "${TARGET_FILE}.tmp"

mv "${TARGET_FILE}.tmp" "${TARGET_FILE}"

echo
echo "Updated SealedSecret file:"
echo "  ${TARGET_FILE}"
echo
echo "Copy password now and store it in your password manager:"
echo "  ${PASSWORD}"
