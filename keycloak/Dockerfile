# Keycloak 26 plus the JDBC driver the OpenMRS user federation provider needs.
#
# Keycloak ships a MySQL driver for its own datasource, but Quarkus does not expose it to provider
# classloaders, and with the embedded database it is not on that classpath at all. Keycloak's answer is
# that a provider's dependencies belong in providers/ beside it.
#
# Fetched here rather than staged by a script so that the version is stated in one place and the build
# is reproducible from this file alone.
FROM quay.io/keycloak/keycloak:${KEYCLOAK_TAG:-26.7.1}

ARG MYSQL_CONNECTOR_VERSION=9.6.0

ADD --chown=keycloak:root \
  https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${MYSQL_CONNECTOR_VERSION}/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar \
  /opt/keycloak/providers/mysql-connector-j.jar
