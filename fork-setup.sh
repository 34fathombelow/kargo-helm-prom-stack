#!/usr/bin/env bash
set -euo pipefail

ORIGINAL_REPO="https://github.com/34fathombelow/kargo-helm-prom-stack.git"

usage() {
  echo "Usage: $0 <new-repo-url>"
  echo ""
  echo "  Example: $0 https://github.com/your-org/your-repo.git"
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

NEW_REPO="$1"

if [[ "$NEW_REPO" == "$ORIGINAL_REPO" ]]; then
  echo "Error: new repo URL is the same as the original. Nothing to do."
  exit 1
fi

echo "Replacing repo URL throughout the repository..."
echo "  From: $ORIGINAL_REPO"
echo "  To:   $NEW_REPO"
echo ""

FILES=(
  "appsets/kube-prometheus-stack.yaml"
  "argocd/kube-prometheus-stack.yaml"
  "kargo-resources/kube-prometheus-stack/stages.yaml"
  "kargo-resources/kube-prometheus-stack/promotiontask.yaml"
)

for f in "${FILES[@]}"; do
  if [[ -f "$f" ]]; then
    sed -i.bak "s|${ORIGINAL_REPO}|${NEW_REPO}|g" "$f" && rm -f "${f}.bak"
    echo "  Updated $f"
  else
    echo "  Warning: $f not found, skipping"
  fi
done

echo ""
echo "Done. Here's what to do next:"
echo ""
echo "  1. Review the changes:"
echo "       git diff"
echo ""
echo "  2. Update cluster names if your clusters are not named 'dev', 'test', 'prod':"
echo "       appsets/kube-prometheus-stack.yaml  (destination.name)"
echo "       kargo-resources/kube-prometheus-stack/stages.yaml  (shard)"
echo ""
echo "  3. Add GitHub Actions secrets to your forked repo:"
echo "       ARGOCD_SERVER  — ArgoCD server hostname (no https://)"
echo "       ARGOCD_TOKEN   — ArgoCD API token with appset-generate role"
echo ""
echo "  4. Commit and push your changes:"
echo "       git add -A && git commit -m 'chore: update repo URL for fork'"
echo "       git push"
echo ""
echo "  5. Bootstrap ArgoCD by applying the bootstrap manifest once:"
echo "       kubectl apply -f kargo-addons-bootstrap.yaml"
echo ""
echo "  6. Regenerate ArgoCD apps (or let the GitHub Action do it on push):"
echo "       ARGOCD_SERVER=<server> TOKEN=<token> ./generate-apps.sh"
