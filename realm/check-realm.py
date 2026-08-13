#!/usr/bin/env python3
"""Check realm/openmrs-realm.json without starting anything.

These assertions used to be RealmDefinitionTest in the Keycloak plugin repository. They
moved here with the realm itself: what they check is a property of the wiring between
OpenMRS, the FHIR server, the SMART app and two Keycloak plugins, which is this
repository's concern rather than any one plugin's.

Every check corresponds to a failure that is silent. Keycloak imports a realm with a
dangling client scope, an unused authenticator config, or a misspelled mapper key without
complaining, and the launch then fails somewhere else entirely -- usually at the first
FHIR call, which looks like the app's fault.

What is deliberately not checked here: whether an authenticator id the flow references
actually exists as a provider. That needs the plugin's own registrations, so it is left to
realm/verify-realm-import.sh, where a real Keycloak either finds the provider or does not.

Usage: realm/check-realm.py [path-to-realm-json]
       exit 0 if every check passes, 1 otherwise
"""

import json
import pathlib
import re
import sys

# Scopes Keycloak creates in every realm whether the import declares them or not, so a
# client may reference them without this file defining them. offline_access is the one
# that matters: declaring it ourselves risks getting its offline-role behaviour wrong.
BUILT_IN_CLIENT_SCOPES = {
    "offline_access", "web-origins", "roles", "role_list", "basic", "acr",
    "address", "phone", "microprofile-jwt", "organization", "service_account",
}

BUILT_IN_AUTHENTICATORS = {
    "auth-cookie", "auth-spnego", "identity-provider-redirector", "auth-otp-form",
    "auth-username-password-form", "conditional-user-configured",
    "reset-credentials-choose-user", "reset-credential-email", "reset-password",
    "reset-otp", "registration-page-form", "registration-user-creation",
    "registration-password-action", "registration-recaptcha-action",
    "client-secret", "client-jwt", "client-secret-jwt", "client-x509",
}

# Keycloak stores a provider id in a column this wide. A longer id imports with
# "Value too long for column" and the authenticator is simply absent.
MAX_AUTHENTICATOR_ID = 36

# scope name -> (session note it reads, claim the app receives)
LAUNCH_SCOPES = {
    "launch/patient": ("smart-oidc-note.patient", "patient"),
    "launch/encounter": ("smart-oidc-note.visit", "encounter"),
}

failures = []


def check(ok, description, detail=""):
    if ok:
        print(f"  PASS  {description}")
    else:
        print(f"  FAIL  {description}")
        if detail:
            print(f"        {detail}")
        failures.append(description)


def step(title):
    print(f"\n=== {title} ===")


def executions(flow):
    """Every execution in a flow, including those nested in sub-flows."""
    return flow.get("authenticationExecutions") or []


def all_executions(realm):
    return [e for f in realm.get("authenticationFlows") or [] for e in executions(f)]


