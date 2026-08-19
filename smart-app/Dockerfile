# The demonstration SMART application: built, then served as static files.
#
# Two stages so the runtime image carries no toolchain. The app is a bundle and an HTML page; nothing
# about it needs Node at runtime, and a SMART app is a third-party artefact by nature -- it talks to the
# FHIR server over HTTP like any other client, and knows nothing about this distribution.
FROM node:22-alpine AS build

WORKDIR /app
COPY package.json ./
RUN npm install --no-audit --no-fund
COPY src ./src
COPY index.html launch.html style.css ./
RUN npm run build

FROM nginx:1.31-alpine

RUN rm -rf /usr/share/nginx/html/*
COPY --from=build /app/index.html /app/launch.html /app/style.css /usr/share/nginx/html/
COPY --from=build /app/dist /usr/share/nginx/html/dist
