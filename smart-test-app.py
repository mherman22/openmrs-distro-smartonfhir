#!/usr/bin/env python3
"""A minimal SMART app, for testing launches by hand in a browser.

A launch needs an app at both ends: something to start it, and something for the authorization
server to redirect back to. Without one, a manual test ends on a browser connection error with the
authorization code sitting unread in the address bar.

This is that app and nothing more. It starts a standalone launch, receives the redirect, exchanges
the code, and shows what it was given — the patient in particular, read back from the FHIR API with
the token it was issued. It is a development tool: the client secret handling, session storage and
error reporting a real app needs are all absent.

    ./smart-test-app.py            # then open http://localhost:3000

Configure with OPENMRS_URL, KEYCLOAK_URL, REALM, CLIENT_ID, PORT.
"""

import base64
import hashlib
import html
import json
import os
import secrets
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

OPENMRS = os.environ.get("OPENMRS_URL", "http://localhost/openmrs")
KEYCLOAK = os.environ.get("KEYCLOAK_URL", "http://localhost:8180")
REALM = os.environ.get("REALM", "openmrs")
CLIENT_ID = os.environ.get("CLIENT_ID", "smartClient")
PORT = int(os.environ.get("PORT", "3000"))

REDIRECT_URI = f"http://localhost:{PORT}/"
FHIR_BASE = f"{OPENMRS}/ws/fhir2/R4"
DEFAULT_SCOPE = "openid fhirUser launch/patient patient/Patient.rs"

# state -> PKCE verifier. In memory on purpose: this only has to survive one launch.
PENDING = {}

# The id_token from the last completed launch. Passing it back as id_token_hint is what lets the
# authorization server end the session without stopping to ask "do you want to log out?".
LAST_ID_TOKEN = {"value": None}

STYLE = """
body { font: 15px/1.5 system-ui, sans-serif; max-width: 46rem; margin: 3rem auto; padding: 0 1.5rem;
       color: #161616; background: #fff; }
h1 { font-size: 1.4rem; } h2 { font-size: 1.05rem; margin-top: 2rem; }
a.launch { display: inline-block; background: #0f62fe; color: #fff; text-decoration: none;
           padding: .7rem 1.2rem; border-radius: 4px; font-weight: 600; }
dl { display: grid; grid-template-columns: max-content 1fr; gap: .4rem 1.2rem; }
dt { color: #525252; } dd { margin: 0; font-family: ui-monospace, monospace; word-break: break-all; }
pre { background: #f4f4f4; padding: 1rem; overflow-x: auto; border-radius: 4px; font-size: .85rem; }
.bad { color: #da1e28; } .good { color: #0e6027; font-weight: 600; }
"""


def page(title, body):
    return (
        f"<!doctype html><html lang=en><head><meta charset=utf-8>"
        f"<title>{html.escape(title)}</title><style>{STYLE}</style></head>"
        f"<body><h1>{html.escape(title)}</h1>{body}</body></html>"
    ).encode()


