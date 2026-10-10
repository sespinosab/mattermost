#!/bin/bash
set -e

# Restores the default configuration layout if a blank persistent volume overrides it
if [ ! -f /mattermost/config/config.json ]; then
    echo "Configuration layout not found. Injecting code workspace defaults..."
    cp /mattermost/config.defaults.json /mattermost/config/config.json
fi

# Execute the core docker container command (Starts the Mattermost server)
exec "$@"
