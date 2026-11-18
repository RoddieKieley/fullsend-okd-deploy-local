#!/usr/bin/env bash
# In-cluster smoke test: gateway auth -> sandbox pod -> policy -> Ready -> exec.
# Mirrors the flags `fullsend run` uses (--keep --no-auto-providers --no-tty
# --policy --detach) so a green smoke means the fullsend path itself works.
set -uo pipefail
source /scripts/openshell-auth.sh
openshell_auth_init

echo "== whoami =="; openshell whoami || exit 10

NAME="smoke-$(head -c3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
echo "== create $NAME =="
openshell sandbox create --name "$NAME" --keep --no-auto-providers --no-tty \
  --from ghcr.io/fullsend-ai/fullsend-sandbox@sha256:8e17e6120e17debdcabff5eb331a7cb7757b09ec3d586010c9d7956fd1fc5633 \
  --policy /scripts/base-policy.yaml --detach -- sleep infinity
echo "create rc=$?"

echo "== wait for Ready =="
for i in $(seq 1 60); do
  out=$(openshell sandbox get "$NAME" 2>&1)
  phase=$(printf '%s\n' "$out" | sed -n 's/^.*Phase:[[:space:]]*//p' | head -1)
  echo "[$i] phase=${phase:-unknown}"
  [ "${phase}" = "Ready" ] && break
  [ "${phase}" = "Failed" ] && break
  sleep 5
done
openshell sandbox list

echo "== exec =="
openshell sandbox exec "$NAME" -- sh -c '
  id
  (command -v opencode && opencode --version) || echo "opencode MISSING"
  (command -v gh && gh --version | head -1) || echo "gh MISSING"
  (command -v python3 && python3 -c "import jsonschema; print(\"jsonschema ok\")") || echo "jsonschema MISSING"
  curl -s -o /dev/null -w "ollama -> %{http_code}\n" --max-time 10 http://<model-host>:8080/v1/models || echo "ollama unreachable"
'
echo "exec rc=$?"

echo "== cleanup =="
openshell sandbox delete "$NAME"
openshell sandbox list
