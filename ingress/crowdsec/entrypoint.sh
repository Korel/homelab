#!/bin/bash
# On first run, if volume mounted, /etc/crowdsec volume will be empty.
# Copy default configs from /staging (where crowdsec base image stores them)
# Skip files that already exist (e.g., separately mounted acquis.yaml)
if [ ! -f /etc/crowdsec/config.yaml ]; then
    cp -a -n /staging/etc/crowdsec/* /etc/crowdsec/
fi
# Run the original crowdsec entrypoint (from crowdsecurity/crowdsec:latest)
exec /docker_start.sh "$@"
