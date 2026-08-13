#!/usr/bin/env bash
#
# Asserts that the development environment is actually usable, rather than merely
# running. Every check corresponds to something a SMART launch depends on.
#
# Usage: ./verify-env.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# The reference application's own compose files, plus this distribution's overlay. Named
# explicitly because compose merges docker-compose.override.yml automatically, and that
# file adds `build:` to every service -- running a launch should not rebuild the images.
# COMPOSE_FILE is compose's own variable, so every `docker compose` below sees both files.
export COMPOSE_FILE="$HERE/docker-compose.yml:$HERE/docker-compose.smart.yml"

OPENMRS_PORT="${OPENMRS_PORT:-80}"
KEYCLOAK_PORT="${KEYCLOAK_PORT:-8180}"
if [ "$OPENMRS_PORT" = "80" ]; then OPENMRS="http://localhost/openmrs"; else OPENMRS="http://localhost:${OPENMRS_PORT}/openmrs"; fi
KC="http://localhost:${KEYCLOAK_PORT}"
FAILURES=0

step()  { printf '\n=== %s ===\n' "$1"; }
pass()  { printf '  PASS  %s\n' "$1"; }
fail()  { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; FAILURES=$((FAILURES+1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }

# -L throughout: OpenMRS answers several of these through a redirect, and a 301 is
# not a failure.
status() { curl -sL -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>/dev/null || echo 000; }

step "Containers"
for svc in db backend frontend gateway keycloak; do
  state="$(docker compose ps "$svc" --format '{{.State}}' 2>/dev/null | head -1)"
  if [ "$state" = "running" ]; then pass "$svc is running"; else fail "$svc is running" "state='$state'"; fi
done

step "OpenMRS"
check "OpenMRS answers through the gateway" "$(status "$OPENMRS/")" "200"
check "the O3 frontend is served"           "$(status "$OPENMRS/spa/")" "200"
SESSION="$(curl -sL --max-time 20 "$OPENMRS/ws/rest/v1/session" 2>/dev/null)"
if printf '%s' "$SESSION" | grep -q '"authenticated"'; then
  pass "the session endpoint responds (the ESM app shell depends on it)"
else
  fail "the session endpoint responds" "got: $(printf '%s' "$SESSION" | head -c 120)"
fi

step "FHIR"
# fhir2 requires authentication, so 401 is the healthy answer for an anonymous call:
# it proves the endpoint is mapped rather than missing.
code="$(status "$OPENMRS/ws/fhir2/R4/metadata")"
if [ "$code" = "200" ] || [ "$code" = "401" ]; then
  pass "the FHIR R4 endpoint is mapped (HTTP $code)"
else
  fail "the FHIR R4 endpoint is mapped" "HTTP $code; the fhir2 module may not have started"
fi

step "Keycloak"
check "the openmrs realm is served" "$(status "$KC/realms/openmrs/.well-known/openid-configuration")" "200"
DISC="$(curl -sL --max-time 20 "$KC/realms/openmrs/.well-known/openid-configuration" 2>/dev/null)"

got="$(printf '%s' "$DISC" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print('S256' if 'S256' in d.get('code_challenge_methods_supported',[]) else 'missing')
except Exception: print('unparseable')")"
check "PKCE S256 is advertised" "$got" "S256"

got="$(printf '%s' "$DISC" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    scopes=d.get('scopes_supported',[])
    want={'launch','launch/patient','launch/encounter','fhirUser'}
    print('all' if want.issubset(set(scopes)) else 'missing: %s' % sorted(want-set(scopes)))
except Exception: print('unparseable')")"
check "the SMART launch scopes are advertised" "$got" "all"

step "SMART providers are loaded"
# Captured once to a file. Piping docker logs straight into `grep -q` breaks under
# `set -o pipefail`: grep exits on the first match, docker dies of SIGPIPE, and the
# pipeline reports failure despite the match.
KC_LOG="$(mktemp)"
docker compose logs keycloak > "$KC_LOG" 2>&1 || true
for provider in smart-audience-validator smart-access-authenticator smart-application-authenticator smart-username-password-form smart-context-claim-mapper; do
  if grep -q "$provider" "$KC_LOG"; then
    pass "$provider registered"
  else
    fail "$provider registered" "not mentioned in the Keycloak log"
  fi
done
if grep -q "Realm 'openmrs' imported" "$KC_LOG"; then
  pass "the realm was imported"
else
  fail "the realm was imported" "no import line in the Keycloak log"
fi

step "Keycloak accepts plain HTTP"
# Keycloak refuses HTTP per realm, and the refusal is a rendered page rather than an error status:
# a realm left at the default "external" answers "HTTPS required" for any client it does not
# consider private, so it looks fine from localhost and fails through a tunnel or from another
# machine. Both realms matter here, because master serves the admin console.
for realm in master openmrs; do
  body="$(docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get "realms/$realm" \
    --fields sslRequired --format csv --noquotes 2>/dev/null | tr -d ' \r\n')"
  case "$body" in
    none) pass "the $realm realm accepts plain HTTP" ;;
    "")   fail "the $realm realm accepts plain HTTP" "could not read sslRequired for $realm" ;;
    *)    fail "the $realm realm accepts plain HTTP" \
               "sslRequired=$body, so Keycloak answers 'HTTPS required' to non-private clients" ;;
  esac
