FROM node:22-bookworm-slim AS node
FROM nginx:1.29-bookworm
COPY --from=node /usr/local/bin/node /usr/local/bin/node
RUN apt-get update && apt-get install -y --no-install-recommends \
      iproute2 tcpdump apache2-utils procps ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /lab
