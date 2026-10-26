#!/usr/bin/env bash
# Registers a private Git repo in ArgoCD with a token read from a file, then applies the root app.
# usage: KUBECONFIG=... ./scripts/register-repo.sh <https git url> <token file> [git user]
set -euo pipefail

REPO_URL="${1:?usage: register-repo.sh <https git url> <token file> [git user]}"
TOKEN_FILE="${2:?usage: register-repo.sh <https git url> <token file> [git user]}"
GIT_USER="${3:-git}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ -r "$TOKEN_FILE" ]] || { echo "Token file not readable: $TOKEN_FILE" >&2; exit 1; }

kubectl -n argocd create secret generic repo-monitoring-only \
  --from-literal=type=git \
  --from-literal=url="$REPO_URL" \
  --from-literal=username="$GIT_USER" \
  --from-file=password=<(tr -d '\r\n' < "$TOKEN_FILE") \
  --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
  | kubectl apply -f -

kubectl apply -f "$ROOT/bootstrap/root-app.yaml"
echo "Applied monitoring-root. Watch it with: kubectl -n argocd get applications"