done

# And prove it, rather than trusting the setting: ask over HTTP and look for the refusal page.
for probe in "/admin/master/console/" "/realms/openmrs/.well-known/openid-configuration"; do
  page="$(curl -s -L --max-time 20 "$KC$probe" 2>/dev/null)"
  if printf '%s' "$page" | grep -qi "HTTPS required"; then
    fail "$probe is served over plain HTTP" "Keycloak answered with its 'HTTPS required' page"
  else
    pass "$probe is served over plain HTTP"
  fi
done

step "The SMART discovery document"
DISCO_SMART="$(curl -sL --max-time 20 "$OPENMRS/ws/fhir2/R4/.well-known/smart-configuration" 2>/dev/null)"
DISCO="$DISCO_SMART"
got="$(printf '%s' "$DISCO" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print('unparseable'); raise SystemExit
missing=[k for k in ('authorization_endpoint','token_endpoint','capabilities','scopes_supported') if not d.get(k)]
print('complete' if not missing else 'missing: %s' % missing)")"
check "the module serves a discovery document" "$got" "complete"

# Every field SMART App Launch 2.x marks REQUIRED. Absence is a conformance failure, and an
# app cannot discover PKCE support or which keys to trust.
got="$(printf '%s' "$DISCO_SMART" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('unparseable'); raise SystemExit
need=('issuer','jwks_uri','authorization_endpoint','token_endpoint','grant_types_supported',
      'capabilities','code_challenge_methods_supported')
missing=[k for k in need if not d.get(k)]
print('all' if not missing else 'missing: %s' % missing)")"
check "every SMART 2.x required field is present" "$got" "all"

check "PKCE advertises S256 and nothing weaker" "$(printf '%s' "$DISCO_SMART" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('unparseable'); raise SystemExit
m=d.get('code_challenge_methods_supported',[])
print('S256-only' if m==['S256'] else 'unexpected: %s' % m)")" "S256-only"

# A discovery document is a contract. Advertising a flow that has not been walked makes an app
# fail in a way that looks like the app's fault. The standalone capabilities were absent until
# the flow completed in a browser; permission-v2 stays absent until scopes are enforced.
check "no capability is advertised that is not implemented" "$(printf '%s' "$DISCO_SMART" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('unparseable'); raise SystemExit
caps=set(d.get('capabilities',[]))
over=caps & {'permission-v2'}
print('honest' if not over else 'overclaimed: %s' % sorted(over))")" "honest"

# The keys an app is told to verify with must be fetchable from where the app runs, not only
# from inside the compose network.
ADVERTISED_JWKS="$(printf '%s' "$DISCO_SMART" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('jwks_uri',''))
except Exception: print('')")"
if [ -n "$ADVERTISED_JWKS" ]; then
  keys="$(curl -s --max-time 20 "$ADVERTISED_JWKS" 2>/dev/null | python3 -c "
import sys,json
try: print(len(json.load(sys.stdin).get('keys',[])))
except Exception: print(0)")"
  if [ "${keys:-0}" -gt 0 ]; then
    pass "the advertised signing keys are fetchable from outside the containers ($keys keys)"
  else
    fail "the advertised signing keys are fetchable from outside the containers" \
         "$ADVERTISED_JWKS returned no keys, so an app cannot verify tokens"
  fi
else
  fail "the discovery document advertises a jwks_uri" "none present"
fi