def authorize_url(ehr_launch=None, fhir_base=None):
    """Builds an authorization request.

    Standalone by default. For an EHR launch, pass the handle the EHR supplied and the FHIR base it
    named in iss: the handle goes back as the launch parameter and the launch scope asks for the
    context the EHR already established, instead of launch/patient which would ask the authorization
    server to establish it.
    """
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("=")
    challenge = (
        base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    )
    state = secrets.token_urlsafe(16)
    PENDING[state] = verifier

    scope = os.environ.get("SCOPE", DEFAULT_SCOPE)
    if ehr_launch:
        # launch replaces launch/patient: the EHR has already chosen the patient.
        scope = "launch " + " ".join(s for s in scope.split() if not s.startswith("launch/"))

    params = {
        "client_id": CLIENT_ID,
        "response_type": "code",
        "scope": scope,
        "redirect_uri": REDIRECT_URI,
        "state": state,
        # Required: the server refuses a launch that does not name the FHIR server it means to use.
        # In an EHR launch this is the iss the EHR supplied, which the spec says are the same thing.
        "aud": fhir_base or FHIR_BASE,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    if ehr_launch:
        params["launch"] = ehr_launch

    return f"{KEYCLOAK}/realms/{REALM}/protocol/openid-connect/auth?" + urllib.parse.urlencode(params)


def post_form(url, fields):
    request = urllib.request.Request(
        url,
        data=urllib.parse.urlencode(fields).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        try:
            return error.code, json.loads(body)
        except ValueError:
            return error.code, {"error": body[:500]}


def get_json(url, token):
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, {"error": error.read().decode(errors="replace")[:500]}


def describe_patient(resource):
    names = resource.get("name") or []
    display = " ".join(
        filter(None, [" ".join((names[0].get("given") or [])), names[0].get("family")])
    ) if names else "(no name)"
    identifiers = ", ".join(i.get("value", "") for i in (resource.get("identifier") or []))

    return display, identifiers


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # quieter: one line per request is enough
        print(f"  {self.command} {self.path.split('?')[0]}")

    def reply(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)

        if parsed.path == "/logout":
            # RP-initiated logout. Ending the OpenMRS session alone is not enough: the authorization
            # server keeps its own session, and the next launch in this browser would be granted
            # silently as whoever launched last.
            params = {"post_logout_redirect_uri": REDIRECT_URI, "client_id": CLIENT_ID}
            if LAST_ID_TOKEN["value"]:
                params["id_token_hint"] = LAST_ID_TOKEN["value"]
            LAST_ID_TOKEN["value"] = None
            self.send_response(302)
            self.send_header(
                "Location",
                f"{KEYCLOAK}/realms/{REALM}/protocol/openid-connect/logout?"
                + urllib.parse.urlencode(params),
            )
            self.end_headers()
            return

        if "launch" in query and "iss" in query and "code" not in query:
            iss = query["iss"][0]
            handle = query["launch"][0]
            self.send_response(302)
            self.send_header("Location", authorize_url(ehr_launch=handle, fhir_base=iss))
            self.end_headers()
            return

        if parsed.path == "/launch":
            self.send_response(302)
            self.send_header("Location", authorize_url())
            self.end_headers()
            return

        if "error" in query:
            detail = html.escape(query.get("error_description", [""])[0] or query["error"][0])
            self.reply(400, page("The launch was refused", f"<p class=bad>{detail}</p><p><a href='/'>Start again</a></p>"))
            return

        if "code" in query:
            self.reply(200, self.complete_launch(query))
            return

        self.reply(
            200,
            page(
                "SMART test app",
                "<p>A standalone launch: this app will ask the authorization server for access, "
                "you sign in with your own OpenMRS credentials, and you choose which patient's "
                "record this app may open.</p>"
                "<p><a class=launch href='/launch'>Launch</a></p>"
                f"<h2>Configured against</h2><dl>"
                f"<dt>FHIR server</dt><dd>{html.escape(FHIR_BASE)}</dd>"
                f"<dt>Authorization server</dt><dd>{html.escape(KEYCLOAK)}/realms/{html.escape(REALM)}</dd>"
                f"<dt>Client</dt><dd>{html.escape(CLIENT_ID)}</dd></dl>",
            ),
        )

    def complete_launch(self, query):
        code = query["code"][0]
        state = query.get("state", [""])[0]
        verifier = PENDING.pop(state, None)

        if verifier is None:
            return page(
                "Unknown launch",
                "<p class=bad>This redirect carries a state this app did not issue, so the "
                "proof key for it is unknown. Start the launch from this app.</p>"
                "<p><a href='/'>Start again</a></p>",
            )

        status, granted = post_form(
            f"{KEYCLOAK}/realms/{REALM}/protocol/openid-connect/token",
            {
                "client_id": CLIENT_ID,
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": REDIRECT_URI,
                "code_verifier": verifier,
            },
        )

        if status != 200:
            return page(
                "The code could not be exchanged",
                f"<p class=bad>HTTP {status}</p><pre>{html.escape(json.dumps(granted, indent=2))}</pre>",
            )

        token = granted.get("access_token", "")
        patient_id = granted.get("patient")
        LAST_ID_TOKEN["value"] = granted.get("id_token")

        rows = [
            ("Granted scopes", granted.get("scope", "(none)")),
            ("Patient in launch context", patient_id or "(none returned)"),
            ("Token type", granted.get("token_type", "?")),
            ("Expires in", f"{granted.get('expires_in', '?')}s"),
        ]

        body = "<p class=good>The launch completed.</p><h2>What the app was given</h2><dl>" + "".join(
            f"<dt>{html.escape(k)}</dt><dd>{html.escape(str(v))}</dd>" for k, v in rows
        ) + "</dl>"

        # Whatever the launch was actually granted, read some of it. Nothing here is specific to one
        # kind of app: the resource types come from the granted scopes, so an app scoped to
        # observations demonstrates observations and one scoped to conditions demonstrates conditions.
        granted_types = [
            scope.split("/", 1)[1].split(".", 1)[0]
            for scope in (granted.get("scope") or "").split()
            if scope.startswith("patient/") and "/" in scope
        ]
        searchable = [t for t in dict.fromkeys(granted_types) if t and t != "*" and t != "Patient"]

        if patient_id and searchable:
            rows = []
            for resource_type in searchable:
                status, bundle = get_json(
                    f"{FHIR_BASE}/{resource_type}?patient={patient_id}&_count=3", token
                )
                rows.append(
                    (resource_type, f"{bundle.get('total', '?')} for this patient")
                    if status == 200
                    else (resource_type, f"HTTP {status}")
                )

            body += (
                "<h2>What this app can read for that patient</h2><dl>"
                + "".join(
                    f"<dt>{html.escape(t)}</dt><dd>{html.escape(str(v))}</dd>" for t, v in rows
                )
                + "</dl>"
            )

        # The patient the launch was scoped to, read back with the token that was issued.
        if patient_id:
            status, resource = get_json(f"{FHIR_BASE}/Patient/{patient_id}", token)
            if status == 200:
                name, identifiers = describe_patient(resource)
                body += (
                    "<h2>Reading that patient from the FHIR API</h2><dl>"
                    f"<dt>Name</dt><dd>{html.escape(name)}</dd>"
                    f"<dt>Identifiers</dt><dd>{html.escape(identifiers)}</dd>"
                    f"<dt>Gender</dt><dd>{html.escape(str(resource.get('gender', '?')))}</dd>"
                    f"<dt>Born</dt><dd>{html.escape(str(resource.get('birthDate', '?')))}</dd></dl>"
                )
            else:
                body += (
                    f"<h2>Reading that patient from the FHIR API</h2>"
                    f"<p class=bad>HTTP {status} — the token could not read the patient it was "
                    f"granted for.</p><pre>{html.escape(json.dumps(resource, indent=2))}</pre>"
                )

        body += (
            "<h2>When you are finished</h2>"
            "<p>Logging out of OpenMRS does not end the session at the authorization server, so the "
            "next launch in this browser would be granted silently as you. This ends both.</p>"
            "<p><a class=launch href='/logout'>Log out</a> &nbsp; <a href='/'>Launch again</a></p>"
        )

        return page("Launch complete", body)


if __name__ == "__main__":
    print(f"SMART test app on http://localhost:{PORT}")
    print(f"  FHIR server          {FHIR_BASE}")
    print(f"  authorization server {KEYCLOAK}/realms/{REALM}")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
