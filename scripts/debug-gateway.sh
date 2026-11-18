#!/usr/bin/env bash
# Diagnose runner-pod -> OpenShell gateway connectivity.
set -uo pipefail
source /scripts/openshell-auth.sh
openshell_auth_init

echo "== dns =="
getent hosts gw-<openshell-namespace>.gw.<cluster-domain> || echo DNS_FAIL
getent hosts openshell-gateway.<openshell-namespace>.svc.cluster.local || echo DNS_FAIL2

echo "== curl route (verify tls chain) =="
curl -sv --max-time 10 https://gw-<openshell-namespace>.gw.<cluster-domain>/ 2>&1 | grep -E 'subject:|issuer:|SSL certificate|HTTP/|Connected|error' | head -20

echo "== curls to service =="
curl -sk --max-time 10 -o /dev/null -w 'svc:8080 -> %{http_code}\n' https://openshell-gateway.<openshell-namespace>.svc.cluster.local:8080 || echo FAIL

echo "== openshell whoami (default) =="
openshell whoami 2>&1 | head -6

echo "== openshell --gateway-insecure whoami (route) =="
openshell --gateway-insecure whoami 2>&1 | head -6

echo "== openshell --gateway-endpoint service (insecure) =="
OPENSHELL_GATEWAY_ENDPOINT=https://openshell-gateway.<openshell-namespace>.svc.cluster.local:8080 \
  openshell --gateway-insecure whoami 2>&1 | head -6

echo "== openshell status (verbose) =="
openshell -vv status 2>&1 | head -25
