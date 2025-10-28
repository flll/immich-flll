FROM google/cloud-sdk:544.0.0-alpine AS gcloud

FROM openresty/openresty:1.21.4.1-0-alpine-apk

RUN apk add --no-cache \
    bash \
    curl \
    python3 \
    gettext

COPY --from=gcloud /google-cloud-sdk /google-cloud-sdk

ENV PATH="/google-cloud-sdk/bin:${PATH}"

RUN mkdir -p /var/log/nginx /var/cache/nginx /tmp

COPY cloud-run-proxy/nginx.conf.template /cloud-run-proxy/nginx.conf.template
COPY cloud-run-proxy/entrypoint.sh /cloud-run-proxy/entrypoint.sh
COPY cloud-run-proxy/token-updater.sh /cloud-run-proxy/token-updater.sh

RUN chmod +x /cloud-run-proxy/entrypoint.sh /cloud-run-proxy/token-updater.sh

EXPOSE 3003

ENTRYPOINT ["/cloud-run-proxy/entrypoint.sh"]

STOPSIGNAL SIGTERM