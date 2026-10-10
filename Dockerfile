# ==========================================
# STAGE 1: Compile the React Frontend Assets
# ==========================================
FROM node:18-alpine AS frontend-builder

WORKDIR /src/webapp
# Copy frontend configurations first to leverage Docker caching
COPY webapp/package*.json ./
RUN npm ci

# Copy the remaining frontend code and compile static production files
COPY webapp/ .
RUN npm run build

# ==========================================
# STAGE 2: Compile the Go Backend Binary
# ==========================================
FROM golang:1.23-alpine AS backend-builder
RUN apk add --no-cache git make bash gcc musl-dev

WORKDIR /src
# Copy backend source code
COPY . .

# Compile a static, production-optimized Go binary targeting Linux 64-bit
RUN cd server && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -tags enterprise -o ./bin/mattermost ./cmd/mattermost

# ==========================================
# STAGE 3: Build the Final Monolithic Runtime
# ==========================================
FROM alpine:3.20

# Extend system PATH to run mattermost binary commands easily
ENV PATH="/mattermost/bin:${PATH}"

# Install minimal infrastructure utilities
RUN apk add --no-cache ca-certificates curl jq tzdata bash

# Set up the expected application directory layout
RUN mkdir -p /mattermost/bin /mattermost/data /mattermost/config /mattermost/plugins /mattermost/client

# 1. Copy the Go binary from STAGE 2
COPY --from=backend-builder /src/server/bin/mattermost /mattermost/bin/

# 2. Copy the compiled React assets from STAGE 1 into the exact location the Go app expects
COPY --from=frontend-builder /src/webapp/dist /mattermost/client/

# 3. Pull default configuration rules from your repository source
COPY --from=backend-builder /src/server/config/config.json /mattermost/config.defaults.json
COPY --from=backend-builder /src/server/config/config.json /mattermost/config/config.json

# Apply security best-practices: Add and use a dedicated non-root user
RUN addgroup -S mattermost && adduser -S mattermost -G mattermost \
    && chown -R mattermost:mattermost /mattermost

USER mattermost
WORKDIR /mattermost

# Default application communication port
EXPOSE 8065

# Declare volume mount paths for data persistence
VOLUME ["/mattermost/data", "/mattermost/config", "/mattermost/plugins"]

# Copy operational script to manage database configuration readiness
COPY --chown=mattermost:mattermost entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["mattermost"]
