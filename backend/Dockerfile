# The reference application backend, unchanged.
#
# This exists as a build context only so that the one runtime property this distribution needs and
# cannot express as an environment variable has somewhere to live once that is solved. The image turns
# OMRS_EXTRA_<NAME> into a runtime property but lowercases the name, and the authentication module reads
# `authentication.whiteList` with a capital L.
#
# Seeding /openmrs/data/openmrs-runtime.properties here does NOT work: the image treats an existing
# runtime properties file as "already installed" and skips writing the database settings, so OpenMRS
# boots into /openmrs/initialsetup. Measured, not assumed.
FROM openmrs/openmrs-reference-application-3-backend:${TAG:-qa}
