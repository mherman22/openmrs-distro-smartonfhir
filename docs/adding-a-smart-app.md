# Adding a SMART app

Two things have to know about your application: **Keycloak**, so it can issue tokens to it, and
**OpenMRS**, so a clinician can launch it. Neither is a code change, and nothing here needs a rebuild.

This page uses the stack as it ships. Every value quoted is one this repository actually sets, and the
last section is what to read when the app does not appear.

## 1. Decide the app's id

The id is yours. It appears in the launch URL (`?appId=…`), in the property names, and nowhere else —
the application itself never sees it.

**No hyphens if you are setting it from the environment.** The image turns `_` into `.` when it maps a
variable to a property, and nothing maps to `-`, so `vitals-review` cannot be expressed that way.
`vitalsreview` can, and `vitals_review` is written `VITALS__REVIEW`.

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

## 3. Tell OpenMRS about the app

Which apps may be launched is runtime properties, `smart.app.<id>.<field>`. In this stack that means
environment variables in `docker-compose.yml`, under the `backend` service:

```yaml
OMRS_EXTRA_SMART_APP_GROWTHCHART_NAME: Growth Chart
OMRS_EXTRA_SMART_APP_GROWTHCHART_DESCRIPTION: Plots weight and height against WHO reference curves
OMRS_EXTRA_SMART_APP_GROWTHCHART_CLIENTID: growth-chart
OMRS_EXTRA_SMART_APP_GROWTHCHART_LAUNCHURL: https://growth.example.org/launch
OMRS_EXTRA_SMART_APP_GROWTHCHART_LAUNCHCONTEXT: patient
```

| field | required | meaning |
|---|---|---|
| `launchurl` | **yes** | Where the launch sends the browser. An app declared without one is dropped rather than listed, because listing it would show a clinician an app that fails when chosen. |
| `name` | no | What the clinician sees. Falls back to the id. |
| `description` | no | Shown under the name. |
| `clientid` | no | Recorded so a deployment can tell which Keycloak registration an app belongs to. The launch does not use it — the app sends its own. |
| `launchcontext` | no | `patient` (the default) or `encounter`. A launch asking for anything else is refused. |

The field names are lower case and unpunctuated — `launchurl`, not `launchUrl` — because the image
lower-cases the variables it maps, so a camel-cased name would arrive as something no reader looks for.

Then apply them:

```bash
docker compose up -d --force-recreate backend
```

A property change needs the container recreated: OpenMRS reads its runtime properties into memory once
at startup and never re-reads them.

## 4. Check the server took it

```bash
curl -u admin:Admin123 -c /tmp/c http://localhost/openmrs/ws/rest/v1/session
curl -b /tmp/c http://localhost/openmrs/ws/rest/v1/smartonfhir/apps
```

```json
{
  "apps": [
    { "id": "vitalsreview", "name": "Vitals Review", "launchContext": "patient" },
    { "id": "growthchart", "name": "Growth Chart", "launchContext": "patient" }
  ],
  "problems": []
}
```

`problems` is the registry saying what it refused and why, and it is served only to a user holding
*View Administration Functions*. An empty list means everything declared was registered.

## 5. Launch it

From the chart: **Launch an app** in the patient banner's Actions menu. The menu lists what the server
returned above, and is hidden when nothing is registered.

By hand, which is what the menu does:

```
{openmrs}/ms/smartEhrLaunchServlet?appId=growthchart&patientId={patient uuid}
```

That answers `302` to your `launchurl` with `iss` and `launch` appended — the launch notification SMART
defines. A patient that does not exist answers `404`, and an app that is not registered answers `404`
too: the address is looked up rather than taken from whoever starts the launch.

## When it does not appear

Ask the server first — `problems` above names most mistakes exactly:

| what you see | what it means |
|---|---|
| `Ignoring runtime property 'smart.app.x.launchurll': 'launchurll' is not a field of a SMART app registration` | A misspelled field. The app may still be registered from its other properties. |
| `Ignoring the app 'x': it has no launchUrl, so a launch would have nowhere to go` | Only optional fields were set, or `launchurl` was misspelled. One typo produces both this line and the one above it. |
| `Ignoring runtime property 'smart.app.x': expected smart.app.<id>.<field>` | A key with no field part. |
| Nothing in `problems`, and the app is absent | The properties never arrived. Check them inside the container: `docker compose exec backend grep '^smart.app' /openmrs/data/openmrs-runtime.properties`. |
| The app is listed, but the menu is empty | The frontend module has to be *in the app shell*, which is decided when the frontend image is built. See ARTIFACTS.md. |
| The launch reaches the app, which then fails at the token endpoint | Keycloak, not OpenMRS: check the client's redirect URIs and that its scopes exist as client scopes. |

**Removing an app is not symmetrical.** Deleting the variables is not enough: the image merges
`OMRS_EXTRA_*` into `openmrs-runtime.properties` on the data volume and keeps what that file already
had, so the property outlives the variable. Delete its lines from that file and recreate the container:

```bash
docker compose exec backend sed -i '/^smart\.app\.growthchart\./d' /openmrs/data/openmrs-runtime.properties
docker compose up -d --force-recreate backend
```

## What the application itself has to do

Nothing in this repository, and that is the point — a SMART application is a third-party artefact that
reads the record over the FHIR API. It needs to handle the launch notification (`iss` and `launch`),
exchange the code with PKCE, and read the launch context out of the **token response** rather than out
of the access token. [INTEGRATING.md in the
module](https://github.com/openmrs/openmrs-module-smartonfhir/blob/fm2/687-7-docs/INTEGRATING.md) is
the app-developer path, hop by hop (on the branch under review; it reaches `master` when the stack
merges), and [docs/ehr-launch.md](ehr-launch.md) shows every request and response
a real launch produced.
