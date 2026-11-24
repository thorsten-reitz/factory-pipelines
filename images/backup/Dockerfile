# Backup-Image: restic + Postgres-Werkzeuge. pg_dump 18 sichert auch ältere Server (bis 18).
FROM postgres:18-alpine
RUN apk add --no-cache restic jq curl ca-certificates tzdata
COPY backup.sh /usr/local/bin/factory-backup
RUN chmod +x /usr/local/bin/factory-backup
LABEL org.opencontainers.image.source="https://github.com/thorsten-reitz/factory-pipelines" \
      org.opencontainers.image.description="Backup, Restore und Restore-Test für Factory-Projekte (restic nach S3)"
ENTRYPOINT ["/usr/local/bin/factory-backup"]
