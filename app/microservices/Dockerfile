# Minimal microservice image for demo
# Configurable via SERVICE_NAME and LOG_INTERVAL environment variables

FROM alpine:3.19

# Install coreutils for shuf command
RUN apk add --no-cache coreutils

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Non-root user for security
RUN adduser -D -u 1000 microservice
USER microservice

ENV SERVICE_NAME=unknown
ENV LOG_INTERVAL=30

ENTRYPOINT ["/entrypoint.sh"]
