#!/usr/bin/env bash
#
# Builds the provider JAR from the plugin repository, imports realm/openmrs-realm.json
# into a throwaway Keycloak container, and asserts through the admin API that the SMART
# flow, client and context mappers actually landed.
#
# This lives with the realm rather than with the plugin because what it checks is a
# property of the wiring -- which names OpenMRS's URLs, the FHIR audience, and the user
# storage provider from a second repository -- not of any one plugin's Java.
#
# The realm template carries a __SMART_LAUNCH_SECRET__ placeholder rather than a
# key, so no secret is committed. A random key is generated per run here; a real
# deployment must inject its own.
#
# The file must be named <realm>-realm.json: Keycloak's directory import rejects
# a mismatch between the file name and the realm inside it.
#
# Usage: realm/verify-realm-import.sh [keycloak-version]
set -euo pipefail

KC_VERSION="${1:-26.7.1}"
CONTAINER="kc-realm-verify"
PORT=8181
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The realm lives here, with the deployment that renders it. The provider it wires up
# lives in the plugin repository, which this reaches into the same way up.sh does --
# the integrator knows about the parts, never the reverse.
SMART_AUTH_REPO="${SMART_AUTH_REPO:-$HERE/../openmrs-contrib-keycloak-smart-auth}"
JAR="$SMART_AUTH_REPO/keycloak-smart-auth/target/keycloak-smart-auth-1.0.0-SNAPSHOT.jar"
WORK="$(mktemp -d)"
FAILURES=0

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

step()  { printf '\n=== %s ===\n' "$1"; }
check() {
  # check <description> <actual> <expected>
  if [ "$2" = "$3" ]; then
    printf '  PASS  %s\n' "$1"
  else
    printf '  FAIL  %s\n        expected %q, got %q\n' "$1" "$3" "$2"
    FAILURES=$((FAILURES + 1))
  fi
}

step "Building provider JAR"
[ -f "$JAR" ] || mvn -f "$SMART_AUTH_REPO/pom.xml" -q -B -ntp clean install
[ -f "$JAR" ] || { echo "provider JAR not found at $JAR"; exit 1; }

step "Rendering the realm for this run"
# Rendered through the same script a real deployment uses, so this exercises the
# renderer rather than a second implementation of it.
SMART_LAUNCH_SECRET="$(openssl rand -base64 32)" \
  OPENMRS_BASE_URL="http://localhost/openmrs" \
  python3 "$HERE/realm/render-realm.py" "$WORK/openmrs-realm.json" | sed 's/^/  /'
grep -q "__" "$WORK/openmrs-realm.json" && { echo "  placeholders survived rendering"; exit 1; }

step "Starting Keycloak $KC_VERSION with realm import"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" -p "$PORT:8080" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  -v "$JAR:/opt/keycloak/providers/openmrs-smart-auth.jar:ro" \
  -v "$WORK/openmrs-realm.json:/opt/keycloak/data/import/openmrs-realm.json:ro" \
  "quay.io/keycloak/keycloak:$KC_VERSION" start-dev --import-realm >/dev/null

for i in $(seq 1 90); do
  if docker logs "$CONTAINER" 2>&1 | grep -qE "started in"; then echo "  up after ${i}s"; break; fi
  if docker logs "$CONTAINER" 2>&1 | grep -qiE "FATAL|failed to start|Exception in thread"; then
    echo "  startup failed:"; docker logs "$CONTAINER" 2>&1 | tail -30; exit 1
  fi
  [ "$i" = 90 ] && { echo "  timed out"; docker logs "$CONTAINER" 2>&1 | tail -30; exit 1; }
  sleep 1
done

step "Import diagnostics from the server log"
if docker logs "$CONTAINER" 2>&1 | grep -qE "Realm 'openmrs' imported|Imported realm openmrs|Realm openmrs imported"; then
  echo "  PASS  realm import reported by server"
else
  echo "  note: no explicit import line; relying on the API assertions below"
fi
if docker logs "$CONTAINER" 2>&1 | grep -aiE "error.*(realm|import)|Unable to import" | grep -v "KC-SERVICES0047"; then
  echo "  FAIL  import errors present in log"; FAILURES=$((FAILURES + 1))
fi

step "Authenticating kcadm inside the container"
# Admin calls run inside the container via kcadm. Keycloak's master realm has
# sslRequired=external, and a request arriving through Docker's published port is
# not treated as local, so host-side curl is rejected with "HTTPS required"
# regardless of IPv4/IPv6. From inside, the request genuinely originates at
# 127.0.0.1.
docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin --password admin >/dev/null 2>&1 \
  || { echo "  kcadm could not authenticate"; docker logs "$CONTAINER" 2>&1 | tail -20; exit 1; }
echo "  kcadm authenticated"

# Paths are given as /realms/... for readability; kcadm wants them relative to /admin/.
api() { docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh get "${1#/}" 2>/dev/null; }

check "realm openmrs exists"        "$(api /realms/openmrs | python3 -c 'import sys,json; print(json.load(sys.stdin)["realm"])')" "openmrs"
check "browser flow is bound"       "$(api /realms/openmrs | python3 -c 'import sys,json; print(json.load(sys.stdin)["browserFlow"])')" "SMART browser flow"
check "action token lifespan set"   "$(api /realms/openmrs | python3 -c 'import sys,json; print(json.load(sys.stdin)["actionTokenGeneratedByUserLifespan"])')" "300"

check "smartClient is public"       "$(api /realms/openmrs/clients?clientId=smartClient | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["publicClient"])')" "True"
check "PKCE S256 enforced"          "$(api /realms/openmrs/clients?clientId=smartClient | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["attributes"].get("pkce.code.challenge.method"))')" "S256"