# The endpoints an app is told to use must be ones a browser can reach, not
# container-internal hostnames.
got="$(printf '%s' "$DISCO" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('unparseable'); raise SystemExit
a=d.get('authorization_endpoint','')
print('reachable' if a.startswith('http://localhost:') else 'unreachable: %s' % a)")"
check "the advertised authorization endpoint is browser-reachable" "$got" "reachable"

got="$(printf '%s' "$DISCO" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('unparseable'); raise SystemExit
# Only the flows that work. Standalone launch is included now that the walk below completes it.
want={'launch-ehr','launch-standalone','context-ehr-patient','context-ehr-encounter',
      'context-standalone-patient','sso-openid-connect'}
have=set(d.get('capabilities',[]))
print('all' if want.issubset(have) else 'missing: %s' % sorted(want-have))")"
check "the implemented launch capabilities are advertised" "$got" "all"

# Without this an app has no discoverable way to log anybody out. Ending the OpenMRS session alone
# leaves the authorization server's session intact, and the next launch in that browser is granted
# silently as whoever launched last.
LOGOUT="$(printf '%s' "$DISCO_SMART" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('end_session_endpoint',''))
except Exception: print('')")"
if [ -z "$LOGOUT" ]; then
  fail "the discovery document advertises where to end a session" "no end_session_endpoint"
else
  pass "the discovery document advertises where to end a session"
  case "$LOGOUT" in
    http://localhost:*) pass "the advertised logout endpoint is browser-reachable" ;;
    *) fail "the advertised logout endpoint is browser-reachable" "got $LOGOUT" ;;
  esac
fi

step "The audience validator decides launches on the aud parameter"
PKCE="code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256"
REDIRECT="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$OPENMRS/")"
authorize() {
  # $1 is the aud value. Status code only: Keycloak renders its error page with the
  # login theme, so the page text cannot distinguish a rejection from a login form.
  curl -s -o "$2" -w '%{http_code}' --max-time 20 \
    "$KC/realms/openmrs/protocol/openid-connect/auth?client_id=smartClient&response_type=code&scope=openid&redirect_uri=$REDIRECT&aud=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1")&$PKCE" 2>/dev/null || echo 000
}

WRONG_BODY="$(mktemp)"; RIGHT_BODY="$(mktemp)"
check "a launch naming another FHIR server is refused" "$(authorize "https://attacker.example.org/fhir" "$WRONG_BODY")" "400"
check "a launch naming this FHIR server is admitted"   "$(authorize "$OPENMRS/ws/fhir2/R4" "$RIGHT_BODY")" "200"

# Only the admitted launch should reach a form that asks for credentials.
if grep -qiE 'type="password"|name="password"' "$RIGHT_BODY"; then
  pass "the admitted launch reaches the login form"
else
  fail "the admitted launch reaches the login form" "no password field in the response"
fi
if grep -qiE 'type="password"|name="password"' "$WRONG_BODY"; then
  fail "the refused launch stops before the login form" "a password field was rendered"
else
  pass "the refused launch stops before the login form"
fi
rm -f "$WRONG_BODY" "$RIGHT_BODY" "$KC_LOG"

step "SMART access tokens are actually examined on FHIR requests"
# A 401 alone proves nothing: fhir2 answers 401 to any unauthenticated call. What
# distinguishes our path is the OAuth challenge header and our verifier's own log line.
HDRS="$(mktemp)"
code="$(curl -s -D "$HDRS" -o /dev/null -w '%{http_code}' --max-time 20 \
  -H "Authorization: Bearer not-a-real-token" "$OPENMRS/ws/fhir2/R4/Patient" 2>/dev/null || echo 000)"
check "a bad bearer token is refused" "$code" "401"
if grep -qi 'WWW-Authenticate: *Bearer error="invalid_token"' "$HDRS"; then
  pass "the refusal carries an OAuth bearer challenge"
else
  fail "the refusal carries an OAuth bearer challenge" "no WWW-Authenticate: Bearer header"
fi
rm -f "$HDRS"

OMRS_LOG="$(mktemp)"
docker compose exec -T backend sh -c 'cat /openmrs/data/openmrs.log' > "$OMRS_LOG" 2>/dev/null || true
if grep -q "Rejected a SMART access token" "$OMRS_LOG"; then
  pass "the module's own verifier examined the token"
else
  fail "the module's own verifier examined the token" \
       "no rejection logged, so the bearer filter may not be running at all"
