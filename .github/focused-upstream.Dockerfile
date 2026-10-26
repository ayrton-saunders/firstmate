# Trusted workflow-owned test environment. No candidate build context or code.
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash ca-certificates coreutils git python3 \
    && rm -rf /var/lib/apt/lists/*
