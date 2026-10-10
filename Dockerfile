# ==========================================
# STAGE 1: Compile the React Frontend Assets
# ==========================================
FROM node:24-alpine AS frontend-builder

WORKDIR /src/webapp
# Copy all webapp source code (required by npm workspaces during postinstall)
COPY webapp/ .
RUN npm ci --engine-strict=false && npm run build

# ==========================================
# STAGE 2: Compile the Go Backend Binary
# ==========================================
FROM golang:alpine AS backend-builder
RUN apk add --no-cache git make bash gcc musl-dev

WORKDIR /src
# Copy backend source code
COPY . .

# Compile a static, production-optimized Go binary targeting Linux 64-bit
ENV GOTOOLCHAIN=auto
RUN cd server && \
    go mod edit -replace github.com/mattermost/mattermost/server/public=./public && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ./bin/mattermost ./cmd/mattermost && \
    mkdir -p config && \
    OUTPUT_CONFIG=/src/server/config/config.json go run ./scripts/config_generator

# ==========================================
# STAGE 3: Build the Final Monolithic Runtime
# ==========================================
FROM alpine:3.20

# Extend system PATH to run mattermost binary commands easily
ENV PATH="/mattermost/bin:${PATH}"

# Install minimal infrastructure utilities
# hadolint ignore=DL3018
RUN apk add --no-cache ca-certificates curl jq tzdata bash

# Set up the expected application directory layout
RUN mkdir -p /mattermost/bin /mattermost/data /mattermost/config /mattermost/plugins /mattermost/client

# 1. Copy the Go binary from STAGE 2
COPY --from=backend-builder /src/server/bin/mattermost /mattermost/bin/

# 2. Copy the compiled React assets from STAGE 1 into the exact location the Go app expects
COPY --from=frontend-builder /src/webapp/channels/dist /mattermost/client/

# 3. Pull default configuration rules and assets (i18n, fonts, templates)
COPY --from=backend-builder /src/server/config/config.json /mattermost/config.defaults.json
COPY --from=backend-builder /src/server/config/config.json /mattermost/config/config.json
COPY --from=backend-builder /src/server/i18n /mattermost/i18n/
COPY --from=backend-builder /src/server/fonts /mattermost/fonts/
COPY --from=backend-builder /src/server/templates /mattermost/templates/

# Copy operational script to manage database configuration readiness
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Apply security best-practices: Add and use a dedicated non-root user
RUN addgroup -S mattermost && adduser -S mattermost -G mattermost \
    && chown -R mattermost:mattermost /mattermost /entrypoint.sh

USER mattermost
WORKDIR /mattermost

# Default application communication port
EXPOSE 8065

# Declare volume mount paths for data persistence
VOLUME ["/mattermost/data", "/mattermost/config", "/mattermost/plugins"]

ENTRYPOINT ["/entrypoint.sh"]
CMD ["mattermost", "server"]
