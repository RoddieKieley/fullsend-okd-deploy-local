#!/usr/bin/env bash
set -uo pipefail
OKD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export OKD_ROOT
. "$OKD_ROOT/scripts/lib/values.sh"
T="${SECRETS_DIR:-$OKD_ROOT/../tmp}"
NS="$INFERENCE_NAMESPACE"
set -a; source "$T/litellm.env"; set +a

oc -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: litellm
  namespace: ${INFERENCE_NAMESPACE}
spec:
  to:
    kind: Service
    name: litellm
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
YAML

HOST=$(oc -n "$NS" get route litellm -o jsonpath='{.spec.host}')
echo "route host: $HOST"

echo "== test through the route from a pod =="
oc -n "$NS" delete job litellm-route-test --ignore-not-found >/dev/null 2>&1
oc -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: litellm-route-test
  namespace: $NS
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: c
          image: registry.access.redhat.com/ubi10/ubi-minimal:latest
          env:
            - name: KEY
              valueFrom: { secretKeyRef: { name: litellm-master-key, key: master-key } }
          command: ["/bin/sh","-c"]
          args:
            - |
              curl -s -o /tmp/r -w 'status=%{http_code}\n' --max-time 120 -X POST \
                https://$HOST/v1/chat/completions \
                -H "Authorization: Bearer \$KEY" -H 'Content-Type: application/json' \
                -d '{"model":"qwen38","messages":[{"role":"user","content":"Reply with the single word: pong"}],"max_tokens":64}'
              head -c 400 /tmp/r; echo
YAML
for i in $(seq 1 30); do
  st=$(oc -n "$NS" get pods -l job-name=litellm-route-test --no-headers 2>/dev/null | awk '{print $3}' | head -1)
  case "$st" in Completed|Error) break ;; esac
  sleep 5
done
oc -n "$NS" logs job/litellm-route-test 2>&1 | head -20
echo "ROUTE_HOST=$HOST"
