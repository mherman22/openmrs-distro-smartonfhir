# Adding a SMART app

Two things have to know about your application: **Keycloak**, so it can issue tokens to it, and
**OpenMRS**, so a clinician can launch it. Neither is a code change, and nothing here needs a rebuild.

This page uses the stack as it ships. Every value quoted is one this repository actually sets, and the
last section is what to read when the app does not appear.

## 1. What identifies an app

Nothing to decide: registering an app returns a `uuid`, and that is what the launch URL carries
(`?appId=…`). The application itself never sees it.

## 2. Tell Keycloak about the app

The realm ships one client, `smartClient`, which the demonstration application uses. A second
application can either reuse it or get its own; a real deployment gives each application its own client,
because the client id is how the authorization server tells them apart.

To add one in the admin console — `http://localhost:8180`, `admin` / `admin` — create a client with:

| setting | value | why |
|---|---|---|
| Client authentication | **off** (public client) | A browser application cannot keep a secret. |
| Standard flow | **on** | Authorization code is the flow SMART defines. |
| Direct access grants | **off** | Password grant has no place in a SMART launch. |
| Valid redirect URIs | your app's redirect, e.g. `http://localhost:3000/*` | Keycloak refuses any other target. |
| Web origins | `+` | Lets the browser call the token endpoint from that origin. |
| `pkce.code.challenge.method` | `S256` | SMART App Launch 2.x requires PKCE, `S256` only. |

Then give it the scopes an application needs. `smartClient` has `profile`, `fhirUser`, `launch` and
`fhir-audience` as defaults, with `launch/patient`, `launch/encounter` and the `patient/*.rs` reads
optional. A scope that is not defined as a client scope is refused with `invalid_scope` rather than
ignored, so add what you intend to grant and nothing more.

To make the change survive a restart, put it in `keycloak/realm/openmrs-realm.json` instead: the realm
is re-imported on every start, so anything added through the console alone is lost.

## 3. Register it with OpenMRS

Which apps may be launched is held in the database and managed through the REST resource, so
registering one needs no restart and no change to `docker-compose.yml`.

```bash
curl -u admin:Admin123 -c /tmp/c http://localhost/openmrs/ws/rest/v1/session
curl -b /tmp/c -X POST http://localhost/openmrs/ws/rest/v1/smartapp \
  -H 'Content-Type: application/json' \
  -d '{"name":"Growth Chart",
       "description":"Plots weight and height against WHO reference curves",
       "launchUrl":"https://growth.example.org/launch",
       "clientId":"growth-chart",
       "launchContext":"patient"}'
```

| field | required | meaning |
|---|---|---|
| `name` | **yes** | What the clinician sees. Unique: two apps of one name are indistinguishable in a menu. |
| `launchUrl` | **yes** | Where the launch sends the browser. Must be `http` or `https`. |
| `description` | no | Shown under the name. |
| `clientId` | no | Recorded so a deployment can tell which Keycloak registration an app belongs to. The launch does not use it — the app sends its own. |
| `launchContext` | no | `patient` (the default) or `encounter`. |

Writing needs *Manage SMART Apps*; reading the list needs *Get SMART Apps*. A registration that could
not be launched is refused with `400` rather than stored, so a bad launch URL or a duplicate name is a
failed request, not an app that appears and then fails when chosen.

## 4. Check the server took it

```bash
curl -b /tmp/c 'http://localhost/openmrs/ws/rest/v1/smartapp?v=custom:(uuid,display,launchContext)'
```

```json
{
  "results": [
    { "uuid": "423ff4c6-cb5f-4795-9ecf-62b171a82211", "display": "Vitals Review", "launchContext": "patient" },
    { "uuid": "e3f4d1f8-b410-4ba2-809f-cf077acbc02d", "display": "Growth Chart", "launchContext": "patient" }
  ]
}
```

## 5. Launch it

From the chart: **Launch an app** in the patient banner's Actions menu. The menu lists what the server
returned above, and is hidden when nothing is registered.

By hand, which is what the menu does:

```
{openmrs}/ms/smartEhrLaunchServlet?appId={app uuid}&patientId={patient uuid}
```

That answers `302` to your `launchUrl` with `iss` and `launch` appended — the launch notification SMART
defines. An app that is not registered answers `404`, and a patient that does not exist answers `400`:
the address is looked up rather than taken from whoever starts the launch.

## Retiring one

```bash
curl -b /tmp/c -X DELETE 'http://localhost/openmrs/ws/rest/v1/smartapp/{uuid}?reason=replaced'
```

`204`, and it leaves the list. Retiring is reversible and keeps the record; `POST .../{uuid}?purge=true`
deletes it outright.

## When it does not appear

| what you see | what it means |
|---|---|
| `400` with *A SMART app needs a launch URL* | `launchUrl` was missing or blank. |
| `400` with *must be an http or https URL* | A launch URL that a browser cannot be sent to. |
| `400` with *is already registered* | Another app holds that name. Edit that one, or choose another name. |
| `403` on the POST | The user lacks *Manage SMART Apps*. |
| The app is registered, but the menu is empty | The frontend module has to be *in the app shell*, which is decided when the frontend image is built. See ARTIFACTS.md. |
| The launch reaches the app, which then fails at the token endpoint | Keycloak, not OpenMRS: check the client's redirect URIs and that its scopes exist as client scopes. |

## What the application itself has to do

Nothing in this repository, and that is the point — a SMART application is a third-party artefact that
reads the record over the FHIR API. It needs to handle the launch notification (`iss` and `launch`),
exchange the code with PKCE, and read the launch context out of the **token response** rather than out
of the access token. [INTEGRATING.md in the
module](https://github.com/openmrs/openmrs-module-smartonfhir/blob/fm2/687-7-docs/INTEGRATING.md) is
the app-developer path, hop by hop (on the branch under review; it reaches `master` when the stack
merges), and [docs/ehr-launch.md](ehr-launch.md) shows every request and response
a real launch produced.
