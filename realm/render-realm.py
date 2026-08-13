#!/usr/bin/env python3
"""Render realm/openmrs-realm.json for a particular deployment.

The committed realm is a template. It holds placeholders rather than a secret or
any environment's hostnames, so that nothing deployment-specific and nothing
sensitive lives in version control.

Placeholders, and where each value has to be reachable from:

  __SMART_LAUNCH_SECRET__   HS256 key shared with the OpenMRS module. Required.
  __OPENMRS_BASE_URL__      OpenMRS as the *browser* sees it. The launch and
                            patient-selection URLs are browser redirects, so a
                            container-internal hostname will not do.
  __FHIR_BASE_URL__         The FHIR base as the *app* names it in `aud`. Must
                            match what the app sends or the audience validator
                            rejects the launch.
  __SMART_APP_BASE_URL__    Where the SMART app itself is served, for redirect URIs.
  __OPENMRS_JDBC_URL__      How Keycloak reaches the OpenMRS database, from inside its own
                            container. Users are read from it directly.
  __OPENMRS_DB_USER__       and
  __OPENMRS_DB_PASSWORD__   credentials for that database.
  __SSL_REQUIRED__          all | external | none. Keycloak answers 403 on realm
                            endpoints over plain HTTP unless this is "none", so a
                            local development stack must set it. Defaults to
                            "external".

Usage:
  SMART_LAUNCH_SECRET=$(openssl rand -base64 32) \\
  OPENMRS_BASE_URL=http://localhost/openmrs \\
  realm/render-realm.py /tmp/import/openmrs-realm.json
"""
import os
import sys

TEMPLATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "openmrs-realm.json")

DEFAULTS = {
    "OPENMRS_BASE_URL": "http://localhost/openmrs",
    "SMART_APP_BASE_URL": "http://localhost:3000",
    # Keycloak refuses realm endpoints over plain HTTP when this is "external",
    # answering 403, so a local HTTP development stack has to set "none". The
    # default is the safe one; development opts out deliberately.
    "SSL_REQUIRED": "external",
    "OPENMRS_JDBC_URL": "jdbc:mysql://db:3306/openmrs",
    "OPENMRS_DB_USER": "openmrs",
}


def resolve():
    values = {}

    secret = os.environ.get("SMART_LAUNCH_SECRET", "").strip()
    if not secret:
        sys.exit("SMART_LAUNCH_SECRET is required. Generate one with: openssl rand -base64 32")
    values["__SMART_LAUNCH_SECRET__"] = secret

    openmrs = os.environ.get("OPENMRS_BASE_URL", DEFAULTS["OPENMRS_BASE_URL"]).rstrip("/")
    values["__OPENMRS_BASE_URL__"] = openmrs

    # Defaults to the FHIR base under the OpenMRS URL, which is where fhir2 serves it.
    values["__FHIR_BASE_URL__"] = os.environ.get("FHIR_BASE_URL", openmrs + "/ws/fhir2/R4").rstrip("/")

    values["__SMART_APP_BASE_URL__"] = os.environ.get(
        "SMART_APP_BASE_URL", DEFAULTS["SMART_APP_BASE_URL"]).rstrip("/")

    values["__OPENMRS_JDBC_URL__"] = os.environ.get("OPENMRS_JDBC_URL", DEFAULTS["OPENMRS_JDBC_URL"])
    values["__OPENMRS_DB_USER__"] = os.environ.get("OPENMRS_DB_USER", DEFAULTS["OPENMRS_DB_USER"])

    db_password = os.environ.get("OPENMRS_DB_PASSWORD", "").strip()
    if not db_password:
        sys.exit("OPENMRS_DB_PASSWORD is required: Keycloak reads OpenMRS users directly from its database")
    values["__OPENMRS_DB_PASSWORD__"] = db_password

    ssl_required = os.environ.get("SSL_REQUIRED", DEFAULTS["SSL_REQUIRED"]).strip()
    if ssl_required not in ("all", "external", "none"):
        sys.exit("SSL_REQUIRED must be one of: all, external, none (got %r)" % ssl_required)
    values["__SSL_REQUIRED__"] = ssl_required

    return values


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)

    target = sys.argv[1]
    rendered = open(TEMPLATE).read()
    values = resolve()

    for placeholder, value in values.items():
        rendered = rendered.replace(placeholder, value)

    leftover = [p for p in values if p in rendered]
    if leftover:
        sys.exit("placeholders survived substitution: %s" % ", ".join(leftover))

    if "__" in rendered:
        # Catches a placeholder added to the template but not taught to this script,
        # which would otherwise ship a literal __PLACEHOLDER__ into a live realm.
        import re
        unknown = sorted(set(re.findall(r"__[A-Z0-9_]+__", rendered)))
        if unknown:
            sys.exit("template contains placeholders this script does not know: %s" % ", ".join(unknown))

    directory = os.path.dirname(os.path.abspath(target))
    if directory:
        os.makedirs(directory, exist_ok=True)
    open(target, "w").write(rendered)

    # Never echo the secret.
    print("rendered %s" % target)
    for key in ("__OPENMRS_BASE_URL__", "__FHIR_BASE_URL__", "__SMART_APP_BASE_URL__", "__SSL_REQUIRED__",
                "__OPENMRS_JDBC_URL__", "__OPENMRS_DB_USER__"):
        print("  %-24s %s" % (key.strip("_").lower(), values[key]))


if __name__ == "__main__":
    main()
