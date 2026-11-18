#!/usr/bin/env bash
set -euo pipefail
OKD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export OKD_ROOT
. "$OKD_ROOT/scripts/lib/values.sh"
okd_require REGISTRY IMAGE_NAMESPACE OPENSHELL_BIN FULLSEND_BIN WORKSPACE_ROOT || exit 1
D="$OKD_ROOT/image"
W="${AGENTS_WORKTREE:?AGENTS_WORKTREE must be set (harness worktree)}"
REG="$REGISTRY"

command -v rsync >/dev/null || { echo "rsync missing"; exit 1; }
rm -rf "$D/agents-okd"
rsync -a --exclude '.git' --exclude '.opencode' --exclude '.fullsend-cache' "$W/" "$D/agents-okd/"
install -m 0755 "$OPENSHELL_BIN" "$D/openshell"
install -m 0755 "$FULLSEND_BIN" "$D/fullsend"

cd "$D"
podman build -t fullsend-runner-okd:dev . 2>&1 | tail -8
podman push --tls-verify=false fullsend-runner-okd:dev "$REG/${IMAGE_NAMESPACE}/fullsend-runner-okd:dev" 2>&1 | tail -3
echo "== imagestream =="
oc -n fullsend get imagestream fullsend-runner-okd -o jsonpath='{.status.tags[*].tag}{"\n"}'
