#!/usr/bin/env bash
# Replaces the placeholder Git URL in every manifest, e.g. ./scripts/set-repo-url.sh https://github.com/acme/monitoring.git
set -euo pipefail

URL="${1:?usage: set-repo-url.sh <https git url> [branch]}"
BRANCH="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

grep -rl 'github.com/CHANGE_ME/monitoring-only.git' "$ROOT" --include='*.yaml' | while read -r f; do
  sed -i "s#https://github.com/CHANGE_ME/monitoring-only.git#${URL}#g" "$f"
  [[ -n "$BRANCH" ]] && sed -i "s#targetRevision: main#targetRevision: ${BRANCH}#; s#revision: main#revision: ${BRANCH}#" "$f"
  echo "updated $f"
done
