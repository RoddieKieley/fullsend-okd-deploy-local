#!/usr/bin/env bash
set -uo pipefail
OKD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export OKD_ROOT
. "$OKD_ROOT/scripts/lib/values.sh"
okd_require REGISTRY IMAGE_NAMESPACE || exit 1
REG="$REGISTRY"
oc registry login --to "$HOME/.config/containers/auth.json" >/dev/null 2>&1
podman login "$REG" -u "$(oc whoami)" -p "$(oc whoami -t)" --tls-verify=false 2>&1 | tail -3
podman push --tls-verify=false fullsend-runner-okd:dev "$REG/${IMAGE_NAMESPACE}/fullsend-runner-okd:dev" 2>&1 | tail -6
echo "exit=$?"
oc -n "$NAMESPACE" get imagestream fullsend-runner-okd -o jsonpath='{.status.tags[*].tag}{"\n"}' 2>&1