fi
rm -f "$OMRS_LOG"

# A structurally valid JWT gets past parsing into key resolution, so the rejection reason
# shows whether the authorization server's JWKS was actually consulted. Asserting on the
# module's INFO line would not work: OpenMRS logs this package at WARN.
WELL_FORMED="$(python3 -c "
import base64, json, time
def seg(d): return base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip('=')
print(seg({'alg':'RS256','kid':'no-such-key'}) + '.' +
      seg({'iss':'$KC/realms/openmrs','aud':'$OPENMRS/ws/fhir2/R4','preferred_username':'admin','exp':int(time.time())+300}) +
      '.' + base64.urlsafe_b64encode(b'not-a-real-signature').decode().rstrip('='))")"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
  -H "Authorization: Bearer $WELL_FORMED" "$OPENMRS/ws/fhir2/R4/Patient" 2>/dev/null || echo 000)"
check "a token signed by an unknown key is refused" "$code" "401"

OMRS_LOG2="$(mktemp)"
docker compose exec -T backend sh -c 'cat /openmrs/data/openmrs.log' > "$OMRS_LOG2" 2>/dev/null || true
if grep -qE "no matching key|Signed JWT rejected|Another algorithm expected" "$OMRS_LOG2"; then
  pass "the authorization server's signing keys were consulted"
else
  fail "the authorization server's signing keys were consulted" \
       "the rejection did not reach key resolution, so JWKS may be unreachable"
fi
rm -f "$OMRS_LOG2"

step "Keycloak reads users from OpenMRS"
# Without federation, every Keycloak user must be created and kept in step by hand. A
# federationLink on the user is Keycloak saying the account came from the OpenMRS database.
FED="$(docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get users -r openmrs \
  -q "username=${SMART_DEV_USER:-doctor}" 2>/dev/null | python3 -c "
import sys,json
try:
    u=json.load(sys.stdin)
    print('federated' if u and u[0].get('federationLink') else ('local' if u else 'absent'))
except Exception: print('unreadable')")"
if [ "$FED" = "federated" ]; then
  pass "the user comes from the OpenMRS database, not a copy in Keycloak"
elif [ "$FED" = "local" ]; then
  fail "the user comes from the OpenMRS database" "the user is local to Keycloak; federation is not in use"
else
  fail "the user comes from the OpenMRS database" "no such user in the realm ($FED)"
fi

step "A genuine Keycloak token reads FHIR data"
# The end-to-end case. Everything above proves bad tokens are refused, which is the easier
# half; this proves a real one is accepted and maps to an OpenMRS user.
DEV_USER="${SMART_DEV_USER:-doctor}"
# With federation, this is the user's own OpenMRS password.
DEV_PASSWORD="${SMART_DEV_PASSWORD:-OpenmrsDoc123}"
TOKEN_JSON="$(curl -s --max-time 30 -X POST "$KC/realms/openmrs/protocol/openid-connect/token" \
  -d client_id=smartClient -d grant_type=password -d "username=$DEV_USER" -d "password=$DEV_PASSWORD" \
  -d "scope=openid profile fhirUser launch" 2>/dev/null)"
ACCESS_TOKEN="$(printf '%s' "$TOKEN_JSON" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('access_token',''))
except Exception: print('')")"

if [ -z "$ACCESS_TOKEN" ]; then
  fail "an access token can be obtained for $DEV_USER" \
       "$(printf '%s' "$TOKEN_JSON" | head -c 160)"
else
  pass "an access token was obtained for $DEV_USER"

  # aud must name this FHIR server or the module refuses the token, and the username claim
  # is what it maps onto an OpenMRS user.
  claims="$(printf '%s' "$ACCESS_TOKEN" | python3 -c "
import sys,json,base64
p=sys.stdin.read().split('.')[1]; p+='='*(-len(p)%4)
c=json.loads(base64.urlsafe_b64decode(p))
aud=c.get('aud'); aud=aud if isinstance(aud,list) else [aud]
print('%s|%s' % ('yes' if '$OPENMRS/ws/fhir2/R4' in aud else 'no', c.get('preferred_username')))")"
  check "the token names this FHIR server in aud" "${claims%%|*}" "yes"
  check "the token names the expected user"       "${claims##*|}" "$DEV_USER"

  BODY="$(mktemp)"
  code="$(curl -s -o "$BODY" -w '%{http_code}' --max-time 30 \
    -H "Authorization: Bearer $ACCESS_TOKEN" "$OPENMRS/ws/fhir2/R4/Patient?_count=1" 2>/dev/null || echo 000)"
  check "the FHIR API accepts it" "$code" "200"
  got="$(python3 -c "
