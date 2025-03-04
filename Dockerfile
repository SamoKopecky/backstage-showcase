#
# Copyright (c) 2023 Red Hat, Inc.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Stage 1 - Install dependencies
#@follow_tag(registry.redhat.io/ubi9/nodejs-18:1)
FROM registry.access.redhat.com/ubi9/nodejs-18:1 AS deps
USER 0

# Env vars
ENV YARN=./.yarn/releases/yarn-1.22.19.cjs

COPY ./package.json ./yarn.lock ./
COPY ./packages ./packages
COPY ./.yarn ./.yarn
COPY ./.yarnrc.yml ./

# Remove all files except package.json
RUN find packages -mindepth 2 -maxdepth 2 \! -name "package.json" -exec rm -rf {} \+

ENV IS_CONTAINER="TRUE"
RUN $YARN install --frozen-lockfile --network-timeout 600000 --ignore-scripts

# Stage 2 - Build packages
#@follow_tag(registry.redhat.io/ubi9/nodejs-18:1)
FROM registry.access.redhat.com/ubi9/nodejs-18:1 AS build
USER 0

# Env vars
ENV YARN=./.yarn/releases/yarn-1.22.19.cjs
ENV TECHDOCS_BUILDER_TYPE=external
ENV TECHDOCS_GENERATOR_TYPE=local
ENV TECHDOCS_PUBLISHER_TYPE=awsS3
ENV SEGMENT_WRITE_KEY=temp
ENV SEGMENT_TEST_MODE=true

COPY . .
COPY --from=deps /opt/app-root/src .
COPY --from=deps --chown=0:0 /opt/app-root/src/.yarn ./.yarn
COPY --from=deps --chown=0:0 /opt/app-root/src/.yarnrc.yml ./

RUN git config --global --add safe.directory /opt/app-root/src
RUN $YARN build --filter=backend

# Stage 3 - Build the actual backend image and install production dependencies
#@follow_tag(registry.redhat.io/ubi9/nodejs-18-minimal:1)
FROM registry.access.redhat.com/ubi9/nodejs-18-minimal:1 AS runner
USER 0

# Env vars
ENV YARN=./.yarn/releases/yarn-1.22.19.cjs
ENV TECHDOCS_BUILDER_TYPE=external
ENV TECHDOCS_GENERATOR_TYPE=local
ENV TECHDOCS_PUBLISHER_TYPE=awsS3
ENV SEGMENT_WRITE_KEY=temp
ENV SEGMENT_TEST_MODE=true

# Install gzip for tar and clean up
RUN microdnf install -y gzip python3 python3-pip && \
    pip3 install mkdocs-techdocs-core==1.2.1 && \
    microdnf clean all

COPY --from=build --chown=1001:1001 /opt/app-root/src/.yarn ./.yarn
COPY --from=build --chown=1001:1001 /opt/app-root/src/.yarnrc.yml ./

# Switch to nodejs user
USER 1001

# Copy the install dependencies from the build stage and context
COPY --from=build /opt/app-root/src/yarn.lock /opt/app-root/src/package.json /opt/app-root/src/packages/backend/dist/skeleton.tar.gz ./
RUN tar xzf skeleton.tar.gz && rm skeleton.tar.gz

# Install production dependencies
ENV IS_CONTAINER="TRUE"
RUN $YARN install --frozen-lockfile --production --network-timeout 600000 --ignore-scripts && $YARN cache clean

# Copy the built packages from the build stage
COPY --from=build /opt/app-root/src/packages/backend/dist/bundle.tar.gz .
RUN tar xzf bundle.tar.gz && rm bundle.tar.gz

# Copy any other files that we need at runtime
COPY ./app-config.yaml ./app-config.production.yaml ./app-config.example.yaml ./app-config.example.production.yaml ./

# The fix-permissions script is important when operating in environments that dynamically use a random UID at runtime, such as OpenShift.
# The upstream backstage image does not account for this and it causes the container to fail at runtime.
RUN fix-permissions ./

ENTRYPOINT ["node", "packages/backend", "--config", "app-config.yaml", "--config", "app-config.example.yaml", "--config", "app-config.example.production.yaml"]
