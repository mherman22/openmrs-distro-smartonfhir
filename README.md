# SMART on FHIR distribution and development environment

Brings up **OpenMRS Reference Application 3.7.1** alongside **Keycloak 26**, with the
SMART provider installed and the SMART realm imported. This is the environment the
2.0 revamp is developed against.

```bash
cp .env.example .env       # optional; every value has a working default
./up.sh                    # build the provider, render the realm, start the stack
./verify-env.sh            # assert the environment is actually usable
```

First run pulls several GB and OpenMRS builds its database, so expect it to take a
while. Subsequent runs are fast.

| | |
|---|---|
| OpenMRS | <http://localhost/openmrs> |
| O3 frontend | <http://localhost/openmrs/spa> |
| FHIR base | <http://localhost/openmrs/ws/fhir2/R4> |
| SMART discovery | <http://localhost/openmrs/ws/fhir2/R4/.well-known/smart-configuration> |
| Keycloak | <http://localhost:8180> (`admin`/`admin`) |
| Dev clinician | `doctor` / `Smart123` — a Keycloak user matching an OpenMRS demo user |

## Requirements

- Docker with Compose v2, and a running daemon
- **JDK 17 or newer** to build the Keycloak provider. If your default `java` is
  older, point `SMART_JAVA_HOME` at a suitable JDK:
  ```bash
  SMART_JAVA_HOME=$(/usr/libexec/java_home -v 21) ./up.sh --rebuild
  ```
- The other repositories checked out **beside this one**, or the matching variable pointing
  at each:

  | Repository | Variable | What it contributes |
  |---|---|---|
  | `openmrs-module-smartonfhir` | `MODULE_REPO` | the OpenMRS module |
  | `openmrs-contrib-keycloak-smart-auth` | `SMART_AUTH_REPO` | Keycloak SMART launch SPI, and the realm |
  | `openmrs-contrib-keycloak-auth` | `USERSTORE_REPO` | Keycloak user federation against OpenMRS |
  | `openmrs-esm-smart-app-launch-app` | `ESM_REPO` | the patient-selection screen |

  Only the module and the SMART SPI are required. Without the federation provider, Keycloak
  users are created and maintained by hand; without the ESM, standalone launch has no
  patient-selection screen.

## Why `up.sh` rather than `docker compose up`

Three things must happen before the containers start, and Keycloak starts without
any of them if you skip the script:

1. **The provider JAR is built** from the sibling Keycloak SPI checkout.
2. **The realm is rendered** from its template. The committed realm holds
   placeholders, never a secret and never an environment's hostnames, so it has to
   be rendered with a generated HS256 key and this environment's URLs.
3. **The same secret is written where the OpenMRS module reads it**
   (`target/openmrs-config/smart-secret-key.json`), so both ends of the app-token
   handshake agree. They are useless if they drift.

Everything `up.sh` generates lands under `target/`, which is git-ignored.

## How the bearer scheme is registered

The authentication module reads its settings from **`openmrs-runtime.properties`**, filtered
by the `authentication.` prefix — not from a file of its own. `up.sh` therefore appends:

```properties
authentication.scheme=smartBearer
authentication.scheme.smartBearer.type=org.openmrs.module.smartonfhir.web.smart.SmartBearerTokenAuthenticationScheme
```

That is also the instruction for a real deployment. Two things about it are easy to get
wrong:

- A separate `authentication-runtime.properties` is **never read**.
  `reloadConfigFromRuntimeProperties` takes the *application* name and uses
  `authentication` as a key prefix.
- The scheme is registered so that `Context.authenticate` can route SMART credentials to
  it. It deliberately returns no credentials and no challenge URL of its own, because the
  authentication module's filter is mapped to `/*`: a scheme that returns credentials there
  makes that filter authenticate the request and then issue its interactive-login **success
  redirect**, which is a 302 where a FHIR client expects data. Reading the bearer header is
  `SmartBearerTokenFilter`'s job, scoped to the FHIR paths.

## Development-only Keycloak changes

`up.sh` applies two things at runtime that are **not** in the committed realm, so the realm
stays production-shaped and no credential is in version control:

- direct access grants on `smartClient`, so a test can obtain a token without a browser;
- a Keycloak user matching an OpenMRS demo user. Until the user-federation provider is
  ported, Keycloak has no knowledge of OpenMRS users, so the two are lined up by hand.

Keycloak is recreated on every run. It holds no durable state by design, and realm import
uses `IGNORE_EXISTING` — against a container whose realm already exists, an edited realm is
silently ignored, so recreating it is what makes a realm change take effect at all.

## URLs have to be browser-reachable

The SMART launch and patient-selection URLs in the realm are **browser redirects**.
A container-internal hostname such as `http://backend:8080` cannot work: the
browser has to resolve it. Likewise the `aud` value the audience validator accepts
must be the FHIR base *as the app names it*, not as another container sees it. This
is why the realm is rendered per-environment rather than committed with URLs in it.

