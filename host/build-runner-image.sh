#!/usr/bin/env bash
set -euo pipefail
OKD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export OKD_ROOT
. "$OKD_ROOT/scripts/lib/values.sh"
okd_require REGISTRY IMAGE_NAMESPACE OPENSHELL_BIN FULLSEND_BIN || exit 1
D="$OKD_ROOT/image"
mkdir -p "$D"
install -m 0755 "$OPENSHELL_BIN" "$D/openshell"
install -m 0755 "$FULLSEND_BIN" "$D/fullsend"
cd "$D"
podman build -t fullsend-runner-okd:dev . 2>&1 | tail -20
echo "== local image =="
podman images fullsend-runner-okd
echo "== login =="
oc registry login --to "$HOME/.config/containers/auth.json" 2>&1 | tail -3
oc -n fullsend get imagestream fullsend-runner-okd >/dev/null 2>&1 || oc -n fullsend create imagestream fullsend-runner-okd
echo "== push =="
podman push fullsend-runner-okd:dev ${REGISTRY}/${IMAGE_NAMESPACE}/fullsend-runner-okd:dev 2>&1 | tail -5
echo "== imagestream =="
oc -n fullsend get imagestream fullsend-runner-okd
