# The reference application backend, plus the runtime properties its environment cannot express.
#
# The image turns OMRS_EXTRA_<NAME> into a runtime property but lowercases the name, and the
# authentication module reads `authentication.whiteList` with a capital L. There is no environment
# variable that produces that, and openmrs-server.properties is rewritten from scratch on every start,
# so seeding the runtime properties is what is left.
#
# This seeds a *fresh* /openmrs/data volume: Docker copies image content into an empty named volume, and
# does nothing to a volume that already has content. So after changing runtime.properties the volume has
# to go too:
#
#   docker compose down -v
FROM openmrs/openmrs-reference-application-3-backend:${TAG:-qa}

COPY runtime.properties /openmrs/data/openmrs-runtime.properties