If you change `OPENMRS_PORT`, re-run `./up.sh` so the realm is re-rendered.

## Commands

| | |
|---|---|
| `./up.sh` | build, render, start, wait for readiness |
| `./up.sh --rebuild` | force a rebuild of the provider JAR |
| `./up.sh --down` | stop and remove containers, keep data |
| `./up.sh --clean` | stop and remove containers **and volumes** |
| `./verify-env.sh` | assert the environment works |
| `docker compose logs -f keycloak` | follow Keycloak |

## What `verify-env.sh` checks

Beyond "the containers are up": that OpenMRS answers through the gateway, that the
O3 frontend is served, that `/ws/rest/v1/session` responds (the ESM app shell will
not boot without it), that the FHIR endpoint is mapped, that Keycloak advertises
PKCE `S256` and the SMART launch scopes, that all four SMART providers registered,
and that **a launch naming the wrong FHIR server is rejected before the login form**.

## Keycloak is pinned on purpose

Every SPI the provider implements is internal to Keycloak — the server logs
`KC-SERVICES0047` for each one — so a minor upgrade can break it with no
deprecation cycle. Before moving `KEYCLOAK_TAG`, run
`realm/verify-realm-import.sh <new-version>` in the SPI repository and confirm it
is green.

## This is a development configuration

Keycloak runs `start-dev` with an embedded database over plain HTTP, and the
credentials here are the defaults. Do not model a deployment on it.

## The patient-selection screen

The screen a standalone launch redirects to lives in `openmrs-esm-smart-app-launch-app`. It is
a frontend module, so it is not part of the container images here; run it against this stack
with the O3 dev server:

```bash
cd ../openmrs-esm-smart-app-launch-app
npm start -- --backend http://localhost
```

That serves the app shell with this module in it, and proxies API calls to the stack. Adding it
to the dockerised frontend instead means rebuilding that image with an extra entry in
`spa-assemble-config.json`, which is worth doing once the module is published.

## Registering your own app

Any SMART app can launch against this stack; nothing is specific to the one that ships with it. The
step-by-step instructions live in
[INTEGRATING.md](https://github.com/mherman22/openmrs-module-smartonfhir/blob/2.0.x/INTEGRATING.md)
in the module repository — admin console click-path and the `kcadm.sh` equivalent.

Two things specific to this development stack:

**Your client does not survive a restart.** `up.sh` recreates Keycloak and its database lives inside
the container, so a client registered through the admin console is gone after the next `./up.sh`.
Either register it again, or add it to `realm/openmrs-realm.json` in
[openmrs-contrib-keycloak-smart-auth](https://github.com/openmrs/openmrs-contrib-keycloak-smart-auth)
so it is imported every time. The second is the better answer if you are iterating for more than an
afternoon.

**Two apps side by side is the useful demonstration** — the shipped one on 3000 and something quite
different on 3100:

```bash
./smart-test-app.py &

CLIENT_ID=risk-dashboard PORT=3100 \
  SCOPE="openid fhirUser launch/patient patient/Observation.rs patient/Condition.rs" \
  ./smart-test-app.py &
```

Register `risk-dashboard` with redirect URI `http://localhost:3100/*` first. Both apps then get the
same login, the same patient-selection screen and the same FHIR access, and neither required a change
to the module.

## Testing a launch by hand

A launch needs an app at both ends: something to start it, and something for the authorization
server to redirect back to. `smart-test-app.py` is the smallest thing that qualifies — it starts a
standalone launch, receives the redirect, exchanges the code, and reads the patient it was given back
from the FHIR API.

```bash
./smart-test-app.py          # then open http://localhost:3000 and press Launch
```

Sign in as the dev user with their own OpenMRS password, choose a patient, and the app shows the
granted scopes, the patient in launch context, and that patient read back over FHIR with the token
it was issued. Configure it with `OPENMRS_URL`, `KEYCLOAK_URL`, `REALM`, `CLIENT_ID`, `SCOPE`
and `PORT`.

It is a development tool. It keeps PKCE verifiers in memory, stores nothing, and reports errors as
plain pages; none of that is what a real app should do.

For the same walk unattended, the frontend module carries a Playwright spec covering it
(`yarn test:e2e` in openmrs-esm-smart-app-launch-app), and `./verify-env.sh` walks it with curl.

## Status

RefApp 3.7.1 and Keycloak 26 run together with the `smartonfhir` omod installed and
configured. `verify-env.sh` covers the whole bearer path, including obtaining a real token
and reading FHIR data with it.

Not yet built: the patient-selection UI, so the interactive launch flows cannot be walked
end to end in a browser; the Keycloak user-federation provider, which is why the dev user
is lined up by hand; and granular scope enforcement, which belongs in fhir2's resource
providers rather than here.
