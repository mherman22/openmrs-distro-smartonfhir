openmrs-distro-smartonfhir
==========================

The OpenMRS Reference Application with SMART on FHIR: **Keycloak 26** as its authorization server, and a
SMART application that launches from a patient's chart already holding that patient's record.

**[Walk through the launch, with screenshots](docs/ehr-launch.md)** — what a clinician sees, what happens
on the wire, and why no second login appears. Then
**[the standalone launch](docs/standalone-launch.md)**, which is the same handshake without an EHR, and
**[the architecture](docs/architecture.md)** — every component, every hop, and what authenticates what.

## Getting it running

```bash
cp .env.example .env                     # then set SMART_LAUNCH_SECRET
docker compose up -d --build
```

That is the whole thing: one compose file, six services, no scripts. The first run installs the OpenMRS
database and takes several minutes; the frontend image is assembled from source and takes about the same.

Then open **http://localhost/openmrs/spa**, sign in, open a patient, and choose **Launch an app** from the
Actions menu.

### What you need first

**Docker with Compose v2. That is all.** No JDK, no Maven, no Node, and no other checkout.

The OpenMRS module, both Keycloak plugins and the frontend module are committed here as build outputs,
because none of them is published anywhere. [ARTIFACTS.md](ARTIFACTS.md) records which commit each was
built from and how to replace one. The SMART application is not committed — it is pulled as an image.

To work on one of those repositories rather than just run the stack, point `.env` at your own build tree;
ARTIFACTS.md has the three variables.

### What a first run does, and what it needs from you

The first `docker compose up -d` installs the OpenMRS database and loads demo data — 50 patients, six
users, and the concepts the vitals app reads. Expect **five to ten minutes**, and do not interrupt it: a
half-finished install leaves duplicate-constraint errors that need `docker compose down -v` and a clean
retry.

**Then restart the backend once.** OpenMRS runs its installation inside the running Tomcat, and
`InitializationFilter` keeps redirecting every request to `/openmrs/initialsetup` until the webapp comes
back up. Restart the gateway with it, or nginx keeps routing to the backend's previous container address
and every request fails to connect:

```bash
docker compose restart backend gateway
```

**Sign in as** `doctor` / `Doctor123` — a clinician with a provider record, which is what lets the launch
resolve a `fhirUser`. The administrator is `admin` / `Admin123`.

**Patient search is empty until the index is built.** FHIR reads work immediately; the search box does
not, because the Lucene index starts empty. Rebuild it from *Administration → Search Index*, or launch
from a chart reached by URL, which needs no search.

## What is here

```
docker-compose.yml     six services: db, backend, frontend, gateway, keycloak, smart-app
.env.example           the launch secret, and the overrides for a local build tree
ARTIFACTS.md           the four committed build outputs: their source commits and how to replace them
backend/               the reference application image, its config, and modules/ — the SMART omod
keycloak/              Keycloak with the JDBC driver, realm/ — the realm, and providers/ — the plugins
frontend/              the app shell, assembled with the committed SMART launch module in it
docs/                  the two walkthroughs, and architecture.md
```

The SMART application itself is not here either. It is released on its own and consumed as an image, the
way a site would consume any third-party SMART app; `SMART_APP_VERSION` in `.env` pins which one.

Everything else the reference application distribution carries — its release pipeline, TLS automation,
monitoring stack, and its own test suites — is not here. None of it is on the path of a local
demonstration, and each folder was one more thing to read before finding the four that matter.

## How the pieces are configured

**The realm is a template Keycloak fills in.** `keycloak/realm/openmrs-realm.json` holds `${OPENMRS_BASE_URL}`,
`${SMART_LAUNCH_SECRET}` and six more placeholders; Keycloak substitutes them from its own environment
during `--import-realm`. There is no rendering step and nothing generated.

**The module is configured by environment variables.** The reference application image turns
`OMRS_EXTRA_SMART_ISSUER` into the runtime property `smart.issuer`, so the compose file states which
authorization server to trust and no configuration files are written.

**One property cannot be expressed that way.** The image lowercases those names, and the authentication
module reads `authentication.whiteList` with a capital L. That, and the two properties registering the
bearer scheme, are seeded by `backend/Dockerfile`. It seeds a *fresh* volume, so changing
`backend/runtime.properties` means `docker compose down -v` too.

**The frontend is built, not pulled.** Which frontend modules exist is decided when the app shell is
assembled, so `frontend/spa-assemble-config.json` names the SMART launch module and `frontend/Dockerfile`
packs it from its own checkout, passed in as a named build context. Where the launch action *appears* is a
separate decision, made at runtime by `frontend/config-core_demo.json`.

**Keycloak waits for OpenMRS.** The user federation provider validates its mappings against the OpenMRS
schema as Keycloak starts, and on a first run that schema does not exist yet. Waiting only for the
database produced `Schema validation: missing table [person]` and a Keycloak that never came up.

## This is a development configuration

Keycloak runs `start-dev` with TLS not required, its state is deliberately not persisted so the realm
cannot drift from the committed one, and the passwords above are defaults. None of that is suitable for a
deployment holding real records.

## The repositories this assembles

| | |
|---|---|
| [openmrs-module-smartonfhir](https://github.com/mherman22/openmrs-module-smartonfhir) | discovery, bearer tokens, launch handles |
| [openmrs-contrib-keycloak-smart-auth](https://github.com/mherman22/openmrs-contrib-keycloak-smart-auth) | Keycloak's SMART OAuth2 extensions |
| [openmrs-contrib-keycloak-auth](https://github.com/mherman22/openmrs-contrib-keycloak-auth) | OpenMRS users as Keycloak's user store |
| [openmrs-esm-smart-app-launch-app](https://github.com/mherman22/openmrs-esm-smart-app-launch-app) | the chart action and the patient picker |
| [openmrs-smart-vitals-reviews-app](https://github.com/mherman22/openmrs-smart-vitals-reviews-app) | the SMART application that gets launched. Not built here -- pulled as an image. |

Those are forks. This work is not upstream yet, so cloning the `openmrs/…` repositories gives the
pre-upgrade code.

## Standalone launch

Both launches work here. **http://localhost:3000/launch.html** with no parameters is a standalone launch:
the application sends the clinician to sign in with their OpenMRS credentials and choose a patient, and the
token comes back carrying that choice. Opening it from a chart is the EHR launch, and takes the patient the
clinician was already looking at.

It works because the compose file gives the application a `SMART_ISS` -- without a FHIR server to name, a
standalone launch has nowhere to go, and the app says so rather than guessing one.

## What is not implemented

- **Scope enforcement.** Scopes are requested, granted and returned, and nothing restricts a request by
  them — so a launched application acts with the privileges of the clinician who launched it. No
  `permission-*` capability is advertised, for that reason.
- **A conformance run.** Every claim here is measured by hand. Inferno's SMART App Launch suite has not
  been run against this stack.
