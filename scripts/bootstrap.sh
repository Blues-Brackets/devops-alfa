#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  echo "Usage: $0 <git_repo_url> <git_username> <git_token>" >&2
  echo "Environment: GIT_REVISION (default HEAD) sets Argo CD source.targetRevision." >&2
  exit 0
fi

if [[ "$#" -ne 3 ]]; then
  echo "Usage: $0 <git_repo_url> <git_username> <git_token>" >&2
  exit 1
fi

export GIT_REPO_URL="$1"
export GIT_USERNAME="$2"
export GIT_TOKEN="$3"

apt update && apt upgrade -y
apt install -y curl git

curl -sfL https://get.k3s.io | sh -

kubectl get nodes
kubectl get pods -A

kubectl create namespace argocd

kubectl apply -n argocd \
  --server-side \
  --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl -n argocd rollout status deployment/argocd-server
kubectl -n argocd rollout status deployment/argocd-repo-server

kubectl -n argocd create secret generic gitops-repo \
  --from-literal=type=git \
  --from-literal=url="$GIT_REPO_URL" \
  --from-literal=username="$GIT_USERNAME" \
  --from-literal=password="$GIT_TOKEN" \
  --dry-run=client -o yaml \
  | kubectl label -f - argocd.argoproj.io/secret-type=repository --local -o yaml \
  | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cluster-gitops
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${GIT_REPO_URL}
    targetRevision: ${GIT_REVISION:-HEAD}
    path: gitops
    kustomize: {}
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

kubectl -n argocd get applications

kubectl get pods -n demo 2>/dev/null || echo "Namespace demo appears once cluster-gitops syncs and sample-nginx deploys."

kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

kubectl port-forward svc/argocd-server -n argocd 8080:443 --address 127.0.0.1
