#!/usr/bin/env bash
# Refresh the Gateway API CRDs shipped by the traefik component, from the official kubernetes-sigs release.
# Usage: hack/update-gateway-api.sh [version]   (default: latest release)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
v=${1:-$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/gateway-api/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')}
curl -fsSL "https://github.com/kubernetes-sigs/gateway-api/releases/download/$v/standard-install.yaml" \
  -o "$ROOT/helm/platform/traefik/gateway-api/standard-install.yaml"
echo "Gateway API CRDs: $v (standard channel)"