def main():
    here = pathlib.Path(__file__).parent
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else here / "openmrs-realm.json"
    raw = path.read_text()
    realm = json.loads(raw)

    step("The template commits no secret and no hostname")

    secrets = raw.count("__SMART_LAUNCH_SECRET__")
    check(secrets == 2, "both authenticator configs carry the secret placeholder",
          f"expected 2 occurrences, found {secrets}")

    leaked = []
    for config in realm.get("authenticatorConfig") or []:
        for key, value in (config.get("config") or {}).items():
            if "secret" in key and value != "__SMART_LAUNCH_SECRET__":
                leaked.append(f"{config.get('alias')}.{key}")
    check(not leaked, "no authenticator config ships a real key", f"literal secrets in: {leaked}")

    hosts = re.findall(r'https?://[^"\s]+', raw)
    check(not hosts, "no environment's hostname is baked in",
          f"absolute URLs found: {hosts} -- use a placeholder and render with render-realm.py")

    used = set(re.findall(r"__[A-Z0-9_]+__", raw))
    renderer = (here / "render-realm.py").read_text()
    unrenderable = sorted(p for p in used if p not in renderer)
    check(not unrenderable, "every placeholder is one the renderer substitutes",
          f"template uses {unrenderable}, which render-realm.py never replaces")

    # Keycloak's directory import rejects a file whose name does not match the realm in it.
    expected_name = f"{realm['realm']}-realm.json"
    check(path.name == expected_name, "the file name matches the realm inside it",
          f"realm '{realm['realm']}' requires the file to be named {expected_name}, not {path.name}")

    step("Nothing dangles")

    defined_scopes = {s["name"] for s in realm.get("clientScopes") or []} | BUILT_IN_CLIENT_SCOPES
    dangling = []
    for client in realm.get("clients") or []:
        for field in ("defaultClientScopes", "optionalClientScopes"):
            for scope in client.get(field) or []:
                if scope not in defined_scopes:
                    dangling.append(f"{client['clientId']}.{field} -> {scope}")
    check(not dangling, "every client scope a client references is defined",
          f"{dangling}; Keycloak logs 'Referenced client scope does not exist' and continues")

    declared = {c["alias"] for c in realm.get("authenticatorConfig") or []}
    referenced = {e["authenticatorConfig"] for e in all_executions(realm) if e.get("authenticatorConfig")}
    check(referenced <= declared, "every config alias an execution references is declared",
          f"undeclared: {sorted(referenced - declared)}; the authenticator would run unconfigured")
    check(declared <= referenced, "every declared config alias is used",
          f"unused: {sorted(declared - referenced)}; it silently does nothing")

    flow_aliases = {f["alias"] for f in realm.get("authenticationFlows") or []}
    unknown_subflows = sorted(e["flowAlias"] for e in all_executions(realm)
                              if e.get("flowAlias") and e["flowAlias"] not in flow_aliases)
    check(not unknown_subflows, "every sub-flow a flow references is defined", f"unknown: {unknown_subflows}")
    check(realm.get("browserFlow") in flow_aliases, "the bound browser flow is one of the defined flows",
          f"browserFlow is '{realm.get('browserFlow')}'")

    too_long = sorted(e["authenticator"] for e in all_executions(realm)
                      if e.get("authenticator") and len(e["authenticator"]) > MAX_AUTHENTICATOR_ID)
    check(not too_long, f"authenticator ids fit Keycloak's {MAX_AUTHENTICATOR_ID}-character column",
          f"too long: {too_long}")

    step("SMART App Launch 2.x requirements")

    clients = realm.get("clients") or []
    check(bool(clients), "the realm defines at least one client")

    no_pkce = []
    for client in clients:
        if not client.get("publicClient"):
            continue
        method = (client.get("attributes") or {}).get("pkce.code.challenge.method")
        if method != "S256":
            no_pkce.append(f"{client['clientId']} -> {method!r}")
    check(not no_pkce, "PKCE S256 is mandatory on every public client",
          f"SMART 2.x requires S256 and forbids plain: {no_pkce}")

    implicit = [c["clientId"] for c in clients if c.get("implicitFlowEnabled")]
    check(not implicit, "implicit flow is off; SMART 2.x is authorization-code only", f"enabled on: {implicit}")

    scopes_by_name = {s["name"]: s for s in realm.get("clientScopes") or []}
    for name, (note, claim) in LAUNCH_SCOPES.items():
        scope = scopes_by_name.get(name)
        if scope is None:
            check(False, f"{name} is defined")
            continue
        mapper = next((m for m in scope.get("protocolMappers") or []
                       if m.get("protocolMapper") == "smart-context-claim-mapper"), None)
        if mapper is None:
            check(False, f"{name} carries the SMART context mapper")
            continue
        config = mapper.get("config") or {}
        check(config.get("user.session.note") == note, f"{name} reads the {note} session note",
              f"reads {config.get('user.session.note')!r}")
        check(config.get("claim.name") == claim, f"{name} writes the {claim} claim",
              f"writes {config.get('claim.name')!r}")
        # The key really is access.tokenResponse.claim. The plausible-looking
        # access.token.response.claim imports cleanly and emits nothing at all.
        check(config.get("access.tokenResponse.claim") == "true",
              f"{name} puts the claim in the token response",
              "access.tokenResponse.claim must be 'true'; SMART context travels in the token response")
        check("access.token.response.claim" not in config,
              f"{name} does not use the misspelled include-in-response key")

    step("What the OpenMRS side depends on")

    profile = scopes_by_name.get("profile")
    if profile is None:
        check(False, "a profile client scope exists",
              "declaring clientScopes suppresses Keycloak's built-ins, so preferred_username would "
              "never be emitted and every OpenMRS login would fail")
    else:
        mapper = next((m for m in profile.get("protocolMappers") or []
                       if (m.get("config") or {}).get("claim.name") == "preferred_username"), None)
        check(mapper is not None, "the profile scope emits preferred_username")
        if mapper is not None:
            check((mapper.get("config") or {}).get("access.token.claim") == "true",
                  "preferred_username reaches the access token",
                  "which is what the OpenMRS bearer filter reads to name the user")
        check("profile" in (clients[0].get("defaultClientScopes") or []),
              "the SMART client gets the profile scope by default")

    audience_mappers = [m for s in realm.get("clientScopes") or []
                        for m in s.get("protocolMappers") or []
                        if m.get("protocolMapper") == "oidc-audience-mapper"]
    check(bool(audience_mappers), "some client scope stamps the FHIR audience",
          "with no aud, the FHIR server refuses every token -- a launch that succeeds until the first call")
    on_a_client = [c["clientId"] for c in clients
                   for m in c.get("protocolMappers") or []
                   if m.get("protocolMapper") == "oidc-audience-mapper"]
    check(not on_a_client, "the audience mapper is on a scope, not on one client",
          f"{on_a_client} carry their own; every other app would silently fail to reach FHIR")
    if audience_mappers:
        config = audience_mappers[0].get("config") or {}
        check(config.get("included.custom.audience") == "__FHIR_BASE_URL__",
              "the audience is the rendered FHIR base", f"is {config.get('included.custom.audience')!r}")
        check(config.get("access.token.claim") == "true", "aud reaches the access token")

    validator = next((e for e in all_executions(realm)
                      if e.get("authenticator") == "smart-audience-validator"), None)
    if validator is None:
        check(False, "the audience validator runs in the flow", "SMART's aud requirement would be unenforced")
    else:
        check(validator.get("requirement") == "REQUIRED", "the audience validator cannot be skipped",
              f"is {validator.get('requirement')!r}; an ALTERNATIVE check is satisfied by a sibling")
        check(validator.get("authenticatorConfig") is not None, "the audience validator is configured",
              "it fails closed when unconfigured, so every launch would be rejected")

    unknown_authenticators = sorted({e["authenticator"] for e in all_executions(realm)
                                     if e.get("authenticator")
                                     and e["authenticator"] not in BUILT_IN_AUTHENTICATORS
                                     and not e["authenticator"].startswith("smart-")})
    check(not unknown_authenticators,
          "every non-built-in authenticator is one of ours by name",
          f"{unknown_authenticators} are neither Keycloak built-ins nor smart-*; "
          "realm/verify-realm-import.sh proves the smart-* ones actually exist")

    print()
    if failures:
        print(f"=== {len(failures)} check(s) failed ===")
        return 1
    print("=== the realm template is internally consistent ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