import json,sys
try: print(json.load(open('$BODY')).get('resourceType',''))
except Exception: print('unparseable')")"
  check "and answers with a FHIR Bundle" "$got" "Bundle"
  rm -f "$BODY"
fi

FHIR_BASE="$OPENMRS/ws/fhir2/R4"
export FHIR_BASE
step "The patient picker is actually served"
# The picker is a frontend module, installed into the SPA host rather than built into the image.
# When its bundle name or registration is wrong the route still resolves and the app simply never
# loads: the launch lands on an empty page with no error anywhere.
IMPORTMAP="$(curl -s -L --max-time 20 "$OPENMRS/spa/importmap.json" 2>/dev/null)"
BUNDLE_URL="$(printf '%s' "$IMPORTMAP" | python3 -c "
import sys, json
try:
    imports = json.load(sys.stdin).get('imports', {})
except Exception:
    print(''); raise SystemExit
print(next((v for k, v in imports.items() if 'smart-app-launch' in k), ''))")"

if [ -z "$BUNDLE_URL" ]; then
  fail "the picker is registered in the SPA import map" "no smart-app-launch entry in $OPENMRS/spa/importmap.json"
else
  pass "the picker is registered in the SPA import map"
  case "$BUNDLE_URL" in
    http*) FETCH="$BUNDLE_URL" ;;
    /*)    FETCH="http://localhost$BUNDLE_URL" ;;
    *)     FETCH="$OPENMRS/spa/$BUNDLE_URL" ;;
  esac
  code="$(curl -s -L -o /dev/null -w '%{http_code}' --max-time 20 "$FETCH" 2>/dev/null)"
  if [ "$code" = "200" ]; then
    pass "the registered bundle is fetchable"
  else
    fail "the registered bundle is fetchable" "$FETCH answered HTTP $code, so the route renders nothing"
  fi
fi

# An unmet backend dependency stops the frontend registering the app at all, and a -SNAPSHOT
# backend does not satisfy a plain >= range: 2.0.0-SNAPSHOT sorts below 2.0.0 under semver.
ROUTES="$(curl -s -L --max-time 20 "$OPENMRS/spa/routes.registry.json" 2>/dev/null)"
got="$(printf '%s' "$ROUTES" | MODULE_VERSION="$(curl -s -u "${SMART_DEV_USER:-doctor}:$DEV_PASSWORD" --max-time 20 \
  "$OPENMRS/ws/rest/v1/module/smartonfhir?v=custom:(version)" 2>/dev/null | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('version',''))
except Exception: print('')")" python3 -c "
import sys, json, os, re
installed = os.environ.get('MODULE_VERSION', '')
try:
    registry = json.load(sys.stdin)
except Exception:
    print('unparseable registry'); raise SystemExit
entry = next((v for k, v in registry.items() if 'smart-app-launch' in k), None)
if entry is None:
    print('the picker is not in the routes registry'); raise SystemExit
required = (entry.get('backendDependencies') or {}).get('smartonfhir')
if not required:
    print('no smartonfhir dependency declared'); raise SystemExit
if not installed:
    print('could not read the installed module version'); raise SystemExit
# Mirror the frontend's own comparison closely enough to catch the prerelease trap.
prerelease = '-' in installed
plain_lower_bound = re.match(r'^>=\s*\d+\.\d+\.\d+$', required.strip())
print('blocked' if prerelease and plain_lower_bound else 'satisfied')")"
check "the picker's backend dependency admits the installed module version" "$got" "satisfied"

step "The standalone launch completes"
# The whole flow, driven as a browser would: authorize, sign in with the clinician's own
# OpenMRS password, land on the picker, turn the launch token into a session, choose a patient,
# and exchange the code. Anything short of the patient arriving in the token response leaves a
# gap only a real app would find.
JAR="$(mktemp)"
AUTHORIZE="$KC/realms/openmrs/protocol/openid-connect/auth?client_id=smartClient&response_type=code&scope=openid%20launch/patient&redirect_uri=http%3A%2F%2Flocalhost%3A3000%2F&aud=$(python3 -c "import urllib.parse,os;print(urllib.parse.quote(os.environ['FHIR_BASE']))")&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256"

curl -s -c "$JAR" -o "$JAR.login" --max-time 25 "$AUTHORIZE" 2>/dev/null
FORM_ACTION="$(LOGIN_FILE="$JAR.login" python3 -c "
import re, html, os
try:
    m = re.search(r'action=\"([^\"]+)\"', open(os.environ['LOGIN_FILE']).read())
    print(html.unescape(m.group(1)) if m else '')
except Exception:
    print('')")"

if [ -z "$FORM_ACTION" ]; then
  fail "the authorization endpoint presents a login form" "no form in the response"
  PICKER_URL=""
else
  pass "the authorization endpoint presents a login form"
  PICKER_URL="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -D - --max-time 25 \
    --data-urlencode "username=${SMART_DEV_USER:-doctor}" --data-urlencode "password=$DEV_PASSWORD" \
    --data-urlencode "credentialId=" "$FORM_ACTION" 2>/dev/null \
    | grep -i '^location:' | sed 's/^[Ll]ocation: *//' | tr -d '\r')"
