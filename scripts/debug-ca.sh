#!/usr/bin/env bash
set -uo pipefail
if [[ -r /etc/openshell-ca/ca.crt ]]; then
  bundle="${HOME:-/work}/ca-bundle.crt"
  cat /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/openshell-ca/ca.crt > "$bundle" 2>/dev/null \
    || cat /etc/ssl/certs/ca-certificates.crt /etc/openshell-ca/ca.crt > "$bundle" 2>/dev/null \
    || cp /etc/openshell-ca/ca.crt "$bundle"
  export SSL_CERT_FILE="$bundle"
fi
source /scripts/openshell-auth.sh
openshell_auth_init
set +e

echo "SSL_CERT_FILE=${SSL_CERT_FILE:-<unset>}"
ls -l /etc/openshell-ca/ 2>&1

echo "== whoami (TLS verified) =="
openshell whoami 2>&1 | head -8
echo "rc=$?"

echo "== list-profiles -o json =="
openshell provider list-profiles -o json > /tmp/p.json 2>/tmp/p.err
echo "rc=$?"; head -3 /tmp/p.err
head -c 120 /tmp/p.json; echo
echo "== jq ids =="
jq -r '.[].id' /tmp/p.json 2>&1 | head -5
