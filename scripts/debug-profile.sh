#!/usr/bin/env bash
set -uo pipefail
source /scripts/openshell-auth.sh
openshell_auth_init
set +e

echo "== list-profiles -o json (raw) =="
openshell provider list-profiles -o json > /tmp/profiles.json 2>/tmp/profiles.err
echo "rc=$?"
echo "--- stderr ---"; head -5 /tmp/profiles.err
echo "--- stdout ---"; head -c 800 /tmp/profiles.json; echo
echo "--- jq ---"; jq -r '.[].id' /tmp/profiles.json 2>&1 | head -10

echo "== list-profiles (table) =="
openshell provider list-profiles 2>&1 | head -10

echo "== import the local one =="
openshell provider profile import --file /scripts/fullsend-local-llm.yaml 2>&1 | tail -5

echo "== list again =="
openshell provider list-profiles -o json 2>&1 | head -c 500; echo