fi

case "$PICKER_URL" in
  *"/ms/smartPatientSelection"*)
    pass "signing in sends the browser to the module's patient-selection entry point"
    # That entry point turns the token into a session and then redirects to the frontend route.
    # Landing on the frontend route directly cannot work: it has no session, so the single-page
    # application redirects to the login page and the launch token in the URL is lost.
    SPA_HOP="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -D - --max-time 25 "$PICKER_URL" 2>/dev/null \
      | grep -i '^location:' | sed 's/^[Ll]ocation: *//' | tr -d '\r')"
    case "$SPA_HOP" in
      *"/spa/smart/select-patient"*) pass "the entry point redirects to the picker with a session in place" ;;
      "") fail "the entry point redirects to the picker with a session in place" "no redirect issued" ;;
      *) fail "the entry point redirects to the picker with a session in place" "went to $SPA_HOP" ;;
    esac
    case "$SPA_HOP" in
      *jsessionid*) fail "the redirect does not put the session id in the URL" "got $SPA_HOP" ;;
      *) pass "the redirect does not put the session id in the URL" ;;
    esac
    ;;
  "") fail "signing in sends the browser to the module's patient-selection entry point" "no redirect after login" ;;
  *) fail "signing in sends the browser to the module's patient-selection entry point" "went to $PICKER_URL" ;;
esac

LAUNCH_TOKEN="$(PICKER="$PICKER_URL" python3 -c "
import urllib.parse as u, os
print(u.parse_qs(u.urlparse(os.environ['PICKER']).query).get('token', [''])[0])" 2>/dev/null)"

if [ -z "$LAUNCH_TOKEN" ]; then
  fail "the picker is handed a launch token" "none present in the redirect"
else
  ENCODED="$(TOKEN="$LAUNCH_TOKEN" python3 -c "
import urllib.parse, os
print(urllib.parse.quote(os.environ['TOKEN']))")"

  # The entry point followed above already authenticated from the token, so an ordinary session
  # request should now answer as the clinician. This is what the frontend relies on: it never sees
  # the token exchange, it simply finds a session waiting.
  who="$(curl -s -b "$JAR" -c "$JAR" --max-time 25 "$OPENMRS/ws/rest/v1/session" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    u = d.get('user') or {}
    if not d.get('authenticated'):
        print('anonymous')
    elif not isinstance(u.get('roles'), list):
        # The frontend reads user.roles without guarding; a session missing it crashes the whole app.
        print('authenticated but no roles')
    else:
        print(u.get('display'))
except Exception:
    print('unreadable')")"
  check "the launch token establishes a usable OpenMRS session" "$who" "${SMART_DEV_USER:-doctor}"

  PATIENT_UUID="$(curl -s -b "$JAR" --max-time 25 "$OPENMRS/ws/rest/v1/patient?q=John&v=custom:(uuid,display)&limit=1" 2>/dev/null | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin).get('results', [])
    print(r[0]['uuid'] if r else '')
