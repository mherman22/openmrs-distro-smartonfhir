# Keycloak 26 plus the JDBC driver the OpenMRS user federation provider needs: Quarkus does not expose
# Keycloak's own MySQL driver to provider classloaders, so a provider's dependencies go in providers/.
FROM quay.io/keycloak/keycloak:${KEYCLOAK_TAG:-26.7.1}

ARG MYSQL_CONNECTOR_VERSION=9.6.0

ADD --chown=keycloak:root \
  https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${MYSQL_CONNECTOR_VERSION}/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar \
  /opt/keycloak/providers/mysql-connector-j.jar