step "SMART flow executions"
api "/realms/openmrs/authentication/flows/SMART%20browser%20flow/executions" > "$WORK/exec.json"
python3 - "$WORK/exec.json" <<'PY'
import json, sys
execs = json.load(open(sys.argv[1]))
for e in execs:
    print("  %-46s %-12s config=%s" % (
        e.get("providerId") or e.get("displayName"), e.get("requirement"), bool(e.get("authenticationConfig"))))
PY

for want in smart-audience-validator smart-access-authenticator smart-application-authenticator smart-username-password-form; do
  found="$(python3 -c "
import json,sys
execs=json.load(open('$WORK/exec.json'))
print('yes' if any(e.get('providerId')=='$want' for e in execs) else 'no')")"
  check "flow contains $want" "$found" "yes"
done

step "The audience validator is REQUIRED and configured"
AUDREQ="$(python3 -c "
import json
execs=json.load(open('$WORK/exec.json'))
print(next((e.get('requirement','') for e in execs if e.get('providerId')=='smart-audience-validator'), 'absent'))")"
check "audience validator is REQUIRED" "$AUDREQ" "REQUIRED"
AUDCFG="$(python3 -c "
import json
execs=json.load(open('$WORK/exec.json'))
print(next((e.get('authenticationConfig','') for e in execs if e.get('providerId')=='smart-audience-validator'), ''))")"
if [ -z "$AUDCFG" ]; then
  check "audience validator has a config" "missing" "present"
else
  check "allowed audiences are configured" "$(api "/realms/openmrs/authentication/config/$AUDCFG" | python3 -c "
import sys,json
v=json.load(sys.stdin)['config'].get('smart-allowed-audiences','')
print('set' if v.strip() else 'empty')")" "set"
fi

step "Authenticator configs carry the injected secret"
for alias_pair in "smart-access-authenticator:smart-launch-access-secret-key" "smart-application-authenticator:smart-launch-secret-key"; do
  prov="${alias_pair%%:*}"; key="${alias_pair##*:}"
  cfgid="$(python3 -c "
import json
execs=json.load(open('$WORK/exec.json'))
print(next((e.get('authenticationConfig','') for e in execs if e.get('providerId')=='$prov'), ''))")"
  if [ -z "$cfgid" ]; then
    check "$prov has an authenticator config" "missing" "present"; continue
  fi
  val="$(api "/realms/openmrs/authentication/config/$cfgid" | python3 -c "
import sys,json; c=json.load(sys.stdin)['config']; v=c.get('$key','')
print('set' if v and v!='__SMART_LAUNCH_SECRET__' else 'unset-or-placeholder')")"
  check "$prov $key is a real value" "$val" "set"
done

step "SMART context mappers on the launch scopes"
for pair in "launch/patient:patient" "launch/encounter:encounter"; do
  scope="${pair%%:*}"; claim="${pair##*:}"
  sid="$(api /realms/openmrs/client-scopes | python3 -c "
import sys,json; print(next((s['id'] for s in json.load(sys.stdin) if s['name']=='$scope'), ''))")"
  if [ -z "$sid" ]; then check "client scope $scope exists" "missing" "present"; continue
  else check "client scope $scope exists" "present" "present"; fi
  got="$(api "/realms/openmrs/client-scopes/$sid/protocol-mappers/models" | python3 -c "
import sys,json
ms=json.load(sys.stdin)
m=next((m for m in ms if m['protocolMapper']=='smart-context-claim-mapper'), None)
if not m: print('no-mapper')
else:
    c=m['config']
    print('%s|%s|%s' % (c.get('claim.name'), c.get('access.tokenResponse.claim'), c.get('user.session.note')))")"
  check "$scope maps to the $claim claim in the token response" "$got" "$claim|true|smart-oidc-note.$( [ "$claim" = patient ] && echo patient || echo visit )"
done

step "preferred_username is emitted (the OpenMRS side maps users by it)"
PSID="$(api /realms/openmrs/client-scopes | python3 -c "
import sys,json; print(next((s['id'] for s in json.load(sys.stdin) if s['name']=='profile'), ''))")"
if [ -z "$PSID" ]; then
  check "profile client scope exists" "missing" "present"
else
  check "profile client scope exists" "present" "present"
  check "profile emits preferred_username" "$(api "/realms/openmrs/client-scopes/$PSID/protocol-mappers/models" | python3 -c "
import sys,json
ms=json.load(sys.stdin)
m=next((m for m in ms if m['config'].get('claim.name')=='preferred_username'), None)
print('yes' if m and m['config'].get('access.token.claim')=='true' else 'no')")" "yes"
fi
check "smartClient defaults include profile" "$(api /realms/openmrs/clients?clientId=smartClient | python3 -c "
import sys,json
c=json.load(sys.stdin)[0]
print('yes' if 'profile' in c.get('defaultClientScopes',[]) else 'no')")" "yes"

step "No dangling client-scope references in the import"
if docker logs "$CONTAINER" 2>&1 | grep -aq "Referenced client scope"; then
  echo "  FAIL  import referenced client scopes that do not exist:"
  docker logs "$CONTAINER" 2>&1 | grep -a "Referenced client scope" | sed 's/^/        /'
  FAILURES=$((FAILURES + 1))
else
  echo "  PASS  every referenced client scope exists"
fi

step "Result"
if [ "$FAILURES" -eq 0 ]; then
  echo "  all checks passed against Keycloak $KC_VERSION"
else
  echo "  $FAILURES check(s) failed"; exit 1
fi