except Exception:
    print('')")"
  if [ -n "$PATIENT_UUID" ]; then
    pass "the picker can search patients with that session"

    ACTION_URL="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -D - --max-time 25 \
      "$OPENMRS/ms/smartLaunchOptionSelected?token=$ENCODED&patientId=$PATIENT_UUID" 2>/dev/null \
      | grep -i '^location:' | sed 's/^[Ll]ocation: *//' | tr -d '\r')"
    APP_URL="$(curl -s -b "$JAR" -c "$JAR" -o /dev/null -D - --max-time 25 "$ACTION_URL" 2>/dev/null \
      | grep -i '^location:' | sed 's/^[Ll]ocation: *//' | tr -d '\r')"
    CODE="$(APP="$APP_URL" python3 -c "
import urllib.parse as u, os
print(u.parse_qs(u.urlparse(os.environ['APP']).query).get('code', [''])[0])" 2>/dev/null)"

    if [ -z "$CODE" ]; then
      fail "choosing a patient returns an authorization code" "landed on $APP_URL"
    else
      pass "choosing a patient returns an authorization code"
      GRANTED="$(curl -s --max-time 25 -X POST "$KC/realms/openmrs/protocol/openid-connect/token" \
        -d client_id=smartClient -d grant_type=authorization_code -d "code=$CODE" \
        -d "redirect_uri=http://localhost:3000/" \
        -d "code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" 2>/dev/null | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('patient') or 'no-patient-claim')
except Exception:
    print('unreadable')")"
      check "the app receives the chosen patient as launch context" "$GRANTED" "$PATIENT_UUID"

      # A standalone launch has to sign the clinician in so they can search. That session used to
      # outlive the launch, leaving the browser holding a fully privileged session that no visible
      # logout would obviously end -- on a shared workstation, the next person's session.
      left="$(curl -s -b "$JAR" --max-time 25 "$OPENMRS/ws/rest/v1/session" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print((d.get('user') or {}).get('display') if d.get('authenticated') else 'ended')
except Exception:
    print('unreadable')")"
      check "the session the launch created does not outlive it" "$left" "ended"
    fi
  else
    fail "the picker can search patients with that session" "the search returned nothing"
  fi
fi
rm -f "$JAR" "$JAR.login"

step "The EHR launch completes"
# An EHR launch is pure redirects, with no single-page application anywhere in it, so curl is
# sufficient here in a way it was not for the patient picker. Each hop below failed at some point
# during this work, and each failed in a way that looked like something else.
EJAR="$(mktemp)"
DEV_USER="${SMART_DEV_USER:-doctor}"

# A clinician already working in OpenMRS: the launch servlet refuses an unauthenticated request.
curl -s -u "$DEV_USER:$DEV_PASSWORD" -c "$EJAR" --max-time 25 "$OPENMRS/ws/rest/v1/session" -o /dev/null
LOC_UUID="$(curl -s -b "$EJAR" --max-time 25 "$OPENMRS/ws/rest/v1/location?limit=1" 2>/dev/null | python3 -c "
import sys, json
try: print(json.load(sys.stdin)['results'][0]['uuid'])
except Exception: print('')")"
curl -s -b "$EJAR" -c "$EJAR" --max-time 25 -X POST -H 'Content-Type: application/json' \
  -d "{\"sessionLocation\":\"$LOC_UUID\"}" "$OPENMRS/ws/rest/v1/session" -o /dev/null

EHR_PATIENT="$(curl -s -b "$EJAR" --max-time 25 "$OPENMRS/ws/rest/v1/patient?q=John&limit=1&v=custom:(uuid)" 2>/dev/null | python3 -c "
import sys, json
try: print(json.load(sys.stdin)['results'][0]['uuid'])
except Exception: print('')")"

if [ -z "$EHR_PATIENT" ]; then
  fail "a patient is available to launch for" "the search returned nothing"
