#!/usr/bin/env bash
# Deploy the in-cluster LiteLLM gateway from the deployment values.
set -uo pipefail
OKD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export OKD_ROOT
. "$OKD_ROOT/scripts/lib/values.sh"
okd_require CLUSTER_DOMAIN INFERENCE_NAMESPACE MODEL_API_BASE LITELLM_MODEL_QWEN_UPSTREAM || exit 1
T="${SECRETS_DIR:-$OKD_ROOT/../tmp}"
NS="$INFERENCE_NAMESPACE"

# master key: generated once, kept 600 next to the other lab secrets
if [[ ! -f "$T/litellm.env" ]]; then
  umask 077
  printf 'LITELLM_MASTER_KEY=%s\n' "$(openssl rand -hex 24)" > "$T/litellm.env"
  chmod 600 "$T/litellm.env"
fi
set -a; source "$T/litellm.env"; set +a

oc get ns "$NS" >/dev/null 2>&1 || oc new-project "$NS" >/dev/null

oc -n "$NS" create secret generic litellm-master-key \
  --from-literal=master-key="$LITELLM_MASTER_KEY" \
  --dry-run=client -o yaml | oc -n "$NS" apply -f -

ENMAAS_MODELS=""
if [[ -n "${ENMAAS_API_BASE:-}" && -n "${ENMAAS_MODEL_GLM:-}" && -n "${ENMAAS_MODEL_DEEPSEEK:-}" ]]; then
  ENMAAS_MODELS=$(cat <<EOF
${ENMAAS_MODELS}
EOF
)
fi

oc -n "$NS" apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-config
  namespace: ${INFERENCE_NAMESPACE}
data:
  config.yaml: |
    model_list:
      - model_name: qwen38
        litellm_params:
          model: openai/${LITELLM_MODEL_QWEN_UPSTREAM}
          api_base: ${MODEL_API_BASE}
          api_key: not-needed
      # Remote EnMaaS (Red Hat) gateway. The api key is never in this ConfigMap:
      # it reaches the pod from Secret/enmaas-api-key via ENMAAS_API_KEY.
      # Aliases stay slash-free so they map cleanly onto gateway/<alias> in
      # projects.json and fullsend/model=<slug> on the Jobs.
${ENMAAS_MODELS}
    general_settings:
      master_key: os.environ/LITELLM_MASTER_KEY
    litellm_settings:
      drop_params: true
      request_timeout: 600
      num_retries: 2
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: ${INFERENCE_NAMESPACE}
  labels: { app: litellm }
spec:
  replicas: 1
  selector:
    matchLabels: { app: litellm }
  template:
    metadata:
      labels: { app: litellm }
    spec:
      containers:
        - name: litellm
          image: ghcr.io/berriai/litellm:main-stable
          command: ["litellm"]
          args: ["--config", "/app/config.yaml", "--port", "4000"]
          env:
            - name: LITELLM_MASTER_KEY
              valueFrom:
                secretKeyRef: { name: litellm-master-key, key: master-key }
            # Remote EnMaaS credential: Secret only, never the ConfigMap.
            # Optional: absent on clusters without the remote provider.
            - name: ENMAAS_API_KEY
              valueFrom:
                secretKeyRef: { name: enmaas-api-key, key: api-key, optional: true }
            - name: HOME
              value: /tmp
            - name: TMPDIR
              value: /tmp
          ports:
            - containerPort: 4000
              name: http
          readinessProbe:
            httpGet: { path: /health/liveliness, port: 4000 }
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests: { cpu: 200m, memory: 512Mi }
            limits: { cpu: "2", memory: 2Gi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
            runAsNonRoot: true
            seccompProfile: { type: RuntimeDefault }
          volumeMounts:
            - name: config
              mountPath: /app/config.yaml
              subPath: config.yaml
              readOnly: true
      volumes:
        - name: config
          configMap: { name: litellm-config }
---
apiVersion: v1
kind: Service
metadata:
  name: litellm
  namespace: ${INFERENCE_NAMESPACE}
spec:
  selector: { app: litellm }
  ports:
    - name: http
      port: 4000
      targetPort: 4000
YAML

echo "== wait for rollout =="
oc -n "$NS" rollout status deploy/litellm --timeout=300s 2>&1 | tail -3
oc -n "$NS" get pods -o wide 2>&1 | tail -3
