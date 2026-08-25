# SMART on FHIR with OpenMRS

What SMART solves, which component answers which question, why the launch is silent, what the scopes mean,
and what is not finished. Targets Reference Application 3.x, Keycloak 26 and SMART App Launch 2.x, and
supersedes the 2021 guide written for Keycloak 14 and the RefApp 2.x user interface.

This page used to be the module's GitHub wiki. It lives here now, beside the stack it describes, so that a
change to the compose file or the realm and the change to its explanation are the same commit and the same
review.

If you are new to this, read from the top — the sections build on each other, and the first assumes no
prior knowledge of SMART.

## Quick answers

| | |
|---|---|
| **Why is there no Keycloak login page?** | [Why no login page appears](#why-no-login-page-appears). Authentication happens during the launch, not at OpenMRS login, and OpenMRS vouches with its own session cookie. |
| **How do I run it?** | [`docker compose up -d`](../README.md#getting-it-running). Every artefact is committed, so nothing needs building first. |
| **How is it configured?** | [Runtime properties, with one file for the authorization server](../README.md#how-the-pieces-are-configured). |
| **What does `patient/Observation.rs` mean?** | [Scopes](#scopes-and-what-this-stack-does-with-them). A compartment, a resource type and a set of interactions — and a ceiling, not a grant. |
| **Why are scopes not enforced?** | [What is not implemented](#what-is-not-implemented-and-why). The prerequisite is in place; fhir2 offers no supported way to add a HAPI interceptor. |
| **What does a launch actually look like?** | [EHR launch](ehr-launch.md) and [standalone launch](standalone-launch.md), photographed, with every request and response. |
| **The launch button is missing.** | [Troubleshooting](#troubleshooting). The frontend module has to be in the app shell, which is decided when the image is built. |


## The problem it solves

A clinician is looking at a patient in OpenMRS and wants a tool the EHR does not have — a growth chart, a
risk calculator, a specialist decision aid. Historically that meant somebody writing an OpenMRS module,
for OpenMRS, in Java.

SMART turns that around. The tool is an ordinary web application. It reads the patient's record through
the EHR's FHIR API, using an OAuth2 access token the EHR's authorization server issued to it. The same
application runs against Epic, Cerner and OpenMRS without changes, because all three implement the same
launch handshake.

Three things have to be true for that to work, and they are what this stack provides:

1. **The application must be told which patient**, without the clinician retyping anything. That is
   *launch context*.
2. **The application must get a token** scoped to what it needs, without ever seeing the clinician's
   password. That is the OAuth2 authorization code flow, with the EHR's authorization server in the
   middle.
3. **The FHIR API must accept that token** and act as the right user.

## The two ways an application starts

**EHR launch.** The clinician is already working in the chart and clicks the application. The EHR knows
which patient, and tells the application. *Scenario: a nurse recording a child's weight opens a growth
chart, and it comes up on that child, already plotted.*

**Standalone launch.** The clinician opens the application directly — a bookmark, a desktop shortcut — and
the application has to ask who the patient is. *Scenario: a clinician opens the same growth chart from a
browser bookmark at the start of a shift, and is shown a patient search before any data appears.*

This stack implements both, end to end, and both are walked through with screenshots and captured traffic:
[EHR launch](ehr-launch.md) and [standalone launch](standalone-launch.md). The demonstration application
implements both halves, and the end-to-end suite exercises them on every run.

## Who does what

Six repositories, because six different questions need answering.

| | Answers | Required? |
|---|---|---|
| [openmrs-module-smartonfhir](https://github.com/mherman22/openmrs-module-smartonfhir) | How does the FHIR server take part in a launch, and how does it verify tokens? | Yes |
| [openmrs-contrib-keycloak-smart-auth](https://github.com/mherman22/openmrs-contrib-keycloak-smart-auth) | How does the authorization server implement SMART's OAuth2 extensions? | Yes |
| [openmrs-contrib-keycloak-auth](https://github.com/mherman22/openmrs-contrib-keycloak-auth) | Where do Keycloak's users come from? | Recommended |
| [openmrs-distro-smartonfhir](https://github.com/mherman22/openmrs-distro-smartonfhir) | How are all of these wired together into something that runs? | To run it |
| [openmrs-esm-smart-app-launch-app](https://github.com/mherman22/openmrs-esm-smart-app-launch-app) | Where does a clinician click? | For the UI |
| [openmrs-smart-vitals-reviews-app](https://github.com/mherman22/openmrs-smart-vitals-reviews-app) | What does a SMART application that reads this record look like? | No — it is the demonstration |

**The module** publishes the SMART discovery document, verifies the bearer tokens presented on FHIR
requests, issues the opaque handle that starts a launch, and signs the statement that says *this clinician,
this patient*. It never issues tokens and never holds credentials.

**The Keycloak SMART plugin** supplies the authenticators that carry a launch through the authorization
server, the protocol mapper that puts the chosen patient into the token, and the validator that enforces
the `aud` parameter SMART requires. Without it a launch completes and the application receives no patient
at all, so it is not optional.

**The user federation plugin** makes the OpenMRS `users` table Keycloak's user database, so clinicians sign
in with the password they already have. Keycloak could find users elsewhere — its own store, LDAP — and the
launch still works; without it, every clinician exists twice and the copies must be kept in step by hand.

**The distribution** is the realm, the compose file, and the configuration that makes the other four agree.

**The frontend module** is the *Launch an app* action in the patient chart and the patient-selection screen
a standalone launch lands on.

The two Keycloak plugins share no code. The only thing linking them is a claim: the module maps a token to
an OpenMRS user by `preferred_username`, so whatever identity source you use, that claim must match a real
OpenMRS username.

**The demonstration application** is a third-party SMART app as far as this stack is concerned: released on
its own, pulled as a published image, given a client id and a FHIR server through its environment and
nothing else. This distribution holds none of its source.

The module's own work is in review upstream as a stack of six pull requests against
`openmrs/openmrs-module-smartonfhir` — #35, then #29 through #33. Until they land, cloning the
`openmrs/…` repositories gives the pre-upgrade Keycloak 14 code, which is why the links above point at the
forks.

## Running it, and configuring it

The [README](../README.md) is the operational half of this page: what a first run does, what it needs from
you, and how each piece is configured. Two things worth knowing before you read it — the stack configures
the module entirely from environment variables, and every artefact it needs is committed, so
`docker compose up -d` is the whole of it.

## A launch, step by step

Both flows are documented as walkthroughs rather than as prose here, because both are photographed against
a running stack and quote the traffic they actually produced:

- **[An EHR launch](ehr-launch.md)** — from the chart to the application holding the patient, with the
  request and response of every hop.
- **[A standalone launch](standalone-launch.md)** — the same flow started from a bookmark, where the
  authorization server has to ask which patient.
- **[Architecture](architecture.md)** — the containers, and sequence diagrams of both flows.

## Why no login page appears

This is the most common question, and the answer is not single sign-on.

Authentication happens **at launch time, synchronously**, inside the redirect chain of a launch. It does not
happen at OpenMRS login: before the first launch there is no Keycloak cookie at all.

So Keycloak does have to authenticate the clinician on the fourth hop of [an EHR launch](ehr-launch.md#what-happened-on-the-wire) — it has never seen them. It simply does not
ask. It delegates to OpenMRS, which reads its own session cookie and signs a token asserting who this is.
Keycloak accepts it because it holds the same secret. **The EHR vouches; Keycloak does not peek.**

The proof is what happens when you remove that cookie: launch from a browser with no OpenMRS session and
Keycloak falls through to a password form. The silence is an OpenMRS session cookie doing the work, not SSO.

## Scopes, and what this stack does with them

A scope like `patient/Observation.rs` packs three separate claims:

| Part | Means |
|---|---|
| `patient/` | only the launch patient's data — a *compartment* |
| `Observation` | only this resource type |
| `.rs` | read and search only; no create, update or delete |

SMART 2.x spells interactions `c r u d s`; the older syntax says `.read`, `.write`, `.*`. And the governing
rule: **a scope is a ceiling, never a grant.** `patient/Observation.rs` does not give an application
permission to read Observations — it limits it to at most that, within whatever the clinician could already
do. Correct enforcement is the intersection of the two.

This stack advertises `patient/Patient.rs`, `patient/Observation.rs`, `patient/Condition.rs` and
`patient/Encounter.rs`, grants them, and returns them in the token — and **does not enforce them.** See [what is not implemented](#what-is-not-implemented-and-why)
for why, and why no `permission-*` capability is claimed as a result.

## What protects what

- **`aud` is validated** before authentication, by a Keycloak authenticator that fails closed. This is
  SMART's defence against an application being tricked into sending its token to a counterfeit FHIR
  server, and it is the reason a custom authenticator is needed at all: vanilla Keycloak ignores the
  parameter.
- **PKCE `S256` only.** `plain` is neither advertised nor accepted.
- **Launch handles** are 256-bit, opaque, single-use, and bound to the clinician who minted them. They used
  to be the patient UUID, which is guessable and discloses the very thing it stands for.
- **The launch address comes from the registry**, so the launch servlet cannot be told where to send a
  handle.
- **The shared secret has no default.** Anything able to sign with it can assert any username to Keycloak
  without a password, so the module fails closed when it is absent rather than trusting a built-in key.
- **Bearer tokens are verified locally** against published keys, with asymmetric algorithms only —
  permitting an HMAC algorithm would mean accepting a token signed with a secret this module also knows.
- **Refusals say nothing.** A rejected token gets `WWW-Authenticate: Bearer error="invalid_token"` and the
  reason is logged, never returned, so a caller cannot probe which check failed.

## What is not implemented, and why

**Scope enforcement.** Scopes are requested, granted and returned; nothing restricts a request by them, so
a launched application acts with the privileges of the clinician who launched it. Two things were in the
way. The first is now fixed: the access token carries `patient`, so the server can finally know which
patient a token was scoped to. The second remains — fhir2 4.2.0 offers no supported way for another module
to contribute a HAPI interceptor. `FhirRestServlet` unregisters every interceptor and registers a fixed
list, and it does so on every module start or stop, so an interceptor registered at runtime would work
until the next module event and then silently stop.

A servlet filter could refuse by resource type and interaction, and reject a search that does not name the
launch patient. It could not police `GET /Observation/{id}`, because the request carries no patient and the
resource has to be loaded to know whose it is. Enforcement that blocks searches but lets instance reads
through looks like a boundary and is not, which is why the partial version has not been built.

**Encounter context** works — an EHR launch naming a visit returns it as `encounter` — but is not
advertised, because no environment exercises it and a capability nothing walks is one nobody notices
breaking.

**Backend Services** (`client_credentials`, `system/` scopes) is not implemented at all.

**A conformance run.** Every claim on this page is measured by hand. Inferno's SMART App Launch STU2.2
suite has not been run against this stack, and until it has, the honest phrasing is "conforms as far as we
have measured."

## Keycloak upgrades

Every SPI these plugins implement is one Keycloak marks internal — the server logs `KC-SERVICES0047` for
each — so a minor upgrade can break them with no deprecation cycle and no compiler warning. The version is
pinned deliberately. Things measured the hard way, worth checking on any bump:

- Authenticator provider ids must be **≤ 36 characters** — the column is `VARCHAR(36)`.
- An authentication flow's `description` must be **≤ 255 characters**.
- `AuthenticationExecutionExportRepresentation` **rejects unknown fields**, so a `_comment` key in an
  execution fails the whole realm import.
- The include-in-token-response config key is `access.tokenResponse.claim`. The wrong spelling imports
  cleanly and silently emits nothing.
- Declaring `clientScopes` in a realm suppresses Keycloak's built-ins, so `profile` must be declared
  explicitly or there is no `preferred_username`.
- The admin API refuses requests through a published port with `HTTPS required`; use `kcadm.sh` inside the
  container.

## Troubleshooting

**No *Launch an app* in the chart.** The frontend module has to be *in the app shell*, which is decided
when the image is built, not at runtime. Check `frontend/spa-assemble-config.json` names it, and remember
`docker compose build` does not replace a running container — `up -d` does.

**The launch spins between OpenMRS and Keycloak.** Fixed, but the shape is worth knowing: it happened when
OpenMRS returned no token and the authenticator re-challenged instead of letting the flow move on.

**`Schema validation: missing table [person]`** on a first run. Keycloak's federation provider validates
its mappings against the OpenMRS schema at startup, and on a fresh database that schema does not exist yet.
The compose file makes Keycloak wait for the backend to be healthy.

**The application receives the wrong patient.** Check the flow order in [architecture.md](architecture.md) — this is what
`smart-access-authenticator` running after `auth-cookie` looks like.

**`invalid_scope`.** Keycloak only grants a scope that exists as a client scope in the realm. Wildcards
such as `patient/*.rs` are not expanded for you.

## Where things live

| | |
|---|---|
| Discovery document | `{fhirBase}/.well-known/smart-configuration` |
| Launch entry point | `/openmrs/ms/smartEhrLaunchServlet` |
| The vouching endpoint | `/openmrs/smartonfhir/smartAccessConfirmation` |
| Launchable applications | registered through `/openmrs/ws/rest/v1/smartapp` |
| The realm | `keycloak/realm/openmrs-realm.json` in the distribution |
| Where the launch action appears | `frontend/config-core_demo.json` |
| Which frontend modules exist | `frontend/spa-assemble-config.json` |
| Which authorization server is trusted | the `OMRS_EXTRA_SMART_ISSUER` and `OMRS_EXTRA_SMART_AUDIENCE` variables in `docker-compose.yml` |
| Every committed binary, and what it was built from | [ARTIFACTS.md](../ARTIFACTS.md) |
