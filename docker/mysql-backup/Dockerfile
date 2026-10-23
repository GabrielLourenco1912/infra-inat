# syntax=docker/dockerfile:1

# Reuse the Oracle clients matching the project's MySQL 8.0, without shipping mysqld.
FROM mysql:8.0-debian AS client

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        bash ca-certificates cron gzip tzdata util-linux \
        libssl3 libstdc++6 libtinfo6 zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=client /usr/bin/mysql /usr/bin/mysqldump /usr/local/bin/
COPY mysql-backup /usr/local/bin/mysql-backup
COPY crontab /etc/cron.d/mysql-backup

RUN chmod 0755 /usr/local/bin/mysql-backup \
    && chmod 0644 /etc/cron.d/mysql-backup \
    && mkdir -p /backups \
    && mysql --version && mysqldump --version

ENTRYPOINT ["/usr/local/bin/mysql-backup"]
CMD ["schedule"]
