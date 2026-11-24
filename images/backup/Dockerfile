# Backup-Image: restic + Postgres-Werkzeuge. pg_dump 18 sichert auch ältere Server (bis 18).
# kubectl für den Restore-Job der Stufe k3s (App anhalten und wieder starten).
FROM postgres:18-alpine
ARG TARGETARCH
ARG KUBECTL_VERSION=v1.36.6
RUN apk add --no-cache restic jq curl ca-certificates tzdata \
 && curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH:-amd64}/kubectl" \
 && chmod +x /usr/local/bin/kubectl
COPY backup.sh /usr/local/bin/factory-backup
RUN chmod +x /usr/local/bin/factory-backup
LABEL org.opencontainers.image.source="https://github.com/thorsten-reitz/factory-pipelines" \
      org.opencontainers.image.description="Backup, Restore und Restore-Test für Factory-Projekte (restic nach S3)"
ENTRYPOINT ["/usr/local/bin/factory-backup"]
