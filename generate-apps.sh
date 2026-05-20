#!/usr/bin/env bash
set -euo pipefail

for f in appsets/*.yaml; do
  name=$(basename "$f" .yaml)
  echo "Generating argocd/${name}.yaml from $f"
  argocd appset generate "$f" -o yaml --grpc-web --auth-token "$TOKEN" \
    | yq '.[]' - \
    | sed 's/^apiVersion/---\napiVersion/' > "argocd/${name}.yaml"
done
