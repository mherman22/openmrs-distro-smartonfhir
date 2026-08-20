# Shipped artefacts

Four build outputs are committed to this repository so that a clone starts with
`docker compose up -d` and nothing else. They are here because none of them is published: the two
OpenMRS modules and the Keycloak plugin have no release and no snapshot deployment, and the frontend
module cannot go to npm under a scope that is not ours.

Committing a binary means it can silently drift from the source it was built from, so each one records
the commit it came from. **If you change any of those repositories, the matching artefact here is stale
until you replace it** — the table below is the only thing that says so.

| Artefact | Built from | Commit | SHA-256 |
|---|---|---|---|
| `backend/modules/smartonfhir.omod` | [openmrs-module-smartonfhir](https://github.com/mherman22/openmrs-module-smartonfhir) | `0f646bf` (FM2-687) | `98f04cc3591cc4afc625f277ce388e81…` |
| `keycloak/providers/keycloak-smart-auth.jar` | [openmrs-contrib-keycloak-smart-auth](https://github.com/mherman22/openmrs-contrib-keycloak-smart-auth) | `560c365` (FM2-690) | `99825f379b190c7b2a06000d2726fe8a…` |
| `keycloak/providers/openmrs-keycloak-userstore.jar` | [openmrs-contrib-keycloak-auth](https://github.com/mherman22/openmrs-contrib-keycloak-auth) | `3d355a5` (master) | `69ae8721fa9f36e9a03b55f3fd0aeb1f…` |
| `frontend/esm-smart-app-launch.tgz` | [openmrs-esm-smart-app-launch-app](https://github.com/mherman22/openmrs-esm-smart-app-launch-app) | `38ac54e` (main) | `eb307b81a5a65679872157b084faa998…` |

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
