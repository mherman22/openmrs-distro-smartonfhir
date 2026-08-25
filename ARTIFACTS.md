# Shipped artefacts

Four build outputs are committed to this repository so that a clone starts with
`docker compose up -d` and nothing else. They are here because none of them is published: the two
OpenMRS modules and the Keycloak plugin have no release and no snapshot deployment, and the frontend
module cannot go to npm under a scope that is not ours.

Committing a binary means it can silently drift from the source it was built from, so each one records
the commit it came from. **If you change any of those repositories, the matching artefact here is stale
until you replace it** — the table below is the only thing that says so.

Two rows carry a commit their branch has since moved past, and deliberately: the `Built from` column
states what was actually compiled, not what is newest. Both are checked below.

| Artefact | Built from | Commit | SHA-256 |
|---|---|---|---|
| `backend/modules/smartonfhir.omod` | [openmrs-module-smartonfhir](https://github.com/mherman22/openmrs-module-smartonfhir) | `4927d67` (fm2/687-7-docs) | `5eddbf8df72be75df1116d6569c3c60b…` |
| `keycloak/providers/keycloak-smart-auth.jar` | [openmrs-contrib-keycloak-smart-auth](https://github.com/mherman22/openmrs-contrib-keycloak-smart-auth) | `c755f00` (FM2-690) | `35f577b9ebd9e264597dd719753e0180…` |
| `keycloak/providers/openmrs-keycloak-userstore.jar` | [openmrs-contrib-keycloak-auth](https://github.com/mherman22/openmrs-contrib-keycloak-auth) | `3d355a5` (FM2-689) | `69ae8721fa9f36e9a03b55f3fd0aeb1f…` |
| `frontend/esm-smart-app-launch.tgz` | [openmrs-esm-smart-app-launch-app](https://github.com/mherman22/openmrs-esm-smart-app-launch-app) | `e45c585` (main) | `44ed7c06283bcb8f8b1025f8fdb5b6bd…` |

### Where a row is behind its branch, and why it is still current

`openmrs-keycloak-userstore.jar` was built from `3d355a5`, which now survives only on
`backup/pre-fm2-689`; the branch has moved to `FM2-689`. Nothing under `openmrs-keycloak-userstore/`
differs between the two — the only change since is a pull request template — so the jar is current and
rebuilding it would produce the same classes under a new timestamp.

Verified by diffing the recorded commit against the branch head, not assumed. A row whose *source*
changes is a different matter, and means a rebuild -- which is what the frontend archive just had, for
content-addressed chunk names.

`keycloak-smart-auth.jar` and `keycloak/realm/openmrs-realm.json` have to be replaced together: the
authenticator config keys are named in both, and a mismatch imports a realm whose config the plugin
never reads, so every launch fails with nothing configured.

`smartonfhir.omod` is newer than the module's last release because the stack it comes from is not
merged yet: it was rewritten to declare launchable apps in the runtime properties instead of a JSON
file, and `fm2/687-7-docs` on openmrs/openmrs-module-smartonfhir carries that rewrite. This
distribution needs that build -- the compose environment declares apps the way only it reads.

### Replacing the frontend archive changes every chunk URL

Its lazy chunks are named `[id].[contenthash].js` now, so a rebuild that changes their contents changes
their URLs. That is deliberate: they used to be `117.js` and so on, served from a directory whose version
never moves, and a browser holding one from an earlier build renders nothing but
`__webpack_modules__[e] is undefined`. It also means the frontend image must be rebuilt for a new archive
to reach anyone -- `docker compose up -d --build frontend` -- because the archive is baked in rather than
mounted.

The SMART application itself is **not** here: it is published as an image and pulled at run time. See
`SMART_APP_VERSION` in `.env.example`.

## Replacing one

Building the Java artefacts needs **JDK 17 or newer**. On Java 8 the build fails with
`invalid flag: --release`, which is the same failure as a missing toolchain and reads like a broken
build rather than a wrong JDK.

```bash
# the OpenMRS module
(cd ../openmrs-module-smartonfhir && mvn clean install)
cp ../openmrs-module-smartonfhir/omod/target/smartonfhir-2.0.0-SNAPSHOT.omod \
   backend/modules/smartonfhir.omod

# Keycloak's SMART OAuth2 extensions
(cd ../openmrs-contrib-keycloak-smart-auth && mvn clean install)
cp ../openmrs-contrib-keycloak-smart-auth/keycloak-smart-auth/target/keycloak-smart-auth-1.0.0-SNAPSHOT.jar \
   keycloak/providers/keycloak-smart-auth.jar

# OpenMRS users as Keycloak's user store
(cd ../openmrs-contrib-keycloak-auth && mvn clean install)
cp ../openmrs-contrib-keycloak-auth/openmrs-keycloak-userstore/target/openmrs-keycloak-userstore-1.0.0-SNAPSHOT.jar \
   keycloak/providers/openmrs-keycloak-userstore.jar

# the frontend module
(cd ../openmrs-esm-smart-app-launch-app && npm install && npm run build && npm pack)
mv ../openmrs-esm-smart-app-launch-app/uwdigi-esm-smart-app-launch-app-*.tgz \
   frontend/esm-smart-app-launch.tgz
```

Then update the commit and hash above, and recreate what consumes it:

```bash
docker compose up -d --build --force-recreate backend keycloak frontend
```

### Rebuilding the frontend after changing the frontend module

Replacing `frontend/esm-smart-app-launch.tgz` is not enough on its own. `openmrs assemble` is an
expensive layer and BuildKit will reuse it, so `docker compose build frontend` can produce an image that
still serves the previous module while every other check looks right. Bust it explicitly:

```bash
docker compose build --build-arg CACHE_BUST="$(date +%s)" frontend
docker compose up -d --force-recreate frontend
```

Comparing chunk filenames does **not** catch this: they are content-hashed, so unchanged chunks keep
their names and the listing looks identical. Compare something that changes, such as the served
`routes.json`:

```bash
docker compose exec frontend cat \
  /usr/share/nginx/html/uwdigi-esm-smart-app-launch-app-1.0.0/routes.json
```

This cost two wrong diagnoses before it was noticed -- behaviour was attributed to the framework that
was really a stale bundle.

## Working on a module without replacing the artefact

Every path is overridable, so you can point the stack at your own build tree and leave the committed
copies untouched. Put these in `.env`:

```
SMARTONFHIR_OMOD=../openmrs-module-smartonfhir/omod/target/smartonfhir-2.0.0-SNAPSHOT.omod
SMART_AUTH_JAR=../openmrs-contrib-keycloak-smart-auth/keycloak-smart-auth/target/keycloak-smart-auth-1.0.0-SNAPSHOT.jar
USERSTORE_JAR=../openmrs-contrib-keycloak-auth/openmrs-keycloak-userstore/target/openmrs-keycloak-userstore-1.0.0-SNAPSHOT.jar
```

A bind mount follows the inode it was created from, so `mvn clean` leaves the container reading a file
that no longer exists. After rebuilding, recreate the container rather than restarting it:
`docker compose up -d --force-recreate backend`.

The frontend module is baked into its image rather than mounted, so it has no override: replace
`frontend/esm-smart-app-launch.tgz` and rebuild that image.
