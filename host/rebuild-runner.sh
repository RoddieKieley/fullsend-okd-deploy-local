#!/usr/bin/env bash
set -euo pipefail
OKD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export OKD_ROOT
. "$OKD_ROOT/scripts/lib/values.sh"

# The harness config carries the gateway URL as a literal (it is not expanded
# from the environment at run time). Render it from values at image-build time
# so the same harness fork works on any cluster.
LITELLM_ROUTE="${LITELLM_ROUTE:?LITELLM_ROUTE must be set (values.local.env)}"
python3 - "$D/agents-okd/config.yaml" "$LITELLM_ROUTE" <<'PYEOF'
import re, sys
path, url = sys.argv[1], sys.argv[2]
s = open(path).read()
new, n = re.subn(r'(?m)^(\s*url:\s*)\S+\s*$', lambda m: m.group(1) + url, s, count=1)
if n != 1:
    raise SystemExit(f"could not set inference gateway url in {path}")
open(path, "w").write(new)
print(f"harness gateway url -> {url}")
PYEOF
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