else
  APP_CB="http://localhost:3000/"
  # Named by id: the address comes from the app registry, not from this request. Passing a launchUrl
  # used to be how this worked, which made the servlet an open redirector.
  NOTIFY="$(curl -s -b "$EJAR" -c "$EJAR" -o /dev/null -D - --max-time 25 \
    "$OPENMRS/ms/smartEhrLaunchServlet?appId=test-app&patientId=$EHR_PATIENT" \
    2>/dev/null | grep -i '^location:' | sed 's/^[Ll]ocation: *//' | tr -d '\r')"

  # An app this deployment never registered must not be launchable, and neither must an address
  # supplied by the caller.
  UNKNOWN_STATUS="$(curl -s -b "$EJAR" -o /dev/null -w '%{http_code}' --max-time 25 \
    "$OPENMRS/ms/smartEhrLaunchServlet?appId=never-registered&patientId=$EHR_PATIENT" 2>/dev/null)"
  check "an unregistered app cannot be launched" "$UNKNOWN_STATUS" "404"

  INJECTED="$(curl -s -b "$EJAR" -o /dev/null -D - --max-time 25 \
    "$OPENMRS/ms/smartEhrLaunchServlet?appId=test-app&patientId=$EHR_PATIENT&launchUrl=http%3A%2F%2Fevil.example.org%2F" \
    2>/dev/null | grep -i '^location:' | sed 's/^[Ll]ocation: *//' | tr -d '\r')"
  case "$INJECTED" in
    *evil.example.org*) fail "a launch cannot be redirected to an address of the caller's choosing" \
                             "the servlet sent the browser to $INJECTED" ;;
    *) pass "a launch cannot be redirected to an address of the caller's choosing" ;;
  esac

  # SMART requires the EHR to notify the app with iss and launch.
  case "$NOTIFY" in
    *iss=*launch=*|*launch=*iss=*) pass "the EHR notifies the app with iss and launch" ;;
    "") fail "the EHR notifies the app with iss and launch" "the launch servlet issued no redirect" ;;
    *) fail "the EHR notifies the app with iss and launch" "got $NOTIFY" ;;
  esac

  HANDLE="$(N="$NOTIFY" python3 -c "
import urllib.parse as u, os
print(u.parse_qs(u.urlparse(os.environ['N']).query).get('launch', [''])[0])" 2>/dev/null)"
  ISS="$(N="$NOTIFY" python3 -c "
import urllib.parse as u, os
print(u.parse_qs(u.urlparse(os.environ['N']).query).get('iss', [''])[0])" 2>/dev/null)"

  if [ -z "$HANDLE" ]; then
    fail "the launch notification carries a handle" "none present"
  else
    # The app authorizes with the handle and the launch scope: the EHR has already chosen the patient,
    # so it asks for the context that exists rather than for one to be established.
    AUTHZ="$KC/realms/openmrs/protocol/openid-connect/auth?client_id=smartClient&response_type=code\
&scope=openid%20launch&redirect_uri=$(python3 -c "import urllib.parse;print(urllib.parse.quote('$APP_CB'))")\
&aud=$(I="$ISS" python3 -c "import urllib.parse,os;print(urllib.parse.quote(os.environ['I']))")\
&launch=$(H="$HANDLE" python3 -c "import urllib.parse,os;print(urllib.parse.quote(os.environ['H']))")\
&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256"

    # Follow the whole chain: authorize -> OpenMRS redeems the handle -> back into the Keycloak flow.
    APP_BACK="$(curl -s -b "$EJAR" -c "$EJAR" -o /dev/null -D - -L --max-redirs 10 --max-time 40 "$AUTHZ" 2>/dev/null \
      | grep -i '^location:' | sed 's/^[Ll]ocation: *//' | tr -d '\r' | grep "^$APP_CB" | tail -1)"
    EHR_CODE="$(A="$APP_BACK" python3 -c "
import urllib.parse as u, os
print(u.parse_qs(u.urlparse(os.environ['A']).query).get('code', [''])[0])" 2>/dev/null)"

    if [ -z "$EHR_CODE" ]; then
      fail "the EHR launch reaches the app with an authorization code" "ended at ${APP_BACK:-nowhere}"
    else
      # No password was asked for: the OpenMRS session is what authenticated this launch.
      pass "the EHR launch reaches the app with an authorization code, without asking for a password"

      EHR_GRANTED="$(curl -s --max-time 25 -X POST "$KC/realms/openmrs/protocol/openid-connect/token" \
        -d client_id=smartClient -d grant_type=authorization_code -d "code=$EHR_CODE" \
        -d "redirect_uri=$APP_CB" \
        -d "code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" 2>/dev/null | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('patient') or 'no-patient-claim')
except Exception: print('unreadable')")"
      # The launch scope carried no context mapper for a while: the launch completed and returned no
      # patient, which an app cannot tell apart from a patient it may not see.
      check "the app receives the patient the EHR launched for" "$EHR_GRANTED" "$EHR_PATIENT"
    fi
  fi
fi
rm -f "$EJAR"

step "Result"
if [ "$FAILURES" -eq 0 ]; then
  echo "  the environment is ready for SMART launch development"
else
  echo "  $FAILURES check(s) failed"
  exit 1
fi
