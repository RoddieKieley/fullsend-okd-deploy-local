#!/usr/bin/env bash
# Diagnose runner-pod -> OpenShell gateway connectivity.
set -uo pipefail
source /scripts/openshell-auth.sh
openshell_auth_init

: "${OPENSHELL_GATEWAY_URL:?OPENSHELL_GATEWAY_URL must be set}"
SVC_HOST=${OPENSHELL_GATEWAY_URL#*://}; SVC_HOST=${SVC_HOST%%/*}
ROUTE_HOST=""
if [[ -n ${OPENSHELL_GATEWAY_ROUTE:-} ]]; then
  ROUTE_HOST=${OPENSHELL_GATEWAY_ROUTE#*://}; ROUTE_HOST=${ROUTE_HOST%%/*}
fi

echo "== dns =="
getent hosts "$SVC_HOST" || echo DNS_FAIL
[[ -n $ROUTE_HOST ]] && { getent hosts "$ROUTE_HOST" || echo DNS_FAIL2; }

echo "== curl route (verify tls chain) =="
if [[ -n $ROUTE_HOST ]]; then
  curl -sv --max-time 10 "https://$ROUTE_HOST/" 2>&1 \
    | grep -E 'subject:|issuer:|SSL certificate|HTTP/|Connected|error' | head -20
else
  echo "OPENSHELL_GATEWAY_ROUTE unset — skipping route check"
fi

echo "== curls to service =="
curl -sk --max-time 10 -o /dev/null -w 'svc:8080 -> %{http_code}\n' "$OPENSHELL_GATEWAY_URL" || echo FAIL

echo "== openshell whoami (default) =="
openshell whoami 2>&1 | head -6

echo "== openshell --gateway-insecure whoami (route) =="
openshell --gateway-insecure whoami 2>&1 | head -6

echo "== openshell --gateway-endpoint service (insecure) =="
OPENSHELL_GATEWAY_ENDPOINT="$OPENSHELL_GATEWAY_URL" \
  openshell --gateway-insecure whoami 2>&1 | head -6

echo "== openshell status (verbose) =="
openshell -vv status 2>&1 | head -25
