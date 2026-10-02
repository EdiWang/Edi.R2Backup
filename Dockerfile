FROM rclone/rclone:1.75.1

RUN apk add --no-cache ca-certificates tzdata jq flock curl \
    && case "$(uname -m)" in \
        x86_64) arch=amd64; checksum=a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1 ;; \
        aarch64) arch=arm64; checksum=02aa0cb229ba09050cba6638059dadb9eedc2276632ea43d6a57a2f8c1629dd5 ;; \
        *) echo "Unsupported architecture" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/aptible/supercronic/releases/download/v0.2.49/supercronic-linux-${arch}" -o /tmp/supercronic \
    && echo "${checksum}  /tmp/supercronic" | sha256sum -c - \
    && mv /tmp/supercronic /usr/local/bin/supercronic \
    && chmod 755 /usr/local/bin/supercronic \
    && apk del curl \
    && mkdir -p /backup /app \
    && chown 1000:1000 /backup

COPY --chmod=755 scripts/ /app/

ENV RCLONE_CONFIG=/run/secrets/rclone.conf \
    R2_REMOTE=r2 \
    BACKUP_CRON="0 2 * * 4" \
    TZ=Etc/UTC

USER 1000:1000
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
