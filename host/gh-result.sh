#!/usr/bin/env bash
set -uo pipefail
HOST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OKD_ROOT=$(dirname "$HOST_DIR")
D="$OKD_ROOT"
T="${SECRETS_DIR:-}"
. "$OKD_ROOT/scripts/lib/values.sh"
: "${SECRETS_DIR:?SECRETS_DIR must be set (values.local.env)}"
T="$SECRETS_DIR"
ORG="${WORKSPACE_ROOT:-$(dirname "$(dirname "$OKD_ROOT")")}"

bash "$HOST_DIR/render-manifests.sh" >/dev/null 2>&1 || true
TOK=$(sed -n 's/^GH_TOKEN=//p' "$T/gh.env" | head -1)

echo "===== job log: post-script + results ====="
oc -n fullsend logs job/fullsend-triage --tail=60 2>&1 | sed -n '/Running post-script/,$p'

echo
echo "===== agent-result.json ====="
oc -n fullsend delete pod outview --ignore-not-found >/dev/null
sed 's|/out/fs-tri-[a-z0-9]*|/out|' "$D/k8s/rendered/outview-pod.yaml" > "$T/outview-any.yaml"
# point at the newest run directory
NEWEST=$(oc -n fullsend get pods -l app=fullsend-agent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
oc -n fullsend logs job/fullsend-triage 2>&1 | grep -o 'Run directory: /work/output/[a-z0-9-]*' | tail -1
cat > "$T/outview-any.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: outview
  namespace: fullsend
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: image-registry.openshift-image-registry.svc:5000/fullsend/fullsend-runner-okd:dev
      command: ["/bin/bash","-c"]
      args:
        - |
          R=$(ls -dt /out/*/ | head -1)
          echo "run: $R"
          find "$R" -name agent-result.json -exec cat {} \;
      volumeMounts:
        - name: out
          mountPath: /out
  volumes:
    - name: out
      persistentVolumeClaim:
        claimName: fullsend-output
YAML
oc -n fullsend apply -f "$T/outview-any.yaml" >/dev/null
for i in $(seq 1 20); do
  p=$(oc -n fullsend get pod outview -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$p" == "Succeeded" || "$p" == "Failed" ]] && break
  sleep 3
done
oc -n fullsend logs outview 2>&1 | head -60
oc -n fullsend delete pod outview --ignore-not-found >/dev/null

echo
echo "===== full last comment ====="
GH_TOKEN="$TOK" gh issue view 1 --repo ${PROBE_REPO} --json comments \
  --jq '.comments[-1].body' 2>&1
