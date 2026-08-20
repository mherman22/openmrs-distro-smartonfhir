# syntax=docker/dockerfile:1.4
#--------------------------------------------
# Dev Stage - Assembles and Builds Frontend
#--------------------------------------------
FROM --platform=$BUILDPLATFORM node:22-alpine as dev

ARG APP_SHELL_VERSION=10.0.0

RUN mkdir -p /app
WORKDIR /app

COPY spa-assemble-config.json .
COPY spa-build-config.json .

# The SMART launch frontend module, as a packed tarball committed to this repository.
#
# It is not published to a registry, and the @openmrs scope is not ours to publish under, so it ships
# here instead -- which is what lets a clone of this repository build without a second checkout beside
# it. `openmrs assemble` resolves a `file:` spec like any other npm spec (measured, not assumed), so a
# tarball is enough to put the module in the import map and the routes registry alongside every other
# frontend module. See ARTIFACTS.md for which commit it was packed from.
COPY esm-smart-app-launch.tgz /app/esm-smart-app-launch.tgz

ARG CACHE_BUST
RUN npx --legacy-peer-deps openmrs@${APP_SHELL_VERSION:-10.0.0} assemble --manifest --mode config --config spa-assemble-config.json --target ./spa
RUN npx --legacy-peer-deps openmrs@${APP_SHELL_VERSION:-10.0.0} build --build-config spa-build-config.json --target ./spa
RUN if [ ! -f ./spa/index.html ]; then echo 'Build failed. Please check the logs above for details. This may have happened because of an update to a library that OpenMRS depends on.'; exit 1; fi

#--------------------------------------------
# Runtime Stage - Published Image
#--------------------------------------------
FROM nginx:1.31-alpine

RUN apk update && \
    apk upgrade && \
    # add more utils for sponge and envsubst
    apk add --no-cache moreutils

# clear any default files installed by nginx
RUN rm -rf /usr/share/nginx/html/*

COPY startup.sh /usr/local/bin/startup.sh
RUN chmod +x /usr/local/bin/startup.sh

COPY nginx.conf /etc/nginx/nginx.conf

COPY --from=dev /app/spa /usr/share/nginx/html
COPY config-core_demo.json /usr/share/nginx/html

CMD ["/usr/local/bin/startup.sh"]
